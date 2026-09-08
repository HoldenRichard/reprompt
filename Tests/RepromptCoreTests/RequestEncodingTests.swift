import Foundation
import Testing
@testable import RepromptCore

@Suite struct RequestEncodingTests {
    func json(_ r: MessageRequest) throws -> [String: Any] {
        let data = try RequestCoding.encoder().encode(r)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func opus5QuickRequestShape() throws {
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
        #expect(j["temperature"] == nil)
        let system = j["system"] as? [[String: Any]]
        #expect(system?.first?["text"] as? String == "SYS")
        #expect((system?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(r.betaHeaders == ["server-side-fallback-2026-07-01"])
    }

    @Test func opus5DisabledThinkingAllowedAtLowEffort() throws {
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: nil, user: "hi", maxTokens: 100, effort: .low,
            thinking: .disabled, fastMode: true, useFallbacks: false, stream: false)
        let j = try json(r)
        #expect((j["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(j["speed"] as? String == "fast")
        #expect(j["fallbacks"] == nil)
        #expect(j["system"] == nil)
        #expect(r.betaHeaders == ["fast-mode-2026-02-01"])
    }

    @Test func opus5DisabledThinkingRefusedAboveHigh() throws {
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: nil, user: "hi", maxTokens: 100, effort: .xhigh,
            thinking: .disabled, fastMode: false, useFallbacks: true, stream: false)
        #expect(r.thinking == .adaptive)
    }

    @Test func fable51NeverSendsDisabledThinkingOrFastMode() throws {
        let r = RequestBuilder.build(
            model: "claude-fable-5-1", system: nil, user: "hi", maxTokens: 100, effort: .low,
            thinking: .disabled, fastMode: true, useFallbacks: true, stream: false)
        let j = try json(r)
        #expect(j["thinking"] == nil)
        #expect(j["speed"] == nil)
        #expect(j["fallbacks"] as? String == "default")
        #expect((j["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func haiku45OmitsEffortThinkingAndBetas() throws {
        let r = RequestBuilder.build(
            model: "claude-haiku-4-5", system: nil, user: "hi", maxTokens: 100, effort: .low,
            thinking: .adaptive, fastMode: true, useFallbacks: true, stream: false)
        let j = try json(r)
        #expect(j["thinking"] == nil)
        #expect(j["output_config"] == nil)
        #expect(j["fallbacks"] == nil)
        #expect(j["speed"] == nil)
        #expect(r.betaHeaders.isEmpty)
    }

    @Test func sonnet5SendsEffortButNoFallbacks() throws {
        let r = RequestBuilder.build(
            model: "claude-sonnet-5", system: nil, user: "hi", maxTokens: 100, effort: .medium,
            thinking: .adaptive, fastMode: false, useFallbacks: true, stream: false)
        let j = try json(r)
        #expect((j["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(j["fallbacks"] == nil)
    }

    @Test func structuredOutputFormatEncodes() throws {
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: nil, user: "q", maxTokens: 100, effort: .medium,
            thinking: .adaptive, fastMode: false, useFallbacks: true,
            format: OutputFormat(schema: ClarifyQuestions.jsonSchema), stream: false)
        let j = try json(r)
        let format = (j["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        let schema = format?["schema"] as? [String: Any]
        #expect(schema?["additionalProperties"] as? Bool == false)
        #expect((schema?["required"] as? [String]) == ["questions"])
    }

    @Test func encodingIsDeterministic() throws {
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: "S", user: "u", maxTokens: 10, effort: .low,
            thinking: .adaptive, fastMode: false, useFallbacks: true, stream: true)
        let a = try RequestCoding.encoder().encode(r)
        let b = try RequestCoding.encoder().encode(r)
        #expect(a == b)
    }

    @Test func urlRequestHeaders() throws {
        let c = ClaudeClient(apiKey: "sk-test")
        let r = RequestBuilder.build(
            model: "claude-opus-5", system: nil, user: "u", maxTokens: 10, effort: .low,
            thinking: .adaptive, fastMode: true, useFallbacks: true, stream: true)
        let u = try c.urlRequest(for: r)
        #expect(u.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(u.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(u.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01,fast-mode-2026-02-01")
        #expect(u.httpMethod == "POST")
    }
}
