import AppKit
import RepromptCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    /// Non-nil when the current hotkey could not be registered.
    var hotkeyError: String?
    /// Returns true when the new combination was accepted.
    var onHotkeyChanged: (Hotkey) -> Bool

    @State private var keyInput = ""
    @State private var keyStatus = ""
    @State private var launchAtLogin = false
    @State private var launchError: String?
    @State private var accessibilityGranted = AccessibilityPermission.isTrusted

    var body: some View {
        Form {
            Section("API key") {
                SecureField("Anthropic API key", text: $keyInput)
                HStack {
                    Button("Save to Keychain") { saveKey() }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") { removeKey() }
                    Spacer()
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Hotkey") {
                HotkeyRecorder(hotkey: settings.hotkey, onChange: onHotkeyChanged)
                if let hotkeyError {
                    Text(hotkeyError).font(.caption).foregroundStyle(.red)
                }
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
                    .onChange(of: launchAtLogin) { _, wanted in setLaunchAtLogin(wanted) }
                if settings.launchAtLoginStatus == .requiresApproval {
                    Text("Approve Reprompt in System Settings > General > Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text(accessibilityGranted ? "Accessibility: granted" : "Accessibility: not granted")
                    Spacer()
                    if !accessibilityGranted {
                        Button("Request…") {
                            accessibilityGranted = AccessibilityPermission.requestIfNeeded()
                        }
                        Button("Re-check") { accessibilityGranted = AccessibilityPermission.isTrusted }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            launchAtLogin = settings.launchAtLogin
            accessibilityGranted = AccessibilityPermission.isTrusted
            refreshKeyStatus()
        }
    }

    private func setLaunchAtLogin(_ wanted: Bool) {
        do {
            try settings.setLaunchAtLogin(wanted)
            launchError = nil
        } catch {
            launchError = "\(error)"
            // Put the toggle back where reality is, rather than leaving it lying.
            launchAtLogin = settings.launchAtLogin
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
            if let k = try KeychainStore.read() {
                keyStatus = "Saved: \(APIKeyProvider.redacted(k))"
            } else {
                keyStatus = "No key saved"
            }
        } catch { keyStatus = "\(error)" }
    }
}

/// Click, press a combination, done. A local monitor inside our own window needs no
/// permission. It is torn down on disappear: a leaked monitor that returns nil swallows
/// every keystroke in the app, including the overlay's shortcuts and the API-key field.
struct HotkeyRecorder: View {
    var hotkey: Hotkey
    var onChange: (Hotkey) -> Bool
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack {
            Text("Global hotkey")
            Spacer()
            Button(recording ? "Press keys…" : hotkey.description) { toggle() }
                .frame(minWidth: 120)
            Button("Reset") { _ = onChange(.default) }
                .disabled(hotkey == .default)
        }
        .onDisappear { stop() }
        .overlay(alignment: .bottomLeading) {
            if rejected {
                Text("That combination is in use; the previous hotkey is still active.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func toggle() {
        if recording { stop(); return }
        rejected = false
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }  // Escape cancels recording
            let h = Hotkey.fromNSEvent(keyCode: event.keyCode, modifierFlagsRaw: event.modifierFlags.rawValue)
            // Pass through anything that is not a candidate, so the rest of the UI keeps working.
            guard h.hasModifier else { return event }
            rejected = !onChange(h)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
