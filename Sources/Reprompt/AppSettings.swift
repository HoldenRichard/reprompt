import Foundation
import RepromptCore
import ServiceManagement

enum Mode: String, Codable, CaseIterable, Identifiable {
    case quick, clarify
    var id: String { rawValue }
    var title: String { self == .quick ? "Quick" : "Clarify" }
    var symbol: String { self == .quick ? "bolt.fill" : "questionmark.bubble.fill" }
}

enum OverlayPosition: String, Codable, CaseIterable, Identifiable {
    case cursor, screenCenter
    var id: String { rawValue }
    var title: String { self == .cursor ? "Near cursor" : "Screen center" }
}

/// A global hotkey in Carbon terms. Default Cmd+Shift+R.
struct Hotkey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = Hotkey(keyCode: 15 /* kVK_ANSI_R */, carbonModifiers: UInt32(cmdKey | shiftKey))

    var description: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Hotkey.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
            14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "key\(code)"
    }
}

private let cmdKey: Int = 1 << 8
private let shiftKey: Int = 1 << 9
private let optionKey: Int = 1 << 11
private let controlKey: Int = 1 << 12

extension Hotkey {
    /// Build from an NSEvent-style modifier mask (raw NSEvent.ModifierFlags value).
    static func fromNSEvent(keyCode: UInt16, modifierFlagsRaw: UInt) -> Hotkey {
        var m: UInt32 = 0
        if modifierFlagsRaw & (1 << 20) != 0 { m |= UInt32(cmdKey) }      // .command
        if modifierFlagsRaw & (1 << 17) != 0 { m |= UInt32(shiftKey) }    // .shift
        if modifierFlagsRaw & (1 << 19) != 0 { m |= UInt32(optionKey) }   // .option
        if modifierFlagsRaw & (1 << 18) != 0 { m |= UInt32(controlKey) }  // .control
        return Hotkey(keyCode: UInt32(keyCode), carbonModifiers: m)
    }
    var hasModifier: Bool { carbonModifiers != 0 }
}

/// User settings, UserDefaults-backed. Observed by the menubar, overlay, and settings UI.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let mode = "mode", model = "modelID", effort = "effort", maxTokens = "maxTokens"
        static let thinking = "thinking", fastMode = "fastMode", position = "overlayPosition", hotkey = "hotkey"
    }

    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    var modelID: String { didSet { defaults.set(modelID, forKey: Key.model) } }
    var effort: Effort { didSet { defaults.set(effort.rawValue, forKey: Key.effort) } }
    var maxTokens: Int { didSet { defaults.set(maxTokens, forKey: Key.maxTokens) } }
    var thinking: ThinkingMode { didSet { defaults.set(thinking.rawValue, forKey: Key.thinking) } }
    var fastMode: Bool { didSet { defaults.set(fastMode, forKey: Key.fastMode) } }
    var overlayPosition: OverlayPosition { didSet { defaults.set(overlayPosition.rawValue, forKey: Key.position) } }
    var hotkey: Hotkey {
        didSet { if let d = try? JSONEncoder().encode(hotkey) { defaults.set(d, forKey: Key.hotkey) } }
    }

    private init() {
        mode = Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .quick
        let storedModel = defaults.string(forKey: Key.model) ?? ""
        modelID = ModelCatalog.info(for: storedModel) != nil ? storedModel : ModelCatalog.default.id
        effort = Effort(rawValue: defaults.string(forKey: Key.effort) ?? "") ?? .low
        let mt = defaults.integer(forKey: Key.maxTokens)
        maxTokens = mt > 0 ? mt : 2048
        thinking = ThinkingMode(rawValue: defaults.string(forKey: Key.thinking) ?? "") ?? .adaptive
        fastMode = defaults.bool(forKey: Key.fastMode)
        overlayPosition = OverlayPosition(rawValue: defaults.string(forKey: Key.position) ?? "") ?? .cursor
        if let d = defaults.data(forKey: Key.hotkey), let h = try? JSONDecoder().decode(Hotkey.self, from: d) {
            hotkey = h
        } else {
            hotkey = .default
        }
    }

    var model: ModelInfo { ModelCatalog.infoOrGeneric(for: modelID) }

    var optimizerConfig: OptimizerConfig {
        OptimizerConfig(model: modelID, quickEffort: effort, clarifyEffort: .medium, maxTokens: maxTokens,
                        quickThinking: thinking, fastMode: fastMode, useFallbacks: true)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Reprompt: launch at login change failed: \(error)")
            }
        }
    }
}
