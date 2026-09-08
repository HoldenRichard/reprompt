import Carbon.HIToolbox
import Foundation

enum HotkeyError: Error, CustomStringConvertible {
    case install(OSStatus)
    case register(OSStatus)
    var description: String {
        switch self {
        case .install(let s): "InstallEventHandler failed (\(s))"
        case .register(let s): "RegisterEventHotKey failed (\(s)); the combination may be taken by another app"
        }
    }
}

/// Global hotkey via Carbon `RegisterEventHotKey`. Needs no permission and fires even when
/// the frontmost app binds the same keys locally.
final class HotkeyManager {
    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x5250_5054  // 'RPPT'

    func register(_ hotkey: Hotkey) throws {
        unregisterHotkey()
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetEventDispatcherTarget(), hotkeyEventCallback, 1, &spec,
                Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard status == noErr else { throw HotkeyError.install(status) }
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr else { throw HotkeyError.register(status) }
    }

    func unregisterHotkey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    /// The manager lives for the app's lifetime; call this only when tearing down explicitly.
    func shutdown() {
        unregisterHotkey()
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}

/// C callback: no Swift context captured; `userData` carries the manager. Carbon dispatches
/// on the main run loop, so hopping onto the main actor is an assertion, not a hop.
private let hotkeyEventCallback: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.handler?() }
    return noErr
}
