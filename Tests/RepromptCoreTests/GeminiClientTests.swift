import Foundation
import Testing
@testable import RepromptCore

/// A Gemini SSE body. Gemini has no end sentinel: the last chunk carries `finishReason`.
func geminiSSE(text: [String] = ["Hello"], finish: String = "STOP",
               model: String = "gemini-2.5-flash", promptTokens: Int = 10,
               candidateTokens: Int = 5, thoughtTokens: Int? = nil,
               includeFinish: Bool = true) -> [String] {
    var lines: [String] = []
    for t in text {
        lines.append(#"data: {"candidates":[{"content":{"parts":[{"text":\#(jsonQuoted(t))}],"role":"model"}}],"modelVersion":"\#(model)"}"#)
    }
    if includeFinish {
        let thoughts = thoughtTokens.map { ",\"thoughtsTokenCount\":\($0)" } ?? ""
        lines.append(#"data: {"candidates":[{"content":{"parts":[]},"finishReason":"\#(finish)"}],"usageMetadata":{"promptTokenCount":\#(promptTokens),"candidatesTokenCount":\#(candidateTokens)\#(thoughts)},"modelVersion":"\#(model)"}"#)
    }
    return lines
}

@Suite struct GeminiSchemaTranslationTests {
    /// Gemini rejects JSON Schema as written: types must be upper-case and
    /// `additionalProperties` is not a valid key. Sending ours unchanged is a 400.
    @Test func translatesJSONSchemaIntoGeminisDialect() {
        let out = GeminiClient.responseSchema(from: ClarifyQuestions.jsonSchema)
        guard case .object(let root) = out else { Issue.record("not an object"); return }
        #expect(root["type"] == .string("OBJECT"))
        #expect(root["additionalProperties"] == nil, "Gemini rejects this key")
        #expect(root["required"] == .array([.string("questions")]))

        guard case .object(let props)? = root["properties"],
              case .object(let questions)? = props["questions"],
              case .object(let items)? = questions["items"],
              case .object(let itemProps)? = items["properties"] else {
            Issue.record("shape lost in translation"); return
        }
        #expect(questions["type"] == .string("ARRAY"))
        #expect(items["type"] == .string("OBJECT"))
        #expect(items["additionalProperties"] == nil)
        #expect(itemProps["id"] == .object(["type": .string("STRING")]))
        #expect(Set(itemProps.keys) == ["id", "question", "why", "suggested_answers"])
        guard case .object(let answers)? = itemProps["suggested_answers"] else {
            Issue.record("array property lost"); return
        }
        #expect(answers["type"] == .string("ARRAY"))
        #expect(answers["items"] == .object(["type": .string("STRING")]))
    }

    @Test func noAdditionalPropertiesKeySurvivesAnywhereInTheTree() {
        func scan(_ v: JSONValue, path: String) {
            switch v {
            case .object(let o):
                #expect(o["additionalProperties"] == nil, "survived at \(path)")
                for (k, sub) in o { scan(sub, path: "\(path).\(k)") }
            case .array(let a):
                for (i, sub) in a.enumerated() { scan(sub, path: "\(path)[\(i)]") }
            default: break
            }
        }
        scan(GeminiClient.responseSchema(from: ClarifyQuestions.jsonSchema), path: "root")
    }

    @Test func propertyOrderingIsDeclaredSoOutputKeysAreStable() {
        guard case .object(let root) = GeminiClient.responseSchema(from: ClarifyQuestions.jsonSchema),
              case .array(let order)? = root["propertyOrdering"] else {
            Issue.record("no propertyOrdering"); return
        }
        #expect(order == [.string("questions")])
    }

    @Test func nonSchemaValuesPassThroughUntouched() {
        #expect(GeminiClient.responseSchema(from: .string("x")) == .string("x"))
        #expect(GeminiClient.responseSchema(from: .object(["description": .string("keep me")]))
            == .object(["description": .string("keep me")]))
    }
}

@Suite struct GeminiClientTests {
    func client(_ url: URL) -> GeminiClient {
        GeminiClient(apiKey: "gk-test", baseURL: url, session: MockURLProtocol.session(), retry: .none)
    }
    var request: ChatRequest {
        ChatRequest(model: "gemini-2.5-flash", system: "SYS", user: "USER", maxTokens: 512)
    }

    @Test func putsTheModelInThePathAndTheKeyInAHeader() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"candidates":[{"content":{"parts":[{"text":"hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2},"modelVersion":"gemini-2.5-flash"}"#))
        _ = try await client(url).send(request)
        let sent = try #require(MockURLProtocol.requests(for: url).first)
        #expect(sent.url?.absoluteString.hasSuffix("/models/gemini-2.5-flash:generateContent") == true)
        #expect(sent.httpMethod == "POST")
        // The key goes in a header, never a query parameter, so it stays out of logs.
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "gk-test")
        #expect(sent.url?.query?.contains("key=") != true)
    }

    @Test func sendsTheSystemPromptAsItsOwnFieldNotAsAMessage() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"STOP"}],"modelVersion":"m"}"#))
        _ = try await client(url).send(request)
        let body = try #require(try MockURLProtocol.bodyJSON(for: url))
        let system = (body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
        #expect(system?.first?["text"] as? String == "SYS")
        let contents = body["contents"] as? [[String: Any]]
        #expect(contents?.count == 1)
        #expect((contents?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String == "USER")
        #expect((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 512)
    }

    @Test func omitsTheSystemFieldWhenThereIsNoSystemPrompt() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"STOP"}],"modelVersion":"m"}"#))
        _ = try await client(url).send(ChatRequest(model: "m", user: "u", maxTokens: 10))
        let body = try #require(try MockURLProtocol.bodyJSON(for: url))
        #expect(body["systemInstruction"] == nil)
    }

    @Test func structuredOutputSetsTheMimeTypeAndTranslatedSchema() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"candidates":[{"content":{"parts":[{"text":"{}"}]},"finishReason":"STOP"}],"modelVersion":"m"}"#))
        var r = request
        r.jsonSchema = ClarifyQuestions.jsonSchema
        _ = try await client(url).send(r)
        let config = try #require((try MockURLProtocol.bodyJSON(for: url))?["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        let schema = try #require(config["responseSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "OBJECT")
        #expect(schema["additionalProperties"] == nil)
    }

    @Test func decodesTextUsageAndFinishReason() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"candidates":[{"content":{"parts":[{"text":"one "},{"text":"two"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":11,"candidatesTokenCount":7,"thoughtsTokenCount":4,"cachedContentTokenCount":9},"modelVersion":"gemini-2.5-flash-002"}"#))
        let r = try await client(url).send(request)
        #expect(r.text == "one two")
        #expect(r.servedModel == "gemini-2.5-flash-002")
        #expect(r.stopReason == .endTurn)
        #expect(r.usage.inputTokens == 11)
        // Thinking tokens bill as output, so they must be counted there.
        #expect(r.usage.outputTokens == 11)
        #expect(r.usage.cacheReadInputTokens == 9)
    }

    @Test(arguments: [("STOP", StopReason.endTurn), ("MAX_TOKENS", .maxTokens),
                      ("SAFETY", .refusal), ("RECITATION", .refusal),
                      ("PROHIBITED_CONTENT", .refusal), ("SPII", .refusal)])
    func mapsFinishReasonsOntoTheSharedVocabulary(raw: String, expected: StopReason) {
        #expect(GeminiClient.stopReason(finish: raw, blockReason: nil) == expected)
    }

    @Test func unknownFinishReasonsArePreserved() {
        #expect(GeminiClient.stopReason(finish: "SOMETHING_NEW", blockReason: nil) == .unknown("SOMETHING_NEW"))
        #expect(GeminiClient.stopReason(finish: nil, blockReason: nil) == nil)
    }

    /// A blocked PROMPT reports through promptFeedback rather than a finish reason, and must
    /// still read as a refusal instead of an empty success.
    @Test func aBlockedPromptIsARefusal() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"promptFeedback":{"blockReason":"SAFETY"},"modelVersion":"m"}"#))
        let r = try await client(url).send(request)
        #expect(r.stopReason == .refusal)
        #expect(r.stopDetails?.category == "SAFETY")
        #expect(r.text.isEmpty)
        #expect(GeminiClient.stopReason(finish: nil, blockReason: "BLOCK_REASON_UNSPECIFIED") == nil)
    }

    @Test func errorEnvelopesBecomeTypedErrors() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#, status: 429))
        let err = await errorFrom { try await client(url).send(request) }
        #expect(err as? ClaudeError == .api(status: 429, type: "RESOURCE_EXHAUSTED", message: "Quota exceeded"))
    }

    // MARK: Streaming

    func drain(_ url: URL) async throws -> [StreamEvent] {
        var out: [StreamEvent] = []
        for try await e in client(url).stream(request) { out.append(e) }
        return out
    }

    @Test func streamingUsesTheSSEEndpoint() async throws {
        let url = MockURLProtocol.install(.sse(geminiSSE()))
        _ = try await drain(url)
        let sent = try #require(MockURLProtocol.requests(for: url).first)
        #expect(sent.url?.absoluteString.contains(":streamGenerateContent") == true)
        #expect(sent.url?.absoluteString.contains("alt=sse") == true)
    }

    @Test func streamsTextAndFinishesWithAStopEvent() async throws {
        let events = try await drain(MockURLProtocol.install(
            .sse(geminiSSE(text: ["Re", "written ", "prompt"], candidateTokens: 12))))
        #expect(events.first == .messageStart(model: "gemini-2.5-flash", inputTokens: 0))
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Rewritten prompt")
        #expect(events.contains(.messageDelta(stopReason: .endTurn, outputTokens: 12, inputTokens: 10)))
        #expect(events.last == .messageStop)
    }

    /// Gemini has no end sentinel, so a dropped connection looks exactly like a short answer
    /// unless the absence of a finish reason is treated as a failure.
    @Test func aStreamWithNoFinishReasonIsAnError() async throws {
        let err = await errorFrom { try await drain(MockURLProtocol.install(
            .sse(geminiSSE(text: ["half a promp"], includeFinish: false)))) }
        guard case .invalidResponse(let m)? = err as? ClaudeError else {
            Issue.record("expected .invalidResponse, got \(String(describing: err))"); return
        }
        #expect(m.contains("finish reason"))
    }

    @Test func aMidStreamErrorChunkThrows() async throws {
        let err = await errorFrom { try await drain(MockURLProtocol.install(.sse([
            #"data: {"error":{"code":500,"message":"boom","status":"INTERNAL"}}"#,
        ]))) }
        #expect(err as? ClaudeError == .stream(type: "INTERNAL", message: "boom"))
    }

    @Test func aRefusalMidStreamIsReportedAsSuch() async throws {
        let events = try await drain(MockURLProtocol.install(.sse(geminiSSE(text: [], finish: "SAFETY"))))
        #expect(events.contains { if case .messageDelta(.refusal, _, _) = $0 { true } else { false } })
    }

    @Test func toleratesCRLFAndBlankLines() async throws {
        var lines = geminiSSE(text: ["ok"])
        lines = lines.map { $0 + "\r" }
        lines.insert("", at: 1)
        let text = try await drain(MockURLProtocol.install(.sse(lines)))
            .compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "ok")
    }

    @Test func listingModelsStripsThePrefixAndDropsNonChatModels() async throws {
        let url = MockURLProtocol.install(.json("""
        {"models":[
          {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","inputTokenLimit":1048576,"supportedGenerationMethods":["generateContent"]},
          {"name":"models/text-embedding-004","displayName":"Embedding","supportedGenerationMethods":["embedContent"]}
        ]}
        """))
        let models = try await client(url).availableModels()
        #expect(models.map(\.id) == ["gemini-2.5-flash"])
        #expect(models.first?.inputTokenLimit == 1_048_576)
        let sent = try #require(MockURLProtocol.requests(for: url).first)
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "gk-test")
    }
}

@Suite struct LLMClientDispatchTests {
    /// Regression: `availableModels()` lived only in a protocol extension, so every call
    /// through the existential ran the empty default and the harness reported that the
    /// provider offered no models at all.
    @Test func concreteImplementationsAreReachedThroughTheExistential() async throws {
        let geminiURL = MockURLProtocol.install(.json(
            #"{"models":[{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]}]}"#))
        let gemini: any LLMClient = GeminiClient(apiKey: "k", baseURL: geminiURL,
                                                 session: MockURLProtocol.session())
        #expect(try await gemini.availableModels().map(\.id) == ["gemini-2.5-flash"])

        let groqURL = MockURLProtocol.install(.json(
            #"{"data":[{"id":"openai/gpt-oss-120b","context_window":131072}]}"#))
        let groq: any LLMClient = GroqClient(apiKey: "k", baseURL: groqURL,
                                             session: MockURLProtocol.session())
        #expect(try await groq.availableModels().map(\.id) == ["openai/gpt-oss-120b"])
    }

    @Test func eachClientReportsItsOwnProviderThroughTheExistential() {
        let clients: [any LLMClient] = [
            ClaudeClient(apiKey: "k"), GeminiClient(apiKey: "k"), GroqClient(apiKey: "k"),
        ]
        #expect(clients.map(\.provider) == [.anthropic, .gemini, .groq])
    }
}
