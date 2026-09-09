import Foundation
import Testing
@testable import RepromptCore

@Suite struct RequestEncodingTests {
    func json(_ r: MessageRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try RequestCoding.encoder().encode(r)) as! [String: Any]
    }

    @Test func aQuickOpus5RequestHasTheDocumentedShape() throws {
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: "SYS", user: "hi", maxTokens: 2048, effort: .low,
            thinking: .adaptive, fastMode: false, useFallbacks: true, stream: true)
        let j = try json(r)
        #expect(j["model"] as? String == "claude-opus-5")
        #expect(j["max_tokens"] as? Int == 2048)
        #expect(j["stream"] as? Bool == true)
        #expect(j["fallbacks"] as? String == "default")
        #expect((j["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((j["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(j["speed"] == nil)
        #expect(r.betaHeaders == ["server-side-fallback-2026-07-01"])

        let system = j["system"] as? [[String: Any]]
        #expect(system?.count == 1)
        #expect(system?.first?["type"] as? String == "text")
        #expect(system?.first?["text"] as? String == "SYS")
        #expect((system?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let messages = j["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] as? String == "user")
        #expect(messages?.first?["content"] as? String == "hi")
    }

    /// Parameters removed from the current API must never appear, on any model.
    @Test func removedParametersAreNeverSent() throws {
        for model in ModelCatalog.all.map(\.id) + ["claude-unknown-9"] {
            for effort in Effort.allCases {
                for thinking in [ThinkingMode.adaptive, .disabled] {
                    let j = try json(RequestBuilder.build(
                        model: model, system: "s", user: "u", maxTokens: 10, effort: effort,
                        thinking: thinking, fastMode: true, useFallbacks: true, stream: false))
                    #expect(j["temperature"] == nil, "\(model)")
                    #expect(j["top_p"] == nil, "\(model)")
                    #expect(j["top_k"] == nil, "\(model)")
                    #expect(j["budget_tokens"] == nil, "\(model)")
                    #expect((j["thinking"] as? [String: Any])?["budget_tokens"] == nil, "\(model)")
                    #expect(j["output_format"] == nil, "\(model): superseded by output_config.format")
                }
            }
        }
    }

    @Test func opus5AllowsDisabledThinkingUpToHighEffortOnly() throws {
        for effort in [Effort.low, .medium, .high] {
            let r = RequestBuilder.build(model: "claude-opus-5", system: nil, user: "u", maxTokens: 10,
                                         effort: effort, thinking: .disabled, fastMode: false,
                                         useFallbacks: false, stream: false)
            #expect(r.thinking == .disabled, "disabled thinking is legal at \(effort)")
        }
        for effort in [Effort.xhigh, .max] {
            let r = RequestBuilder.build(model: "claude-opus-5", system: nil, user: "u", maxTokens: 10,
                                         effort: effort, thinking: .disabled, fastMode: false,
                                         useFallbacks: false, stream: false)
            #expect(r.thinking == .adaptive, "disabled thinking 400s above high, so it must fall back to adaptive")
        }
    }

    @Test func fastModeIsSentOnlyForOpus5() throws {
        let opus = RequestBuilder.build(model: "claude-opus-5", system: nil, user: "u", maxTokens: 10,
                                        effort: .low, thinking: .adaptive, fastMode: true,
                                        useFallbacks: false, stream: false)
        #expect(opus.speed == .fast)
        #expect(opus.betaHeaders == ["fast-mode-2026-02-01"])
        for model in ["claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5-1", "claude-unknown-9"] {
            let r = RequestBuilder.build(model: model, system: nil, user: "u", maxTokens: 10,
                                         effort: .low, thinking: .adaptive, fastMode: true,
                                         useFallbacks: false, stream: false)
            #expect(r.speed == nil, "\(model) does not support fast mode")
        }
    }

    @Test func fable51NeverReceivesDisabledThinking() throws {
        for effort in Effort.allCases {
            let r = RequestBuilder.build(model: "claude-fable-5-1", system: nil, user: "u", maxTokens: 10,
                                         effort: effort, thinking: .disabled, fastMode: false,
                                         useFallbacks: true, stream: false)
            #expect(r.thinking == nil, "thinking is always on for Fable 5.1, so the field is omitted")
            #expect(r.outputConfig?.effort == effort)
            #expect(r.fallbacks == .default)
        }
    }

    @Test func haiku45ReceivesNeitherEffortNorThinking() throws {
        let j = try json(RequestBuilder.build(
            model: "claude-haiku-4-5", system: nil, user: "u", maxTokens: 10, effort: .low,
            thinking: .adaptive, fastMode: true, useFallbacks: true, stream: false))
        #expect(j["thinking"] == nil)
        #expect(j["output_config"] == nil)
        #expect(j["fallbacks"] == nil)
        #expect(j["speed"] == nil)
    }

    @Test func haikuStillCarriesAStructuredOutputFormatWithoutEffort() throws {
        let j = try json(RequestBuilder.build(
            model: "claude-haiku-4-5", system: nil, user: "u", maxTokens: 10, effort: .low,
            thinking: .adaptive, fastMode: false, useFallbacks: false,
            format: OutputFormat(schema: ClarifyQuestions.jsonSchema), stream: false))
        let output = j["output_config"] as? [String: Any]
        #expect(output?["effort"] == nil, "effort 400s on Haiku")
        #expect((output?["format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func fallbacksAreSentOnlyWhereSupportedAndRequested() throws {
        #expect(RequestBuilder.build(model: "claude-opus-5", system: nil, user: "u", maxTokens: 1, effort: .low,
                                     thinking: .adaptive, fastMode: false, useFallbacks: true, stream: false).fallbacks == .default)
        #expect(RequestBuilder.build(model: "claude-opus-5", system: nil, user: "u", maxTokens: 1, effort: .low,
                                     thinking: .adaptive, fastMode: false, useFallbacks: false, stream: false).fallbacks == nil)
        #expect(RequestBuilder.build(model: "claude-sonnet-5", system: nil, user: "u", maxTokens: 1, effort: .low,
                                     thinking: .adaptive, fastMode: false, useFallbacks: true, stream: false).fallbacks == nil)
    }

    @Test func anUnknownModelGetsTheMinimalSafeRequest() throws {
        let j = try json(RequestBuilder.build(
            model: "claude-from-the-future", system: "s", user: "u", maxTokens: 10, effort: .max,
            thinking: .adaptive, fastMode: true, useFallbacks: true, stream: false))
        #expect(j["thinking"] == nil)
        #expect(j["output_config"] == nil)
        #expect(j["fallbacks"] == nil)
        #expect(j["speed"] == nil)
        #expect(j["model"] as? String == "claude-from-the-future")
    }

    @Test func passingNoThinkingModeOmitsTheField() throws {
        let j = try json(RequestBuilder.build(
            model: "claude-opus-5", system: nil, user: "u", maxTokens: 10, effort: .low,
            thinking: nil, fastMode: false, useFallbacks: false, stream: false))
        #expect(j["thinking"] == nil)
    }

    @Test func omittingTheSystemPromptOmitsTheField() throws {
        let j = try json(RequestBuilder.build(
            model: "claude-opus-5", system: nil, user: "u", maxTokens: 10, effort: .low,
            thinking: .adaptive, fastMode: false, useFallbacks: false, stream: false))
        #expect(j["system"] == nil)
    }

    @Test func structuredOutputSchemaIsEmbeddedVerbatim() throws {
        let j = try json(RequestBuilder.build(
            model: "claude-opus-5", system: nil, user: "q", maxTokens: 100, effort: .medium,
            thinking: .adaptive, fastMode: false, useFallbacks: true,
            format: OutputFormat(schema: ClarifyQuestions.jsonSchema), stream: false))
        let format = (j["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        let schema = format?["schema"] as? [String: Any]
        #expect(schema?["additionalProperties"] as? Bool == false, "the snake_case strategy must not rewrite schema keys")
        #expect(schema?["required"] as? [String] == ["questions"])
        let items = ((schema?["properties"] as? [String: Any])?["questions"] as? [String: Any])?["items"] as? [String: Any]
        #expect((items?["required"] as? [String])?.contains("suggested_answers") == true)
    }

    @Test func encodingIsByteForByteDeterministic() throws {
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: "S", user: "u", maxTokens: 10, effort: .low,
            thinking: .adaptive, fastMode: false, useFallbacks: true, stream: true)
        let a = try RequestCoding.encoder().encode(r)
        let b = try RequestCoding.encoder().encode(r)
        #expect(a == b, "identical requests must produce identical bytes for stable cache keys")
    }

    @Test func requestsRoundTripThroughTheirOwnCoders() throws {
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: "S", user: "u", maxTokens: 10, effort: .xhigh,
            thinking: .adaptive, fastMode: true, useFallbacks: true, stream: true)
        let data = try RequestCoding.encoder().encode(r)
        #expect(try RequestCoding.decoder().decode(MessageRequest.self, from: data) == r)
    }

    @Test func headersCombineEveryActiveBeta() throws {
        let c = ClaudeClient(apiKey: "sk-test")
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: nil, user: "u", maxTokens: 10, effort: .low,
            thinking: .adaptive, fastMode: true, useFallbacks: true, stream: true)
        let u = try c.urlRequest(for: r)
        #expect(u.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(u.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(u.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(u.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01,fast-mode-2026-02-01")
        #expect(u.httpMethod == "POST")
        #expect(u.url == ClaudeClient.defaultBaseURL)
        #expect(u.timeoutInterval >= 600, "long rewrites must not time out at the default 60s")
    }

    @Test func thinkingEncodesAndDecodesAsATaggedObject() throws {
        for value in [Thinking.adaptive, .disabled] {
            let data = try JSONEncoder().encode(value)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(obj?["type"] as? String == (value == .adaptive ? "adaptive" : "disabled"))
            #expect(try JSONDecoder().decode(Thinking.self, from: data) == value)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Thinking.self, from: Data(#"{"type":"enabled"}"#.utf8))
        }
    }

    @Test func fallbacksEncodesAsTheScalarDefaultString() throws {
        let data = try JSONEncoder().encode(Fallbacks.default)
        #expect(String(data: data, encoding: .utf8) == "\"default\"")
        #expect(try JSONDecoder().decode(Fallbacks.self, from: data) == .default)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Fallbacks.self, from: Data("\"auto\"".utf8))
        }
        #expect(Fallbacks.betaHeader == "server-side-fallback-2026-07-01")
        #expect(Speed.betaHeader == "fast-mode-2026-02-01")
    }
}
