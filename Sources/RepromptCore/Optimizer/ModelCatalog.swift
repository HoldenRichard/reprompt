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
    public let displayName: String
    public let supportsEffort: Bool
    public let thinking: ThinkingSupport
    public let supportsFallbacks: Bool
    public let supportsFastMode: Bool
    /// USD per million tokens.
    public let inputPricePerMTok: Double
    public let outputPricePerMTok: Double

    public func cost(usage: Usage) -> Double {
        let cached = Double(usage.cacheReadInputTokens ?? 0)
        let uncached = Double(usage.inputTokens) - cached
        return (uncached * inputPricePerMTok + cached * inputPricePerMTok * 0.1 + Double(usage.outputTokens) * outputPricePerMTok) / 1_000_000
    }
}

/// The models Reprompt offers. Capability flags keep the request builder from sending a
/// parameter a given model rejects (effort on Haiku 4.5, thinking-disabled on Fable 5.1, ...).
public enum ModelCatalog {
    public static let opus5 = ModelInfo(
        id: "claude-opus-5", displayName: "Claude Opus 5",
        supportsEffort: true, thinking: .adaptive(disabledUpToEffort: .high),
        supportsFallbacks: true, supportsFastMode: true,
        inputPricePerMTok: 5, outputPricePerMTok: 25)
    public static let sonnet5 = ModelInfo(
        id: "claude-sonnet-5", displayName: "Claude Sonnet 5",
        supportsEffort: true, thinking: .adaptive(disabledUpToEffort: .max),
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 2, outputPricePerMTok: 10)
    public static let haiku45 = ModelInfo(
        id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5",
        supportsEffort: false, thinking: .budgetOnly,
        supportsFallbacks: false, supportsFastMode: false,
        inputPricePerMTok: 1, outputPricePerMTok: 5)
    public static let fable51 = ModelInfo(
        id: "claude-fable-5-1", displayName: "Claude Fable 5.1",
        supportsEffort: true, thinking: .alwaysOn,
        supportsFallbacks: true, supportsFastMode: false,
        inputPricePerMTok: 10, outputPricePerMTok: 50)

    public static let all: [ModelInfo] = [opus5, sonnet5, haiku45, fable51]
    public static let `default` = opus5

    public static func info(for id: String) -> ModelInfo? { all.first { $0.id == id } }

    /// Unknown IDs get conservative flags: no effort, no thinking param, no betas.
    public static func infoOrGeneric(for id: String) -> ModelInfo {
        info(for: id) ?? ModelInfo(
            id: id, displayName: id, supportsEffort: false, thinking: .budgetOnly,
            supportsFallbacks: false, supportsFastMode: false,
            inputPricePerMTok: 0, outputPricePerMTok: 0)
    }
}

extension Effort {
    var rank: Int { Effort.allCases.firstIndex(of: self) ?? 0 }
    public func isAtMost(_ other: Effort) -> Bool { rank <= other.rank }
}
