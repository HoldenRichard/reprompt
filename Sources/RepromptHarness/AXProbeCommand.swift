import AppKit
import ApplicationServices
import ArgumentParser
import Carbon.HIToolbox
import Foundation

/// Diagnostic for Phase 2: after a delay, report what the Accessibility API sees in the
/// frontmost app, and optionally try to replace the selection. Run it from a terminal that
/// has Accessibility permission, switch to the target app, select text, and wait.
struct AXProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "axprobe", abstract: "Report AX focused element and selected text of the frontmost app after a delay.")

    @Option(name: .long, help: "Seconds to wait before probing.") var delay: Double = 3
    @Option(name: .long, help: "Replace the selection with this text via AX.") var replace: String?
    @Option(name: .long, help: "AX messaging timeout in seconds.") var timeout: Float = 0.3

    mutating func run() async throws {
        eprint("switch to the target app and select text; probing in \(delay)s ...")
        try await Task.sleep(for: .seconds(delay))
        let replace = self.replace
        let timeout = self.timeout
        await MainActor.run { Self.probe(replace: replace, timeout: timeout) }
    }

    @MainActor
    static func probe(replace: String?, timeout: Float) {
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: false] as CFDictionary)
        let front = NSWorkspace.shared.frontmostApplication
        print("frontmost: \(front?.localizedName ?? "?") (\(front?.bundleIdentifier ?? "?"))")
        print("AX trusted: \(trusted)   can post events: \(CGPreflightPostEventAccess())   secure input: \(IsSecureEventInputEnabled())")
        guard trusted else { print("grant Accessibility to the terminal app, then retry"); return }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var focusedRef: CFTypeRef?
        let clock = ContinuousClock()
        let t0 = clock.now
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        print("focused element: \(err.rawValue == 0 ? "ok" : "AXError \(err.rawValue)") in \(fmtMs(clock.now - t0))")
        guard err == .success, let focusedRef else { return }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, timeout)

        func attr(_ name: String) -> (AXError, CFTypeRef?) {
            var v: CFTypeRef?
            let e = AXUIElementCopyAttributeValue(focused, name as CFString, &v)
            return (e, v)
        }
        let (_, role) = attr(kAXRoleAttribute)
        let (_, subrole) = attr(kAXSubroleAttribute)
        print("role: \(role as? String ?? "?")  subrole: \(subrole as? String ?? "-")")
        let t1 = clock.now
        let (selErr, selected) = attr(kAXSelectedTextAttribute)
        let selText = selected as? String
        print("selected text: \(selErr == .success ? "ok" : "AXError \(selErr.rawValue)") in \(fmtMs(clock.now - t1)); \(selText?.count ?? 0) chars")
        if let selText, !selText.isEmpty { print("  \"\(selText.prefix(120))\"") }
        var settable: DarwinBoolean = false
        let setErr = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)
        print("selected text settable: \(setErr == .success ? settable.boolValue.description : "AXError \(setErr.rawValue)")")

        if let replace {
            let e = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, replace as CFString)
            print("set selected text: \(e == .success ? "ok" : "AXError \(e.rawValue)")")
            let (_, after) = attr(kAXSelectedTextAttribute)
            print("re-read selection: \"\((after as? String ?? "").prefix(120))\"")
            let (_, value) = attr(kAXValueAttribute)
            if let v = value as? String { print("field now contains replacement: \(v.contains(replace))") }
        }
    }
}
