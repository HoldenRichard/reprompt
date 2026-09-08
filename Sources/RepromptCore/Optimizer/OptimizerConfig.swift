import Foundation

public enum ThinkingMode: String, Codable, Sendable, CaseIterable {
    case adaptive, disabled
}

/// Everything that shapes an optimizer request. Serialized into harness run records and
/// mirrored by the app's settings.
public struct OptimizerConfig: Codable, Sendable, Equatable {
    public var model: String
    public var quickEffort: Effort
    public var clarifyEffort: Effort
    public var maxTokens: Int
    public var quickThinking: ThinkingMode
    public var fastMode: Bool
    public var useFallbacks: Bool

    public init(
        model: String = ModelCatalog.default.id,
        quickEffort: Effort = .low,
        clarifyEffort: Effort = .medium,
        maxTokens: Int = 2048,
        quickThinking: ThinkingMode = .adaptive,
        fastMode: Bool = false,
        useFallbacks: Bool = true
    ) {
        self.model = model
        self.quickEffort = quickEffort
        self.clarifyEffort = clarifyEffort
        self.maxTokens = maxTokens
        self.quickThinking = quickThinking
        self.fastMode = fastMode
        self.useFallbacks = useFallbacks
    }

    public static let `default` = OptimizerConfig()
}

public enum RequestBuilder {
    /// Applies the model's capability flags so no rejected parameter is sent.
    public static func build(
        model modelID: String,
        system: String?,
        user: String,
        maxTokens: Int,
        effort: Effort?,
        thinking: ThinkingMode?,
        fastMode: Bool,
        useFallbacks: Bool,
        format: OutputFormat? = nil,
        stream: Bool
    ) -> MessageRequest {
        let m = ModelCatalog.infoOrGeneric(for: modelID)
        var thinkingParam: Thinking? = nil
        switch m.thinking {
        case .budgetOnly: thinkingParam = nil
        case .alwaysOn: thinkingParam = nil
        case .adaptive(let disabledUpTo):
            switch thinking {
            case .disabled? where disabledUpTo != nil && (effort ?? .high).isAtMost(disabledUpTo!):
                thinkingParam = .disabled
            case .adaptive?, .disabled?: thinkingParam = .adaptive
            case nil: thinkingParam = nil
            }
        }
        var output: OutputConfig? = nil
        let eff: Effort? = m.supportsEffort ? effort : nil
        if eff != nil || format != nil { output = OutputConfig(effort: eff, format: format) }
        return MessageRequest(
            model: modelID,
            maxTokens: maxTokens,
            system: system.map { [SystemBlock(text: $0)] },
            messages: [.user(user)],
            stream: stream,
            thinking: thinkingParam,
            outputConfig: output,
            fallbacks: (useFallbacks && m.supportsFallbacks) ? .default : nil,
            speed: (fastMode && m.supportsFastMode) ? .fast : nil
        )
    }
}
