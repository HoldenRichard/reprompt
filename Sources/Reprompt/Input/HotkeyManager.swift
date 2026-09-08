import Carbon.HIToolbox
import Foundation

enum HotkeyError: Error, CustomStringConvertible, Equatable {
    case install(OSStatus)
    case register(OSStatus)
    var description: String {
        switch self {
        case .install(let s): "Could not install the hotkey handler (\(s))."
        case .register(let s): "That key combination is unavailable (\(s)); another app is probably using it."
        }
    }
}

/// Global hotkey via Carbon `RegisterEventHotKey`, which needs no permission and fires even
/// when the frontmost app binds the same keys locally.
final class HotkeyManager {
    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var current: Hotkey?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x5250_5054  // 'RPPT'

    /// Registers the new combination BEFORE releasing the old one. Releasing first meant a
    /// combination already taken by another app left Reprompt with no hotkey at all, and no
    /// way to reach the app to fix it.
    func register(_ hotkey: Hotkey) throws {
        if current == hotkey, hotKeyRef != nil { return }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetEventDispatcherTarget(), hotkeyEventCallback, 1, &spec,
                Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard status == noErr else { throw HotkeyError.install(status) }
        }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id,
                                         GetEventDispatcherTarget(), 0, &newRef)
        guard status == noErr, newRef != nil else { throw HotkeyError.register(status) }
        nextID &+= 1
        if let old = hotKeyRef { UnregisterEventHotKey(old) }
        hotKeyRef = newRef
        current = hotkey
    }

    func unregisterHotkey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        current = nil
    }

    /// The manager lives for the app's lifetime; call this only when tearing down explicitly.
    func shutdown() {
        unregisterHotkey()
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}

/// C callback: no Swift context is captured, so `userData` carries the manager. Carbon
/// dispatches hot-key events on the main run loop.
private let hotkeyEventCallback: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.handler?() }
    return noErr
}
