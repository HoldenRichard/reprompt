import AppKit
import Testing
@testable import Reprompt

/// Stands in for the focused text control. `copy()` behaves like a real Cmd+C: it writes
/// to the pasteboard only when something is selected, and leaves it alone otherwise.
@MainActor
final class FakeField {
    let pasteboard: NSPasteboard
    var fullText: String
    var selectedText: String?
    var isEditable = true
    private(set) var copies = 0
    private(set) var selectAlls = 0

    init(fullText: String, selectedText: String?, pasteboard: NSPasteboard) {
        self.fullText = fullText
        self.selectedText = selectedText
        self.pasteboard = pasteboard
    }

    func copy() {
        copies += 1
        guard let s = selectedText else { return }
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
    }

    func selectAll() {
        selectAlls += 1
        selectedText = fullText
    }
}

@Suite @MainActor struct SelectionReaderTests {
    func scratchPasteboard() -> (NSPasteboard, () -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.holdenrichard.reprompt.tests.\(UUID().uuidString)"))
        return (pb, { pb.releaseGlobally() })
    }

    func reader(field: FakeField, ax: (text: String, element: AXUIElement?)? = nil,
                selectAllWhenEmpty: Bool = true, trusted: Bool = true,
                canPost: Bool = true, secure: Bool = false) -> SelectionReader {
        SelectionReader(
            selectAllWhenEmpty: selectAllWhenEmpty,
            copyTimeout: .milliseconds(60),
            isTrusted: { trusted },
            canPostEvents: { canPost },
            secureInputActive: { secure },
            frontmostApp: { nil },
            readAccessibilitySelection: { ax },
            isEditableTextContext: { field.isEditable },
            pasteboard: field.pasteboard,
            sendCopy: { field.copy() },
            sendSelectAll: { field.selectAll() })
    }

    @Test func anAccessibilitySelectionIsUsedWithoutTouchingTheClipboard() async throws {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        pb.setString("user's clipboard", forType: .string)
        let field = FakeField(fullText: "whole", selectedText: "part", pasteboard: pb)

        let s = try await reader(field: field, ax: ("from AX", nil)).read()
        #expect(s.text == "from AX")
        #expect(s.source == .accessibility)
        #expect(!s.selectedAll)
        #expect(field.copies == 0, "no keystroke should be sent when AX answers")
        #expect(pb.string(forType: .string) == "user's clipboard")
    }

    @Test func aRealSelectionIsCopiedAndTheClipboardIsPutBack() async throws {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        pb.setString("user's clipboard", forType: .string)
        let field = FakeField(fullText: "the whole prompt", selectedText: "the whole", pasteboard: pb)

        let s = try await reader(field: field).read()
        #expect(s.text == "the whole")
        #expect(s.source == .clipboard)
        #expect(!s.selectedAll)
        #expect(field.copies == 1)
        #expect(field.selectAlls == 0, "must not select all when the user already selected")
        #expect(pb.string(forType: .string) == "user's clipboard", "clipboard must be restored")
    }

    /// The feature: cursor in a field, nothing selected, hotkey does everything.
    @Test func withNothingSelectedInATextFieldTheWholeFieldIsUsed() async throws {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        pb.setString("user's clipboard", forType: .string)
        let field = FakeField(fullText: "make the login screen less janky", selectedText: nil, pasteboard: pb)

        let s = try await reader(field: field).read()
        #expect(s.text == "make the login screen less janky")
        #expect(s.selectedAll, "the session needs to know the whole field is now selected")
        #expect(field.selectAlls == 1)
        #expect(field.copies == 2, "one copy that found nothing, one after selecting all")
        #expect(pb.string(forType: .string) == "user's clipboard")
    }

    /// The guard: outside a text control, Cmd+A selects things that must not be pasted over.
    @Test func selectAllIsNeverSentOutsideATextControl() async throws {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        let field = FakeField(fullText: "every message in the mailbox", selectedText: nil, pasteboard: pb)
        field.isEditable = false

        let err = await errorOnMain { try await reader(field: field).read() }
        #expect(err as? SelectionError == .noSelection)
        #expect(field.selectAlls == 0, "Cmd+A in a list would select every item")
        #expect(field.copies == 1)
    }

    @Test func theSettingTurnsSelectAllOff() async throws {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        let field = FakeField(fullText: "text", selectedText: nil, pasteboard: pb)
        let err = await errorOnMain { try await reader(field: field, selectAllWhenEmpty: false).read() }
        #expect(err as? SelectionError == .noSelection)
        #expect(field.selectAlls == 0)
    }

    @Test func anEmptyFieldStillReportsNothingToRead() async throws {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        pb.clearContents()
        pb.setString("keep me", forType: .string)
        let field = FakeField(fullText: "   ", selectedText: nil, pasteboard: pb)
        let err = await errorOnMain { try await reader(field: field).read() }
        #expect(err as? SelectionError == .noSelection)
        #expect(field.selectAlls == 1)
        #expect(pb.string(forType: .string) == "keep me", "clipboard restored even on failure")
    }

    @Test func permissionAndSecureInputFailFastWithoutKeystrokes() async {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        let field = FakeField(fullText: "t", selectedText: "t", pasteboard: pb)

        let untrusted = await errorOnMain { try await reader(field: field, trusted: false).read() }
        #expect(untrusted as? SelectionError == .notTrusted)
        let cannotPost = await errorOnMain { try await reader(field: field, canPost: false).read() }
        #expect(cannotPost as? SelectionError == .cannotPostEvents)
        let secure = await errorOnMain { try await reader(field: field, secure: true).read() }
        #expect(secure as? SelectionError == .secureInput)
        #expect(field.copies == 0)
        #expect(field.selectAlls == 0)
    }

    @Test func aCopyThatNeverLandsTimesOutRatherThanHanging() async {
        let (pb, cleanup) = scratchPasteboard()
        defer { cleanup() }
        // A field that claims to be editable but whose copy and select-all do nothing at all.
        let field = FakeField(fullText: "", selectedText: nil, pasteboard: pb)
        let clock = ContinuousClock()
        let start = clock.now
        let err = await errorOnMain { try await reader(field: field).read() }
        #expect(err as? SelectionError == .noSelection)
        #expect(clock.now - start < .seconds(2), "two bounded waits, not a hang")
    }

    @Test func theEditableRoleListCoversNativeAndWebControls() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            #expect(SelectionReader.editableRoles.contains(role), "\(role)")
        }
        for role in ["AXTable", "AXList", "AXOutline", "AXButton", "AXWebArea"] {
            #expect(!SelectionReader.editableRoles.contains(role), "\(role) is not something you type into")
        }
    }
}
