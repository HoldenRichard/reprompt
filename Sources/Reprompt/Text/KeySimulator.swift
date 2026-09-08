import CoreGraphics

/// Posts synthetic Cmd+key presses. Requires the Accessibility grant (`CGPreflightPostEventAccess`).
enum KeySimulator {
    static let keyC: CGKeyCode = 8
    static let keyV: CGKeyCode = 9

    static func press(_ key: CGKeyCode, flags: CGEventFlags = .maskCommand) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func copy() { press(keyC) }
    static func paste() { press(keyV) }
}
