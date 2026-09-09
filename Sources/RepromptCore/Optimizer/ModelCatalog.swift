import Foundation

public enum ThinkingSupport: Sendable, Equatable {
    /// 4.6+ models: `adaptive` or omit; `disabled` allowed per `disabledUpToEffort`.
    case adaptive(disabledUpToEffort: Effort?)
    /// Pre-4.6 API (`budget_tokens`); we omit `thinking` entirely on these.
    case budgetOnly
    /// Always on; `disabled` returns 400.
    case alwaysOn
}

public struct ModelInfo: Sendable, Identifiable, Equatable {
    public let id: String
    public let provider: Provider
    public let displayName: String
    public let supportsEffort: Bool
    public let thinking: ThinkingSupport
    public let supportsFallbacks: Bool
    public let supportsFastMode: Bool
    /// USD per million tokens.
    public let inputPricePerMTok: Double
    public let outputPricePerMTok: Double

    /// `input_tokens` already excludes cache reads and cache creation, which the API
    /// reports in their own fields; cache reads bill at 0.1x and 5-minute writes at 1.25x.
    public func cost(usage: Usage) -> Double {
        let read = Double(usage.cacheReadInputTokens ?? 0)
        let written = Double(usage.cacheCreationInputTokens ?? 0)
        let fresh = Double(usage.inputTokens)
        return (fresh * inputPricePerMTok
            + read * inputPricePerMTok * 0.1
            + written * inputPricePerMTok * 1.25
            + Double(usage.outputTokens) * outputPricePerMTok) / 1_000_000
    }
}

/// The models Reprompt offers. Capability flags keep the request builder from sending a
/// parameter a given model rejects (effort on Haiku 4.5, thinking-disabled on Fable 5.1, ...).
public enum ModelCatalog {
    // MARK: Anthropic — billed per token
    public static let opus5 = ModelInfo(
        id: "claude-opus-5", provider: .anthropic, displayName: "Claude Opus 5",
        supportsEffort: true, thinking: .adaptive(disabledUpToEffort: .high),
        supportsFallbacks: true, supportsFastMode: true,
        inputPricePerMTok: 5, outputPricePerMTok: 25)
    public static let sonnet5 = ModelInfo(
        id: "claude-sonnet-5", provider: .anthropic, displayName: "Claude Sonnet 5",
        supportsEffort: true, thinking: .adaptive(disabledUpToEffort: .max),
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 2, outputPricePerMTok: 10)
    public static let haiku45 = ModelInfo(
        id: "claude-haiku-4-5", provider: .anthropic, displayName: "Claude Haiku 4.5",
        supportsEffort: false, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 1, outputPricePerMTok: 5)
    public static let fable51 = ModelInfo(
        id: "claude-fable-5-1", provider: .anthropic, displayName: "Claude Fable 5.1",
        supportsEffort: true, thinking: .alwaysOn,
        supportsFallbacks: true, supportsFastMode: false,
        inputPricePerMTok: 10, outputPricePerMTok: 50)

    // MARK: Groq — free tier, no per-token charge, so every price is zero.
    // Groq updates its lineup often; `reprompt-harness models` lists what is actually live.
    public static let gptOSS120b = ModelInfo(
        id: "openai/gpt-oss-120b", provider: .groq, displayName: "GPT-OSS 120B",
        supportsEffort: true, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 0, outputPricePerMTok: 0)
    public static let gptOSS20b = ModelInfo(
        id: "openai/gpt-oss-20b", provider: .groq, displayName: "GPT-OSS 20B",
        supportsEffort: true, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 0, outputPricePerMTok: 0)
    public static let qwen38 = ModelInfo(
        id: "qwen/qwen3.8-27b", provider: .groq, displayName: "Qwen 3.8 27B",
        supportsEffort: false, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 0, outputPricePerMTok: 0)
    public static let qwen36 = ModelInfo(
        id: "qwen/qwen3.6-27b", provider: .groq, displayName: "Qwen 3.6 27B",
        supportsEffort: false, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 0, outputPricePerMTok: 0)

    // MARK: Google Gemini — billed, but covered by Google AI Pro's monthly credits.
    // Verified against a live account on 2026-09-09 with `reprompt-harness models`.
    // Gemini 3.8 Flash carries an introductory rate that doubles on 2027-01-01.
    public static let gemini38Flash = ModelInfo(
        id: "gemini-3.8-flash", provider: .gemini, displayName: "Gemini 3.8 Flash",
        supportsEffort: false, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 0.75, outputPricePerMTok: 3.75)
    public static let gemini31Pro = ModelInfo(
        id: "gemini-3.1-pro-preview", provider: .gemini, displayName: "Gemini 3.1 Pro",
        supportsEffort: false, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 2.00, outputPricePerMTok: 12.00)
    public static let gemini36Flash = ModelInfo(
        id: "gemini-3.6-flash", provider: .gemini, displayName: "Gemini 3.6 Flash",
        supportsEffort: false, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 0.75, outputPricePerMTok: 3.75)
    public static let geminiFlashLite = ModelInfo(
        id: "gemini-3.5-flash-lite", provider: .gemini, displayName: "Gemini 3.5 Flash Lite",
        supportsEffort: false, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 0.30, outputPricePerMTok: 2.50)

    public static let anthropicModels: [ModelInfo] = [opus5, sonnet5, haiku45, fable51]
    public static let geminiModels: [ModelInfo] = [gemini38Flash, gemini31Pro, gemini36Flash, geminiFlashLite]
    public static let groqModels: [ModelInfo] = [gptOSS120b, gptOSS20b, qwen38, qwen36]
    public static let all: [ModelInfo] = anthropicModels + geminiModels + groqModels
    public static let `default` = opus5

    public static func models(for provider: Provider) -> [ModelInfo] {
        switch provider {
        case .anthropic: anthropicModels
        case .gemini: geminiModels
        case .groq: groqModels
        }
    }

    public static func defaultModel(for provider: Provider) -> ModelInfo {
        switch provider {
        case .anthropic: opus5
        case .gemini: gemini38Flash
        case .groq: gptOSS120b
        }
    }

    public static func info(for id: String) -> ModelInfo? { all.first { $0.id == id } }

    /// Unknown IDs get conservative flags: no effort, no thinking param, no betas.
    public static func infoOrGeneric(for id: String) -> ModelInfo {
        info(for: id) ?? ModelInfo(
            id: id, provider: .anthropic, displayName: id, supportsEffort: false, thinking: .budgetOnly,
            supportsFallbacks: false, supportsFastMode: false,
            inputPricePerMTok: 0, outputPricePerMTok: 0)
    }
}

extension Effort {
    var rank: Int { Effort.allCases.firstIndex(of: self) ?? 0 }
    public func isAtMost(_ other: Effort) -> Bool { rank <= other.rank }
}
