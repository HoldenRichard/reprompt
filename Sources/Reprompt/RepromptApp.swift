import SwiftUI

@main
struct RepromptApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(settings: delegate.settings, accessibilityGranted: delegate.accessibilityGranted)
        } label: {
            Image(nsImage: MenubarIcon.image(for: delegate.settings.mode))
        }
        Settings {
            SettingsView(settings: delegate.settings, hotkeyError: delegate.hotkeyError) {
                delegate.registerHotkey($0)
            }
        }
    }
}
