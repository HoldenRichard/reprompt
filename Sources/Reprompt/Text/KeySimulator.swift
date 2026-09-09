import AppKit
import CoreGraphics

/// Posts synthetic Cmd+key presses. Requires the Accessibility grant
/// (`CGPreflightPostEventAccess`).
enum KeySimulator {
    static let keyA: CGKeyCode = 0
    static let keyC: CGKeyCode = 8
    static let keyV: CGKeyCode = 9

    /// The hotkey fires on key-DOWN, so the user is usually still holding its modifiers when
    /// the synthetic copy goes out. A private event source keeps the hardware modifier state
    /// out of the posted event, and this short wait avoids racing the release: without both,
    /// a Cmd+Shift+R hotkey turns the copy into Cmd+Shift+C, which is a different command in
    /// Chrome, Slack and Terminal.
    static func waitForModifiersToClear(timeout: Duration = .milliseconds(300)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let held = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
            if held.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func press(_ key: CGKeyCode, flags: CGEventFlags = .maskCommand) {
        // .privateState does not combine with the physical keyboard's modifier state.
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func selectAll() { press(keyA) }
    static func copy() { press(keyC) }
    static func paste() { press(keyV) }
}
