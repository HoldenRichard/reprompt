import AppKit
import RepromptCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onHotkeyChanged: (Hotkey) -> Void

    @State private var keyInput = ""
    @State private var keyStatus = ""
    @State private var launchAtLogin = false
    @State private var hotkeyError: String?

    var body: some View {
        Form {
            Section("API key") {
                SecureField("Anthropic API key", text: $keyInput)
                HStack {
                    Button("Save to Keychain") { saveKey() }.disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") { removeKey() }
                    Spacer()
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Hotkey") {
                HotkeyRecorder(hotkey: settings.hotkey) { new in
                    settings.hotkey = new
                    onHotkeyChanged(new)
                }
                if let hotkeyError { Text(hotkeyError).font(.caption).foregroundStyle(.red) }
            }
            Section("Optimizer") {
                Picker("Default mode", selection: $settings.mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Model", selection: $settings.modelID) {
                    ForEach(ModelCatalog.all) { Text($0.displayName).tag($0.id) }
                }
                Picker("Effort (Quick mode)", selection: $settings.effort) {
                    ForEach(Effort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled(!settings.model.supportsEffort)
                Picker("Thinking (Quick mode)", selection: $settings.thinking) {
                    Text("Adaptive").tag(ThinkingMode.adaptive)
                    Text("Disabled where allowed").tag(ThinkingMode.disabled)
                }
                Toggle("Fast mode (Opus 5 only, 2x price)", isOn: $settings.fastMode)
                    .disabled(!settings.model.supportsFastMode)
                Stepper("Max tokens: \(settings.maxTokens)", value: $settings.maxTokens, in: 256...8192, step: 256)
            }
            Section("Overlay") {
                Picker("Position", selection: $settings.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
                HStack {
                    Text(AccessibilityPermission.isTrusted ? "Accessibility: granted" : "Accessibility: not granted")
                    Spacer()
                    if !AccessibilityPermission.isTrusted {
                        Button("Request…") { AccessibilityPermission.requestIfNeeded() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            launchAtLogin = settings.launchAtLogin
            refreshKeyStatus()
        }
    }

    private func saveKey() {
        do {
            try KeychainStore.save(keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
            keyInput = ""
            refreshKeyStatus()
        } catch { keyStatus = "\(error)" }
    }

    private func removeKey() {
        do { try KeychainStore.delete(); refreshKeyStatus() } catch { keyStatus = "\(error)" }
    }

    private func refreshKeyStatus() {
        do {
            if let k = try KeychainStore.read() { keyStatus = "Saved: \(APIKeyProvider.redacted(k))" } else { keyStatus = "No key saved" }
        } catch { keyStatus = "\(error)" }
    }
}

/// Click, press a combination, done. Uses a local key monitor inside our own window: no permission needed.
struct HotkeyRecorder: View {
    var hotkey: Hotkey
    var onChange: (Hotkey) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Global hotkey")
            Spacer()
            Button(recording ? "Press keys…" : hotkey.description) { toggle() }
                .frame(minWidth: 120)
            Button("Reset") { onChange(.default) }.disabled(hotkey == .default)
        }
    }

    private func toggle() {
        if recording { stop(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let h = Hotkey.fromNSEvent(keyCode: event.keyCode, modifierFlagsRaw: event.modifierFlags.rawValue)
            if event.keyCode == 53 { stop(); return nil }  // Escape cancels
            guard h.hasModifier else { return nil }
            onChange(h)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
