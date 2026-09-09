import RepromptCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var settings: AppSettings
    var accessibilityGranted: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Reprompt  \(settings.hotkey.description)")
        if !accessibilityGranted {
            Button("Grant Accessibility permission…") { AccessibilityPermission.requestIfNeeded() }
        }
        Divider()
        Picker("Mode", selection: $settings.mode) {
            ForEach(Mode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
        }
        .pickerStyle(.inline)
        Divider()
        Menu("Model: \(settings.model.displayName)") {
            Picker("Model", selection: $settings.modelID) {
                ForEach(ModelCatalog.models(for: settings.provider)) { m in Text(m.displayName).tag(m.id) }
            }
            .pickerStyle(.inline)
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Quit Reprompt") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
