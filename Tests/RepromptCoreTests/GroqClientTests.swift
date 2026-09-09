import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RepromptCore

/// An OpenAI-style SSE body, which is what Groq speaks.
func groqSSE(text: [String] = ["Hello"], finish: String = "stop",
             model: String = "openai/gpt-oss-120b", promptTokens: Int = 10,
             completionTokens: Int = 5, includeDone: Bool = true) -> [String] {
    var lines: [String] = []
    for t in text {
        lines.append(#"data: {"id":"c1","model":"\#(model)","choices":[{"index":0,"delta":{"content":\#(jsonQuoted(t))},"finish_reason":null}]}"#)
    }
    lines.append(#"data: {"id":"c1","model":"\#(model)","choices":[{"index":0,"delta":{},"finish_reason":"\#(finish)"}],"x_groq":{"usage":{"prompt_tokens":\#(promptTokens),"completion_tokens":\#(completionTokens)}}}"#)
    if includeDone { lines.append("data: [DONE]") }
    return lines
}

@Suite struct GroqClientTests {
    func client(_ url: URL) -> GroqClient {
        GroqClient(apiKey: "gsk-test", baseURL: url, session: MockURLProtocol.session(), retry: .none)
    }
    var request: ChatRequest {
        ChatRequest(model: "openai/gpt-oss-120b", system: "SYS", user: "USER", maxTokens: 512)
    }
    var okBody: String {
        #"{"id":"c1","model":"openai/gpt-oss-120b","choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":4}}"#
    }

    @Test func usesBearerAuthAndTheChatCompletionsShape() async throws {
        let url = MockURLProtocol.install(.json(okBody))
        _ = try await client(url).send(request)
        let sent = try #require(MockURLProtocol.requests(for: url).first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")

        let body = try #require(try MockURLProtocol.bodyJSON(for: url))
        #expect(body["model"] as? String == "openai/gpt-oss-120b")
        // OpenAI's newer field name; `max_tokens` is deprecated for reasoning models.
        #expect(body["max_completion_tokens"] as? Int == 512)
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "SYS")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "USER")
    }

    @Test func omitsTheSystemMessageWhenThereIsNoSystemPrompt() async throws {
        let url = MockURLProtocol.install(.json(okBody))
        _ = try await client(url).send(ChatRequest(model: "m", user: "u", maxTokens: 10))
        let messages = try #require((try MockURLProtocol.bodyJSON(for: url))?["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
    }

    @Test func decodesTextUsageAndFinishReason() async throws {
        let r = try await client(MockURLProtocol.install(.json(okBody))).send(request)
        #expect(r.text == "hi")
        #expect(r.servedModel == "openai/gpt-oss-120b")
        #expect(r.stopReason == .endTurn)
        #expect(r.usage.inputTokens == 9)
        #expect(r.usage.outputTokens == 4)
    }

    @Test(arguments: [("stop", StopReason.endTurn), ("length", .maxTokens),
                      ("content_filter", .refusal), ("tool_calls", .toolUse)])
    func mapsOpenAIFinishReasons(raw: String, expected: StopReason) {
        #expect(GroqClient.stopReason(raw) == expected)
    }

    @Test func unknownFinishReasonsArePreserved() {
        #expect(GroqClient.stopReason("something_new") == .unknown("something_new"))
        #expect(GroqClient.stopReason(nil) == nil)
    }

    /// Groq's effort vocabulary tops out at "high", and models that are not reasoning models
    /// reject the field entirely.
    @Test func reasoningEffortIsClampedAndOnlySentWhereSupported() {
        #expect(GroqClient.reasoningEffort(for: .low, model: "openai/gpt-oss-120b") == "low")
        #expect(GroqClient.reasoningEffort(for: .medium, model: "openai/gpt-oss-120b") == "medium")
        #expect(GroqClient.reasoningEffort(for: .xhigh, model: "openai/gpt-oss-120b") == "high")
        #expect(GroqClient.reasoningEffort(for: .max, model: "openai/gpt-oss-120b") == "high")
        #expect(GroqClient.reasoningEffort(for: .low, model: "qwen/qwen3.8-27b") == nil)
        #expect(GroqClient.reasoningEffort(for: nil, model: "openai/gpt-oss-120b") == nil)
    }

    @Test func structuredOutputUsesTheStrictJSONSchemaEnvelope() async throws {
        let url = MockURLProtocol.install(.json(okBody))
        var r = request
        r.jsonSchema = ClarifyQuestions.jsonSchema
        _ = try await client(url).send(r)
        let format = try #require((try MockURLProtocol.bodyJSON(for: url))?["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let inner = try #require(format["json_schema"] as? [String: Any])
        #expect(inner["strict"] as? Bool == true)
        // Unlike Gemini, Groq takes JSON Schema as written.
        let schema = try #require(inner["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["type"] as? String == "object")
    }

    @Test func errorEnvelopesBecomeTypedErrors() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"error":{"message":"Rate limit reached","type":"rate_limit_exceeded"}}"#, status: 429))
        let err = await errorFrom { try await client(url).send(request) }
        #expect(err as? ClaudeError == .api(status: 429, type: "rate_limit_exceeded", message: "Rate limit reached"))
    }

    // MARK: Streaming

    func drain(_ url: URL) async throws -> [StreamEvent] {
        var out: [StreamEvent] = []
        for try await e in client(url).stream(request) { out.append(e) }
        return out
    }

    @Test func streamsTextAndStopsOnTheDoneSentinel() async throws {
        let events = try await drain(MockURLProtocol.install(
            .sse(groqSSE(text: ["Re", "written"], completionTokens: 8))))
        #expect(events.first == .messageStart(model: "openai/gpt-oss-120b", inputTokens: 0))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Rewritten")
        #expect(events.contains(.messageDelta(stopReason: .endTurn, outputTokens: 8, inputTokens: 10)))
        #expect(events.last == .messageStop)
    }

    @Test func setsStreamTrueOnTheWire() async throws {
        let url = MockURLProtocol.install(.sse(groqSSE()))
        _ = try await drain(url)
        #expect((try MockURLProtocol.bodyJSON(for: url))?["stream"] as? Bool == true)
    }

    /// Without the sentinel the connection simply ended, which is not a finished message.
    @Test func aStreamWithNoDoneSentinelIsAnError() async throws {
        let err = await errorFrom { try await drain(MockURLProtocol.install(
            .sse(groqSSE(text: ["partial"], includeDone: false)))) }
        guard case .invalidResponse(let m)? = err as? ClaudeError else {
            Issue.record("expected .invalidResponse, got \(String(describing: err))"); return
        }
        #expect(m.contains("completion marker"))
    }

    @Test func aMidStreamErrorChunkThrows() async throws {
        let err = await errorFrom { try await drain(MockURLProtocol.install(.sse([
            #"data: {"error":{"message":"overloaded","type":"server_error"}}"#,
        ]))) }
        #expect(err as? ClaudeError == .stream(type: "server_error", message: "overloaded"))
    }

    @Test func toleratesCRLFAndEmptyDeltas() async throws {
        var lines = groqSSE(text: ["ok"]).map { $0 + "\r" }
        lines.insert(#"data: {"choices":[{"delta":{},"finish_reason":null}]}"#, at: 1)
        let text = try await drain(MockURLProtocol.install(.sse(lines)))
            .compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "ok")
    }

    @Test func listsModelsFromTheModelsEndpoint() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"object":"list","data":[{"id":"openai/gpt-oss-120b","context_window":131072},{"id":"llama-3.1-8b-instant","context_window":131072}]}"#))
        let models = try await client(url).availableModels()
        #expect(models.map(\.id) == ["openai/gpt-oss-120b", "llama-3.1-8b-instant"])
        #expect(models.first?.inputTokenLimit == 131_072)
    }
}

@Suite struct TrailingUsageTests {
    /// Regression: Groq and Gemini report the prompt size only in the FINAL chunk, so
    /// reading it solely from messageStart recorded every streamed rewrite as 0 input
    /// tokens — which made the harness under-report usage on both providers.
    @Test func groqStreamingRecoversThePromptTokenCount() async throws {
        let url = MockURLProtocol.install(.sse(groqSSE(text: ["x"], promptTokens: 617, completionTokens: 42)))
        let client = GroqClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(), retry: .none)
        var events: [StreamEvent] = []
        for try await e in client.stream(ChatRequest(model: "m", user: "u", maxTokens: 10, stream: true)) {
            events.append(e)
        }
        #expect(events.contains(.messageDelta(stopReason: .endTurn, outputTokens: 42, inputTokens: 617)))
    }

    @Test func geminiStreamingRecoversThePromptTokenCount() async throws {
        let url = MockURLProtocol.install(.sse(geminiSSE(text: ["x"], promptTokens: 593, candidateTokens: 31)))
        let client = GeminiClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(), retry: .none)
        var events: [StreamEvent] = []
        for try await e in client.stream(ChatRequest(model: "m", user: "u", maxTokens: 10, stream: true)) {
            events.append(e)
        }
        #expect(events.contains(.messageDelta(stopReason: .endTurn, outputTokens: 31, inputTokens: 593)))
    }

    /// The optimizer must keep the late count rather than the zero that arrived first.
    @Test func theOptimizerReportsTheLateArrivingInputCount() async throws {
        let url = MockURLProtocol.install(.sse(groqSSE(text: ["rewritten"], promptTokens: 601, completionTokens: 55)))
        let optimizer = PromptOptimizer(
            client: GroqClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(), retry: .none),
            config: OptimizerConfig(provider: .groq, model: "openai/gpt-oss-120b"),
            prompts: stubPrompts())
        let r = try await optimizer.optimize("x")
        #expect(r.usage.inputTokens == 601, "input tokens were lost")
        #expect(r.usage.outputTokens == 55)
    }
}
