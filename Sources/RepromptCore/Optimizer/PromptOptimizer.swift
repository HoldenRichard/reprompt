import Foundation

public struct OptimizeResult: Sendable, Equatable {
    public var text: String
    public var requestedModel: String
    public var servedModel: String
    public var ttfb: Duration
    public var total: Duration
    public var usage: Usage
    public var stopReason: StopReason?
    public var promptHash: String
}

public struct ClarifyResult: Sendable, Equatable {
    public var questions: ClarifyQuestions
    public var servedModel: String
    public var total: Duration
    public var usage: Usage
    public var promptHash: String
}

/// The optimizer: quick rewrite, clarifying questions, and the answers-informed rewrite.
public struct PromptOptimizer: Sendable {
    public let client: ClaudeClient
    public var config: OptimizerConfig
    public let prompts: PromptSet

    public init(client: ClaudeClient, config: OptimizerConfig = .default, prompts: PromptSet) {
        self.client = client
        self.config = config
        self.prompts = prompts
    }

    // MARK: Request construction

    public static func userMessage(original: String, answers: [ClarifyAnswer]) -> String {
        var s = "<original_prompt>\n\(original)\n</original_prompt>"
        if !answers.isEmpty {
            s += "\n\n<clarifications>\n"
            for a in answers {
                s += "Q: \(a.question)\nA: \(a.answer.isEmpty ? "(no answer; use best judgment)" : a.answer)\n"
            }
            s += "</clarifications>"
        }
        return s
    }

    public func rewriteRequest(original: String, answers: [ClarifyAnswer], stream: Bool) -> MessageRequest {
        let system = answers.isEmpty ? prompts.optimizer : prompts.clarifyFinal
        let effort = answers.isEmpty ? config.quickEffort : config.clarifyEffort
        return RequestBuilder.build(
            model: config.model, system: system.text,
            user: Self.userMessage(original: original, answers: answers),
            maxTokens: config.maxTokens, effort: effort,
            thinking: config.quickThinking, fastMode: config.fastMode,
            useFallbacks: config.useFallbacks, stream: stream)
    }

    public func questionsRequest(original: String) -> MessageRequest {
        RequestBuilder.build(
            model: config.model, system: prompts.clarifyQuestions.text,
            user: Self.userMessage(original: original, answers: []),
            maxTokens: 1024, effort: config.clarifyEffort,
            thinking: .adaptive, fastMode: config.fastMode,
            useFallbacks: config.useFallbacks,
            format: OutputFormat(schema: ClarifyQuestions.jsonSchema), stream: false)
    }

    // MARK: Calls

    public func optimizeStream(_ original: String, answers: [ClarifyAnswer] = []) -> AsyncThrowingStream<StreamEvent, any Error> {
        client.stream(rewriteRequest(original: original, answers: answers, stream: true))
    }

    /// Collects the stream, timing first token and completion. Fails on refusal and truncation.
    public func optimize(_ original: String, answers: [ClarifyAnswer] = []) async throws -> OptimizeResult {
        let clock = ContinuousClock()
        let start = clock.now
        var firstToken: ContinuousClock.Instant? = nil
        var text = ""
        var served = config.model
        var inputTokens = 0
        var outputTokens = 0
        var stop: StopReason? = nil
        for try await event in optimizeStream(original, answers: answers) {
            switch event {
            case .messageStart(let model, let input): served = model; inputTokens = input
            case .blockStart(_, _, let fallbackTo): if let fallbackTo { served = fallbackTo }
            case .textDelta(let t):
                if firstToken == nil { firstToken = clock.now }
                text += t
            case .messageDelta(let reason, let out): stop = reason; outputTokens = out
            case .messageStop, .ping: break
            case .error(let e): throw e
            }
        }
        let end = clock.now
        if stop == .refusal { throw ClaudeError.refusal(category: nil, explanation: nil) }
        if stop == .maxTokens { throw ClaudeError.truncated(partial: text) }
        let prompt = answers.isEmpty ? prompts.optimizer : prompts.clarifyFinal
        return OptimizeResult(
            text: Self.cleanOutput(text), requestedModel: config.model, servedModel: served,
            ttfb: (firstToken ?? end) - start, total: end - start,
            usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens),
            stopReason: stop, promptHash: prompt.sha256)
    }

    public func clarifyingQuestions(for original: String) async throws -> ClarifyResult {
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await client.send(questionsRequest(original: original))
        let total = clock.now - start
        if response.stopReason == .refusal {
            throw ClaudeError.refusal(category: response.stopDetails?.category, explanation: response.stopDetails?.explanation)
        }
        guard let data = response.text.data(using: .utf8) else { throw ClaudeError.decoding("questions not UTF-8") }
        let questions: ClarifyQuestions
        do { questions = try RequestCoding.decoder().decode(ClarifyQuestions.self, from: data) } catch {
            throw ClaudeError.decoding("questions JSON: \(error); text: \(response.text.prefix(300))")
        }
        return ClarifyResult(
            questions: questions.clamped(), servedModel: response.servedModel,
            total: total, usage: response.usage, promptHash: prompts.clarifyQuestions.sha256)
    }

    /// Strip wrapping code fences or tags a model occasionally adds around the prompt.
    public static func cleanOutput(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) } else { s = "" }
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for tag in ["optimized_prompt", "prompt", "rewritten_prompt"] {
            let open = "<\(tag)>", close = "</\(tag)>"
            if s.hasPrefix(open), s.hasSuffix(close) {
                s = String(s.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }
}
