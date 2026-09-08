import AppKit
import ApplicationServices

enum InsertError: Error, CustomStringConvertible {
    case cannotPostEvents
    var description: String {
        switch self {
        case .cannotPostEvents: "Reprompt cannot send keystrokes; grant Accessibility permission. The text was copied to the clipboard instead."
        }
    }
}

/// Writes the replacement back: AX `kAXSelectedText` when the element accepts it and the
/// write can be verified, otherwise re-activate the target app and paste via Cmd+V with the
/// pasteboard snapshotted and restored afterwards.
struct TextInserter {
    var settleDelay: Duration = .milliseconds(220)

    func replace(_ selection: Selection, with text: String) async throws {
        if let element = selection.element, writeViaAccessibility(element: element, text: text) {
            return
        }
        try await paste(text: text, into: selection.app)
    }

    func writeViaAccessibility(element: AXUIElement, text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        // Chromium views can report success without changing anything; verify via the value.
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String {
            return value.contains(text)
        }
        return true
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
            try await Task.sleep(for: .milliseconds(80))
        }
        let snapshot = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        KeySimulator.paste()
        try await Task.sleep(for: settleDelay)
        snapshot.restore(to: pb)
    }

    /// Explicit "Copy" action: leaves the text on the clipboard on purpose.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
