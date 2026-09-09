import AppKit
import ApplicationServices

enum SelectionError: Error, CustomStringConvertible, Equatable {
    case notTrusted
    case secureInput
    case noSelection
    case cannotPostEvents

    var description: String {
        switch self {
        case .notTrusted: "Reprompt needs Accessibility permission (System Settings > Privacy & Security > Accessibility)."
        case .secureInput: "Secure input is active (a password field, or Terminal's Secure Keyboard Entry), so the selection cannot be read."
        case .noSelection: "Nothing is selected, and the cursor is not in a text field."
        case .cannotPostEvents: "Reprompt cannot send keystrokes; grant Accessibility permission."
        }
    }
}

struct Selection {
    enum Source: Equatable { case accessibility, clipboard }
    var text: String
    var app: NSRunningApplication?
    var source: Source
    /// Focused element when the Accessibility path succeeded; used for the write-back.
    var element: AXUIElement?
    /// True when nothing was selected and the reader selected the whole field itself.
    var selectedAll = false
}

protocol SelectionReading {
    func read() async throws -> Selection
}

/// Reads the current selection, escalating in three steps:
///
/// 1. The Accessibility API, which leaves the clipboard untouched.
/// 2. A simulated Cmd+C, for Chromium and Electron apps that hide the selection from AX.
/// 3. If that copied nothing, Cmd+A then Cmd+C, so the hotkey works with the cursor merely
///    sitting in a text field. Step 3 only runs inside a text control: in a mailbox or a
///    file list Cmd+A selects every item, and Accept would then paste over all of them.
///
/// Every outside dependency is a seam so the escalation can be tested without a real
/// focused element or the Accessibility grant.
struct SelectionReader: SelectionReading {
    var copyTimeout: Duration = .milliseconds(400)
    var selectAllWhenEmpty: Bool

    var isTrusted: () -> Bool
    var canPostEvents: () -> Bool
    var secureInputActive: () -> Bool
    var frontmostApp: () -> NSRunningApplication?
    var readAccessibilitySelection: () -> (text: String, element: AXUIElement?)?
    var isEditableTextContext: () -> Bool
    var pasteboard: NSPasteboard
    var sendCopy: () async -> Void
    var sendSelectAll: () async -> Void

    init(
        selectAllWhenEmpty: Bool = true,
        axTimeout: Float = 0.3,
        copyTimeout: Duration = .milliseconds(400),
        isTrusted: @escaping () -> Bool = { AccessibilityPermission.isTrusted },
        canPostEvents: @escaping () -> Bool = { AccessibilityPermission.canPostEvents },
        secureInputActive: @escaping () -> Bool = { AccessibilityPermission.secureInputActive },
        frontmostApp: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        readAccessibilitySelection: (() -> (text: String, element: AXUIElement?)?)? = nil,
        isEditableTextContext: (() -> Bool)? = nil,
        pasteboard: NSPasteboard = .general,
        sendCopy: @escaping () async -> Void = { await KeySimulator.waitForModifiersToClear(); KeySimulator.copy() },
        sendSelectAll: @escaping () async -> Void = { await KeySimulator.waitForModifiersToClear(); KeySimulator.selectAll() }
    ) {
        self.selectAllWhenEmpty = selectAllWhenEmpty
        self.copyTimeout = copyTimeout
        self.isTrusted = isTrusted
        self.canPostEvents = canPostEvents
        self.secureInputActive = secureInputActive
        self.frontmostApp = frontmostApp
        self.readAccessibilitySelection = readAccessibilitySelection
            ?? { Self.liveAccessibilitySelection(timeout: axTimeout) }
        self.isEditableTextContext = isEditableTextContext
            ?? { Self.liveEditableTextContext(timeout: axTimeout) }
        self.pasteboard = pasteboard
        self.sendCopy = sendCopy
        self.sendSelectAll = sendSelectAll
    }

    func read() async throws -> Selection {
        guard isTrusted() else { throw SelectionError.notTrusted }
        let app = frontmostApp()
        if let ax = readAccessibilitySelection() {
            return Selection(text: ax.text, app: app, source: .accessibility, element: ax.element)
        }
        return try await readViaClipboard(app: app)
    }

    // MARK: Clipboard path

    func readViaClipboard(app: NSRunningApplication?) async throws -> Selection {
        guard canPostEvents() else { throw SelectionError.cannotPostEvents }
        guard !secureInputActive() else { throw SelectionError.secureInput }
        let pb = pasteboard
        let snapshot = PasteboardSnapshot.capture(pb)
        defer { snapshot.restore(to: pb) }

        if let text = try await copySelection(pb) {
            return Selection(text: text, app: app, source: .clipboard, element: nil)
        }
        guard selectAllWhenEmpty, isEditableTextContext() else { throw SelectionError.noSelection }
        await sendSelectAll()
        guard let text = try await copySelection(pb) else { throw SelectionError.noSelection }
        return Selection(text: text, app: app, source: .clipboard, element: nil, selectedAll: true)
    }

    /// Sends Cmd+C and waits for the pasteboard to change. Returns nil when nothing was
    /// selected, which a real Cmd+C reports by leaving the pasteboard alone.
    private func copySelection(_ pb: NSPasteboard) async throws -> String? {
        pb.clearContents()
        let baseline = pb.changeCount
        await sendCopy()
        let clock = ContinuousClock()
        let deadline = clock.now + copyTimeout
        while pb.changeCount == baseline, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        guard pb.changeCount != baseline, let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    // MARK: Live Accessibility queries

    private static func focusedElement(timeout: Float) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func liveAccessibilitySelection(timeout: Float) -> (text: String, element: AXUIElement?)? {
        guard let focused = focusedElement(timeout: timeout) else { return nil }
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, focused)
    }

    /// True when the focused element is something a person types into. Any one of the
    /// signals is enough; Chromium exposes different ones from native controls.
    static func liveEditableTextContext(timeout: Float) -> Bool {
        guard let focused = focusedElement(timeout: timeout) else { return false }
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, editableRoles.contains(role) {
            return true
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        // Chromium marks content-editable regions this way even when the role is generic.
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, "AXEditableAncestor" as CFString, &editableRef) == .success,
           editableRef != nil {
            return true
        }
        return false
    }

    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
}
