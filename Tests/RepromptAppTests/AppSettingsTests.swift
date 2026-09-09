import Foundation
import Testing
@testable import Reprompt
@testable import RepromptCore

@Suite @MainActor struct AppSettingsTests {
    func withSuite(_ body: (String, UserDefaults) throws -> Void) rethrows {
        let name = "com.holdenrichard.reprompt.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(name, defaults)
    }

    @Test func freshSettingsUseTheDocumentedDefaults() {
        withSuite { _, defaults in
            let s = AppSettings(defaults: defaults)
            #expect(s.mode == .quick)
            #expect(s.provider == OptimizerConfig.default.provider)
            #expect(s.modelID == ModelCatalog.defaultModel(for: s.provider).id)
            #expect(s.effort == .low, "Quick mode targets low latency")
            #expect(s.maxTokens == 2048)
            #expect(s.thinking == .adaptive)
            #expect(!s.fastMode)
            #expect(s.overlayPosition == .cursor)
            #expect(s.hotkey == .default)
        }
    }

    @Test func everySettingSurvivesARelaunch() {
        withSuite { _, defaults in
            let a = AppSettings(defaults: defaults)
            a.mode = .clarify
            a.provider = .anthropic
            a.modelID = "claude-sonnet-5"
            a.effort = .xhigh
            a.maxTokens = 4096
            a.thinking = .disabled
            a.fastMode = true
            a.overlayPosition = .screenCenter
            a.hotkey = Hotkey(keyCode: 12, carbonModifiers: 0x0900)

            let b = AppSettings(defaults: defaults)
            #expect(b.mode == .clarify)
            #expect(b.provider == .anthropic)
            #expect(b.modelID == "claude-sonnet-5")
            #expect(b.effort == .xhigh)
            #expect(b.maxTokens == 4096)
            #expect(b.thinking == .disabled)
            #expect(b.fastMode)
            #expect(b.overlayPosition == .screenCenter)
            #expect(b.hotkey == Hotkey(keyCode: 12, carbonModifiers: 0x0900))
        }
    }

    /// A model removed from the catalog must not leave the app sending a dead model id.
    @Test func anUnknownStoredModelFallsBackToTheProviderDefault() {
        withSuite { _, defaults in
            defaults.set("claude-sonnet-4-20250514", forKey: "modelID")
            let s = AppSettings(defaults: defaults)
            #expect(s.modelID == ModelCatalog.defaultModel(for: s.provider).id)
        }
    }

    /// A model belonging to a different provider is as unusable as an unknown one: sending
    /// a Claude model id to Gemini is a 404 at request time.
    @Test func aStoredModelFromAnotherProviderIsRejected() {
        withSuite { _, defaults in
            defaults.set(Provider.gemini.rawValue, forKey: "provider")
            defaults.set("claude-opus-5", forKey: "modelID")
            let s = AppSettings(defaults: defaults)
            #expect(s.provider == .gemini)
            #expect(s.modelID == ModelCatalog.defaultModel(for: .gemini).id)
        }
    }

    @Test func switchingProviderCarriesTheModelWithIt() {
        withSuite { _, defaults in
            let s = AppSettings(defaults: defaults)
            s.provider = .anthropic
            #expect(s.modelID == ModelCatalog.defaultModel(for: .anthropic).id)
            s.modelID = "claude-haiku-4-5"
            s.provider = .groq
            #expect(s.modelID == ModelCatalog.defaultModel(for: .groq).id,
                    "a Claude model must not survive a switch to Groq")
            #expect(s.optimizerConfig.provider == .groq)
        }
    }

    @Test func switchingToTheSameProviderLeavesTheChosenModelAlone() {
        withSuite { _, defaults in
            let s = AppSettings(defaults: defaults)
            s.provider = .gemini
            s.modelID = "gemini-3.6-flash"
            s.provider = .gemini
            #expect(s.modelID == "gemini-3.6-flash")
        }
    }

    @Test func corruptStoredValuesFallBackInsteadOfCrashing() {
        withSuite { _, defaults in
            defaults.set("not-a-mode", forKey: "mode")
            defaults.set("not-an-effort", forKey: "effort")
            defaults.set("not-a-thinking-mode", forKey: "thinking")
            defaults.set("not-a-position", forKey: "overlayPosition")
            defaults.set(Data("garbage".utf8), forKey: "hotkey")
            defaults.set(0, forKey: "maxTokens")

            let s = AppSettings(defaults: defaults)
            #expect(s.mode == .quick)
            #expect(s.effort == .low)
            #expect(s.thinking == .adaptive)
            #expect(s.overlayPosition == .cursor)
            #expect(s.hotkey == .default)
            #expect(s.maxTokens == 2048, "a zero token budget would make every request fail")
        }
    }

    @Test func theOptimizerConfigMirrorsTheSettings() {
        withSuite { _, defaults in
            let s = AppSettings(defaults: defaults)
            s.provider = .anthropic
            s.modelID = "claude-fable-5-1"
            s.effort = .high
            s.maxTokens = 1024
            s.thinking = .disabled
            s.fastMode = true

            let c = s.optimizerConfig
            #expect(c.provider == .anthropic)
            #expect(c.model == "claude-fable-5-1")
            #expect(c.quickEffort == .high)
            #expect(c.maxTokens == 1024)
            #expect(c.quickThinking == .disabled)
            #expect(c.fastMode)
            #expect(c.useFallbacks)
            #expect(c.clarifyEffort == .medium)
        }
    }

    @Test func modelLookupResolvesThroughTheCatalog() {
        withSuite { _, defaults in
            let s = AppSettings(defaults: defaults)
            s.provider = .anthropic
            s.modelID = "claude-haiku-4-5"
            #expect(s.model.displayName == "Claude Haiku 4.5")
            #expect(!s.model.supportsEffort)
        }
    }

    @Test func modeAndPositionCarryTheirDisplayMetadata() {
        #expect(Mode.allCases == [.quick, .clarify])
        #expect(Mode.quick.title == "Quick")
        #expect(Mode.clarify.title == "Clarify")
        #expect(Mode.quick.symbol != Mode.clarify.symbol, "the menubar icon distinguishes the modes")
        #expect(OverlayPosition.allCases.map(\.title) == ["Near cursor", "Screen center"])
    }

    @Test func writesGoToTheInjectedSuiteNotTheRealOne() {
        withSuite { name, defaults in
            let s = AppSettings(defaults: defaults)
            s.maxTokens = 777
            #expect(defaults.integer(forKey: "maxTokens") == 777)
            #expect(UserDefaults.standard.object(forKey: "maxTokens") == nil || UserDefaults.standard.integer(forKey: "maxTokens") != 777)
            _ = name
        }
    }
}

@Suite @MainActor struct AppearanceSettingTests {
    @Test func defaultsToFollowingTheSystem() {
        let name = "com.holdenrichard.reprompt.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let s = AppSettings(defaults: defaults)
        #expect(s.appearance == .system)
        #expect(s.appearance.nsAppearance == nil, "system means no override, not no appearance")
    }

    @Test func eachChoiceMapsToTheRightAppearanceAndPersists() {
        let name = "com.holdenrichard.reprompt.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(AppearanceSetting.light.nsAppearance?.name == .aqua)
        #expect(AppearanceSetting.dark.nsAppearance?.name == .darkAqua)
        #expect(AppearanceSetting.allCases.map(\.title) == ["Match system", "Light", "Dark"])

        let a = AppSettings(defaults: defaults)
        a.appearance = .dark
        #expect(AppSettings(defaults: defaults).appearance == .dark)
    }

    @Test func aCorruptStoredAppearanceFallsBack() {
        let name = "com.holdenrichard.reprompt.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set("neon", forKey: "appearance")
        #expect(AppSettings(defaults: defaults).appearance == .system)
    }
}
