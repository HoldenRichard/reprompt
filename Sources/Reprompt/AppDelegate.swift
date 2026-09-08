import AppKit
import Foundation
import RepromptCore

/// Wires the hotkey to sessions and owns the overlay. Observable so the menubar can show
/// permission state.
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let overlay = OverlayController()
    private let hotkeys = HotkeyManager()
    private var session: RepromptSession?
    private(set) var accessibilityGranted = false
    private(set) var hotkeyError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        accessibilityGranted = AccessibilityPermission.requestIfNeeded()
        hotkeys.handler = { [weak self] in self?.hotkeyPressed() }
        registerHotkey(settings.hotkey)
        if let p = try? PromptLibrary.load(.optimizer) {
            NSLog("Reprompt ready. hotkey %@, model %@, optimizer prompt %@", settings.hotkey.description, settings.modelID, p.shortHash)
        }
    }

    func registerHotkey(_ hotkey: Hotkey) {
        do {
            try hotkeys.register(hotkey)
            hotkeyError = nil
        } catch {
            hotkeyError = "\(error)"
            NSLog("Reprompt: %@", "\(error)")
        }
    }

    private func hotkeyPressed() {
        if let s = session { s.dismiss(); return }
        accessibilityGranted = AccessibilityPermission.isTrusted
        let s = RepromptSession(mode: settings.mode, settings: settings)
        s.onFinished = { [weak self] in
            self?.overlay.dismiss()
            self?.session = nil
        }
        s.onNeedsActivation = { [weak self] in self?.overlay.activateForTextInput() }
        session = s
        overlay.show(session: s, position: settings.overlayPosition)
        s.start()
    }
}
