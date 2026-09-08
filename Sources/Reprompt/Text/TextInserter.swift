import AppKit
import ApplicationServices

enum InsertError: Error, CustomStringConvertible, Equatable {
    case cannotPostEvents
    case nothingToInsert

    var description: String {
        switch self {
        case .cannotPostEvents: "Reprompt cannot send keystrokes; grant Accessibility permission. The text is on the clipboard instead."
        case .nothingToInsert: "There was nothing to paste."
        }
    }
}

protocol TextInserting {
    /// `preferAccessibility` is false once Reprompt has taken focus itself (Clarify or Edit),
    /// because the element captured at grab time may no longer be the one the user is in.
    func replace(_ selection: Selection, with text: String, preferAccessibility: Bool) async throws
}

/// Writes the rewrite back: through the Accessibility API when the focused element accepts
/// it, otherwise by re-activating the target application and pasting.
struct TextInserter: TextInserting {
    /// How long the target app is given to consume the paste before the clipboard is put back.
    var settleDelay: Duration = .milliseconds(300)

    func replace(_ selection: Selection, with text: String, preferAccessibility: Bool = true) async throws {
        guard !text.isEmpty else { throw InsertError.nothingToInsert }
        if preferAccessibility, let element = selection.element, writeViaAccessibility(element: element, text: text) {
            return
        }
        try await paste(text: text, into: selection.app)
    }

    /// Returns true when the element accepted the write.
    ///
    /// A successful `SetAttributeValue` is trusted rather than re-verified against
    /// `kAXValue`: some views normalise whitespace or expose only the visible portion, so
    /// verification produces false negatives, and falling through to the paste path after a
    /// write that actually landed inserts the rewrite TWICE. A false success is recoverable
    /// (nothing happens and the user retries); a double insert corrupts their document.
    func writeViaAccessibility(element: AXUIElement, text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func paste(text: String, into app: NSRunningApplication?) async throws {
        let pb = NSPasteboard.general
        guard AccessibilityPermission.canPostEvents else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            throw InsertError.cannotPostEvents
        }
        if let app, !app.isActive {
            app.activate()
            try? await Task.sleep(for: .milliseconds(120))
        }
        let snapshot = PasteboardSnapshot.capture(pb)
        // Restore even if this task is cancelled mid-paste; without the defer, pressing
        // Escape inside the settle window left the rewrite on the user's clipboard forever.
        defer { snapshot.restore(to: pb) }
        pb.clearContents()
        pb.setString(text, forType: .string)
        await KeySimulator.waitForModifiersToClear()
        KeySimulator.paste()
        // No signal exists for "the target consumed the paste", so this is a bounded wait.
        // It deliberately ignores cancellation so the clipboard is not restored too early.
        try? await Task.sleep(for: settleDelay)
    }

    /// An explicit Copy action: the text is meant to stay on the clipboard.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
