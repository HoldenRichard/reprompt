import Foundation
import Testing
@testable import RepromptCore

/// A prompt set with recognisable text, so tests can assert WHICH prompt was sent.
func stubPrompts() -> PromptSet {
    func p(_ n: PromptName, _ t: String) -> SystemPrompt {
        SystemPrompt(name: n, text: t, sha256: PromptLibrary.sha256(t), source: nil)
    }
    return PromptSet(
        optimizer: p(.optimizer, "OPTIMIZER-PROMPT"),
        clarifyQuestions: p(.clarifyQuestions, "QUESTIONS-PROMPT"),
        clarifyFinal: p(.clarifyFinal, "CLARIFY-FINAL-PROMPT"),
        judge: p(.judge, "JUDGE-PROMPT"))
}

@Suite struct PromptOptimizerRequestTests {
    let prompts = stubPrompts()
    func optimizer(_ config: OptimizerConfig = .default) -> PromptOptimizer {
        PromptOptimizer(client: ClaudeClient(apiKey: "k"), config: config, prompts: prompts)
    }

    @Test func userMessageWrapsTheOriginalPrompt() {
        let m = PromptOptimizer.userMessage(original: "fix it", answers: [])
        #expect(m == "<original_prompt>\nfix it\n</original_prompt>")
        #expect(!m.contains("<clarifications>"))
    }

    @Test func userMessageAppendsClarificationsAndMarksSkippedOnes() {
        let m = PromptOptimizer.userMessage(original: "fix it", answers: [
            ClarifyAnswer(questionID: "q1", question: "Which file?", answer: "main.swift"),
            ClarifyAnswer(questionID: "q2", question: "Tests?", answer: ""),
        ])
        #expect(m.contains("<original_prompt>\nfix it\n</original_prompt>"))
        #expect(m.contains("Q: Which file?\nA: main.swift"))
        #expect(m.contains("Q: Tests?\nA: (no answer; use best judgment)"))
        #expect(m.hasSuffix("</clarifications>"))
    }

    @Test func quickRewriteUsesTheOptimizerPromptAndQuickEffort() {
        let r = optimizer(OptimizerConfig(quickEffort: .low, clarifyEffort: .max))
            .rewriteRequest(original: "x", answers: [], stream: true)
        #expect(r.system?.first?.text == "OPTIMIZER-PROMPT")
        #expect(r.outputConfig?.effort == .low)
        #expect(r.stream)
        #expect(r.outputConfig?.format == nil, "the rewrite is free text, not structured output")
    }

    @Test func answeredRewriteSwitchesToTheClarifyFinalPromptAndEffort() {
        let r = optimizer(OptimizerConfig(quickEffort: .low, clarifyEffort: .max))
            .rewriteRequest(original: "x",
                            answers: [ClarifyAnswer(questionID: "q", question: "Q?", answer: "A")],
                            stream: false)
        #expect(r.system?.first?.text == "CLARIFY-FINAL-PROMPT")
        #expect(r.outputConfig?.effort == .max)
        #expect(r.messages.first?.content.contains("Q: Q?\nA: A") == true)
    }

    @Test func questionsRequestIsStructuredNonStreamingAndBounded() {
        let r = optimizer(OptimizerConfig(clarifyEffort: .medium)).questionsRequest(original: "x")
        #expect(r.system?.first?.text == "QUESTIONS-PROMPT")
        #expect(r.maxTokens == 1024)
        #expect(!r.stream)
        #expect(r.outputConfig?.effort == .medium)
        #expect(r.outputConfig?.format?.type == "json_schema")
        #expect(r.outputConfig?.format?.schema == ClarifyQuestions.jsonSchema)
    }

    @Test func theSystemPromptIsMarkedCacheableSoTheStablePrefixIsReused() {
        let r = optimizer().rewriteRequest(original: "x", answers: [], stream: true)
        #expect(r.system?.first?.cacheControl?.type == "ephemeral")
    }

    @Test func configuredModelAndTokenBudgetReachTheRequest() {
        let r = optimizer(OptimizerConfig(model: "claude-sonnet-5", maxTokens: 777))
            .rewriteRequest(original: "x", answers: [], stream: true)
        #expect(r.model == "claude-sonnet-5")
        #expect(r.maxTokens == 777)
    }
}

@Suite struct PromptOptimizerCallTests {
    func optimizer(_ url: URL, _ config: OptimizerConfig = .default) -> PromptOptimizer {
        PromptOptimizer(client: ClaudeClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session()),
                        config: config, prompts: stubPrompts())
    }

    @Test func optimizeCollectsTextTimingsAndUsage() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["Rewrite ", "this ", "prompt."],
                                                        inputTokens: 40, outputTokens: 9)))
        let r = try await optimizer(url).optimize("original")
        #expect(r.text == "Rewrite this prompt.")
        #expect(r.requestedModel == ModelCatalog.default.id)
        #expect(r.servedModel == "claude-opus-5")
        #expect(r.stopReason == .endTurn)
        #expect(r.usage.inputTokens == 40)
        #expect(r.usage.outputTokens == 9)
        #expect(r.ttfb <= r.total)
        #expect(r.total > .zero)
        #expect(r.promptHash == PromptLibrary.sha256("OPTIMIZER-PROMPT"))
    }

    @Test func optimizeReportsTheFallbackModelThatActuallyServed() async throws {
        let fallback = #"data: {"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-fable-5-1"},"to":{"model":"claude-opus-5"}}}"#
        let url = MockURLProtocol.install(.sse(sseLines(model: "claude-fable-5-1", extraBlocks: [fallback])))
        let r = try await optimizer(url, OptimizerConfig(model: "claude-fable-5-1")).optimize("x")
        #expect(r.requestedModel == "claude-fable-5-1")
        #expect(r.servedModel == "claude-opus-5")
    }

    @Test func optimizeStripsAWrappingCodeFenceFromTheModelOutput() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["```\n", "the prompt", "\n```"])))
        #expect(try await optimizer(url).optimize("x").text == "the prompt")
    }

    @Test func refusalBecomesATypedRefusalError() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["nope"], stopReason: "refusal")))
        let err = await errorFrom { try await optimizer(url).optimize("x") }
        guard case .refusal? = err as? ClaudeError else {
            Issue.record("expected .refusal, got \(String(describing: err))"); return
        }
    }

    @Test func hittingMaxTokensReportsTruncationAndKeepsThePartialText() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["half a rewr"], stopReason: "max_tokens")))
        let err = await errorFrom { try await optimizer(url).optimize("x") }
        guard case .truncated(let partial)? = err as? ClaudeError else {
            Issue.record("expected .truncated, got \(String(describing: err))"); return
        }
        #expect(partial == "half a rewr")
    }

    /// Regression: cancelling ends the stream without throwing, so a cancelled optimize used
    /// to return its partial text as a successful result.
    @Test func cancellingOptimizeThrowsInsteadOfReturningPartialText() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: (1...40).map { "c\($0) " }), delay: 0.02))
        let opt = optimizer(url)
        let task = Task { try await opt.optimize("x") }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let result = await task.result
        guard case .failure = result else {
            Issue.record("a cancelled optimize must not report success")
            return
        }
    }

    @Test func clarifyingQuestionsDecodesClampsAndReportsUsage() async throws {
        let questions = """
        {"questions":[\
        {"id":"q1","question":"Who is the audience?","why":"changes tone","suggested_answers":["client","team"]},\
        {"id":"q2","question":"How long?","why":"","suggested_answers":[]},\
        {"id":"q3","question":"Format?","why":"","suggested_answers":[]},\
        {"id":"q4","question":"Extra?","why":"","suggested_answers":[]}]}
        """
        let escaped = questions.replacingOccurrences(of: "\"", with: "\\\"")
        let url = MockURLProtocol.install(.json(
            #"{"id":"m","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"\#(escaped)"}],"stop_reason":"end_turn","usage":{"input_tokens":30,"output_tokens":60}}"#))
        let r = try await optimizer(url).clarifyingQuestions(for: "x")
        #expect(r.questions.questions.map(\.id) == ["q1", "q2", "q3"], "must clamp to three")
        #expect(r.questions.questions.first?.suggestedAnswers == ["client", "team"])
        #expect(r.usage.inputTokens == 30)
        #expect(r.servedModel == "claude-opus-5")
        #expect(r.promptHash == PromptLibrary.sha256("QUESTIONS-PROMPT"))
        #expect(r.total > .zero)
    }

    @Test func clarifyingQuestionsSurfacesNonJSONOutputAsADecodingError() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"id":"m","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"Sure! Here are some questions."}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#))
        let err = await errorFrom { try await optimizer(url).clarifyingQuestions(for: "x") }
        guard case .decoding? = err as? ClaudeError else {
            Issue.record("expected .decoding, got \(String(describing: err))"); return
        }
    }

    @Test func clarifyingQuestionsPropagatesARefusalWithItsCategory() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"id":"m","type":"message","role":"assistant","model":"m","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"declined"},"usage":{"input_tokens":1,"output_tokens":0}}"#))
        let err = await errorFrom { try await optimizer(url).clarifyingQuestions(for: "x") }
        #expect(err as? ClaudeError == .refusal(category: "cyber", explanation: "declined"))
    }

    @Test func anEmptyQuestionSetIsReportedRatherThanFaked() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"id":"m","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"{\"questions\":[]}"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#))
        let r = try await optimizer(url).clarifyingQuestions(for: "x")
        #expect(r.questions.isEmpty, "callers must be able to detect this and fall back")
    }
}

@Suite struct CleanOutputTests {
    func clean(_ s: String) -> String { PromptOptimizer.cleanOutput(s) }

    @Test func stripsAFenceThatWrapsTheWholeOutput() {
        #expect(clean("```\nhello\n```") == "hello")
        #expect(clean("```markdown\nhello\nworld\n```\n") == "hello\nworld")
        #expect(clean("  ```text\na\n```  ") == "a")
    }

    /// Regression: an opening fence with no closing fence used to have its first line
    /// deleted, silently corrupting the prompt the user was about to paste.
    @Test func leavesTextAloneWhenOnlyTheOpeningFenceIsPresent() {
        let s = "```\ncode here\n```\n\nAnd then some notes."
        #expect(clean(s) == s, "half-stripping a fence corrupts the prompt")
        #expect(clean("```python\nprint(1)") == "```python\nprint(1)")
    }

    /// Regression: a bare fence used to be replaced with the empty string.
    @Test func doesNotBlankDegenerateFences() {
        #expect(clean("```") == "```")
        #expect(clean("``````") == "``````")
        #expect(clean("```\n```") == "```\n```")
    }

    @Test func keepsFencesThatAreInsideTheContent() {
        #expect(clean("Use ```code``` inline") == "Use ```code``` inline")
        #expect(clean("```\nrun ```x``` now\n```") == "run ```x``` now")
    }

    @Test func stripsAWrappingTagOnlyWhenBothEndsMatch() {
        #expect(clean("<optimized_prompt>\nx\n</optimized_prompt>") == "x")
        #expect(clean("<prompt>y</prompt>") == "y")
        #expect(clean("<rewritten_prompt>z</rewritten_prompt>") == "z")
        #expect(clean("<prompt>y</optimized_prompt>") == "<prompt>y</optimized_prompt>")
        #expect(clean("<prompt>y") == "<prompt>y")
    }

    /// Accept pastes the result over the user's selection, so cleaning must never be able
    /// to turn a non-empty rewrite into an empty one.
    @Test func neverReducesNonEmptyOutputToNothing() {
        for input in ["```\n```", "```\n\n```", "<prompt></prompt>", "<optimized_prompt>\n</optimized_prompt>", "```x\n```"] {
            #expect(!clean(input).isEmpty, "cleaning \(input.debugDescription) produced an empty string")
        }
        #expect(clean("   ").isEmpty, "genuinely empty input may stay empty")
    }

    @Test func trimsSurroundingWhitespaceAndLeavesOrdinaryTextIntact() {
        #expect(clean("  plain  ") == "plain")
        #expect(clean("") == "")
        #expect(clean("\n\n") == "")
        let normal = "Rewrite this.\n\nContext: a thing.\n- one\n- two"
        #expect(clean(normal) == normal)
    }
}
