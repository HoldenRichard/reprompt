import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Accessibility is needed to read the selection via AX and to post the Cmd+C / Cmd+V
/// events used by the clipboard fallback. Input Monitoring is never needed: nothing listens.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once if not yet trusted. Returns the current state.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        // The C global `kAXTrustedCheckOptionPrompt` is not usable under Swift 6 strict concurrency.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary)
    }

    static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    static var secureInputActive: Bool { IsSecureEventInputEnabled() }
}
