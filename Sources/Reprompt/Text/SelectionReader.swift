import AppKit
import ApplicationServices

enum SelectionError: Error, CustomStringConvertible {
    case notTrusted
    case secureInput
    case noSelection
    case cannotPostEvents

    var description: String {
        switch self {
        case .notTrusted: "Reprompt needs Accessibility permission (System Settings > Privacy & Security > Accessibility)."
        case .secureInput: "Secure input is active (a password field or Terminal's Secure Keyboard Entry); cannot read the selection."
        case .noSelection: "No text is selected."
        case .cannotPostEvents: "Reprompt cannot send keystrokes; grant Accessibility permission."
        }
    }
}

struct Selection {
    enum Source { case accessibility, clipboard }
    var text: String
    var app: NSRunningApplication?
    var source: Source
    /// Focused element when the AX path succeeded; used for the AX write-back.
    var element: AXUIElement?
}

/// Reads the current selection: Accessibility first (clipboard untouched), then a simulated
/// Cmd+C with the pasteboard snapshotted and restored. Electron apps usually need the fallback.
struct SelectionReader {
    var axTimeout: Float = 0.3
    var copyTimeout: Duration = .milliseconds(350)

    func read() async throws -> Selection {
        guard AccessibilityPermission.isTrusted else { throw SelectionError.notTrusted }
        let app = NSWorkspace.shared.frontmostApplication
        if let ax = readViaAccessibility() {
            return Selection(text: ax.text, app: app, source: .accessibility, element: ax.element)
        }
        return try await readViaClipboard(app: app)
    }

    // MARK: AX path

    func readViaAccessibility() -> (text: String, element: AXUIElement)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, axTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, axTimeout)
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, focused)
    }

    // MARK: Clipboard fallback

    func readViaClipboard(app: NSRunningApplication?) async throws -> Selection {
        guard AccessibilityPermission.canPostEvents else { throw SelectionError.cannotPostEvents }
        guard !AccessibilityPermission.secureInputActive else { throw SelectionError.secureInput }
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        defer { snapshot.restore(to: pb) }
        pb.clearContents()
        let baseline = pb.changeCount
        KeySimulator.copy()
        let clock = ContinuousClock()
        let deadline = clock.now + copyTimeout
        while pb.changeCount == baseline, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        guard pb.changeCount != baseline, let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionError.noSelection
        }
        return Selection(text: text, app: app, source: .clipboard, element: nil)
    }
}
