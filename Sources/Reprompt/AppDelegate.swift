import AppKit
import Foundation
import RepromptCore

/// Wires the hotkey to sessions and owns the overlay.
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let overlay = OverlayController()
    private let hotkeys = HotkeyManager()
    private var session: RepromptSession?
    private(set) var accessibilityGranted = false
    /// Non-nil when the chosen combination could not be registered.
    private(set) var hotkeyError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings.applyAppearance()
        accessibilityGranted = AccessibilityPermission.requestIfNeeded()
        hotkeys.handler = { [weak self] in self?.hotkeyPressed() }
        registerHotkey(settings.hotkey)
        // Permission is granted in System Settings, so re-check whenever we come back.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        if let p = try? PromptLibrary.load(.optimizer) {
            NSLog("Reprompt ready. hotkey %@, model %@, optimizer prompt %@",
                  settings.hotkey.description, settings.modelID, p.shortHash)
        }
    }

    func refreshPermissions() {
        accessibilityGranted = AccessibilityPermission.isTrusted
    }

    /// Registers `hotkey` and persists it only if that succeeded, keeping the previous one
    /// otherwise. Unregistering first, or saving before registering, left the app with a
    /// hotkey that does not work and survives relaunch.
    @discardableResult
    func registerHotkey(_ hotkey: Hotkey) -> Bool {
        do {
            try hotkeys.register(hotkey)
            hotkeyError = nil
            if settings.hotkey != hotkey { settings.hotkey = hotkey }
            return true
        } catch {
            hotkeyError = "\(error)"
            NSLog("Reprompt: %@", "\(error)")
            return false
        }
    }

    private func hotkeyPressed() {
        if let s = session { s.dismiss(); return }
        refreshPermissions()
        let s = RepromptSession(
            mode: settings.mode, settings: settings,
            reader: SelectionReader(selectAllWhenEmpty: settings.selectAllWhenEmpty))
        s.onFinished = { [weak self] in
            self?.overlay.dismiss()
            self?.session = nil
        }
        s.onReadyForKeyboard = { [weak self] in self?.overlay.takeKeyFocus() }
        s.onNeedsActivation = { [weak self] in self?.overlay.activateForTextInput() }
        s.onWillInsertText = { [weak self] in self?.overlay.relinquishFocusForInsertion() }
        s.onInsertFailed = { [weak self] in self?.overlay.reveal() }
        session = s
        overlay.show(session: s, position: settings.overlayPosition)
        s.start()
    }
}
