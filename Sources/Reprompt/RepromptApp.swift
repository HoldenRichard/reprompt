import SwiftUI

@main
struct RepromptApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(settings: delegate.settings, accessibilityGranted: delegate.accessibilityGranted)
        } label: {
            Image(systemName: delegate.settings.mode == .quick ? "text.badge.checkmark" : "text.badge.plus")
        }
        Settings {
            SettingsView(settings: delegate.settings) { delegate.registerHotkey($0) }
        }
    }
}
