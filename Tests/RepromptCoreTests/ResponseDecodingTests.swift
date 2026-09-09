import Foundation
import Testing
@testable import RepromptCore

@Suite struct ResponseDecodingTests {
    func decode(_ json: String) throws -> MessageResponse {
        try RequestCoding.decoder().decode(MessageResponse.self, from: Data(json.utf8))
    }

    @Test func decodesATextResponse() throws {
        let r = try decode(#"{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"hello"},{"type":"text","text":" world"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":8}}"#)
        #expect(r.id == "msg_1")
        #expect(r.text == "hello world")
        #expect(r.stopReason == .endTurn)
        #expect(r.usage.inputTokens == 10)
        #expect(r.usage.cacheReadInputTokens == 8)
        #expect(r.usage.cacheCreationInputTokens == nil)
        #expect(r.servedModel == "claude-opus-5")
        #expect(r.stopDetails == nil)
    }

    @Test func nonTextBlocksAreKeptButExcludedFromTheText() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"x"},{"type":"tool_use","id":"t","name":"n","input":{}}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#)
        #expect(r.text == "x")
        #expect(r.content.count == 3)
        #expect(r.content[0] == .other(type: "thinking"))
        #expect(r.content[2] == .other(type: "tool_use"))
    }

    @Test func decodesARefusalWithItsCategory() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"nope"},"usage":{"input_tokens":1,"output_tokens":0}}"#)
        #expect(r.stopReason == .refusal)
        #expect(r.stopDetails?.category == "cyber")
        #expect(r.stopDetails?.explanation == "nope")
        #expect(r.text.isEmpty)
    }

    @Test func aSingleFallbackBlockNamesTheServingModel() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"claude-fable-5-1","content":[{"type":"fallback","from":{"model":"claude-fable-5-1"},"to":{"model":"claude-opus-4-8"}},{"type":"text","text":"x"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#)
        #expect(r.servedModel == "claude-opus-4-8")
        #expect(r.content.first == .fallback(from: "claude-fable-5-1", to: "claude-opus-4-8"))
    }

    /// Regression: one fallback block is emitted per model that declined, so on a chain the
    /// LAST block names the model that actually answered. Reading the first mislabelled it.
    @Test func aFallbackChainReportsTheLastModelNotTheFirst() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"claude-fable-5-1","content":[{"type":"fallback","from":{"model":"claude-fable-5-1"},"to":{"model":"claude-opus-5"}},{"type":"fallback","from":{"model":"claude-opus-5"},"to":{"model":"claude-opus-4-8"}},{"type":"text","text":"x"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#)
        #expect(r.servedModel == "claude-opus-4-8")
    }

    @Test func noFallbackMeansTheRequestedModelServed() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"claude-sonnet-5","content":[{"type":"text","text":"x"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#)
        #expect(r.servedModel == "claude-sonnet-5")
    }

    @Test func aNullStopReasonDecodesAsNil() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[],"stop_reason":null,"usage":{"input_tokens":1,"output_tokens":1}}"#)
        #expect(r.stopReason == nil)
    }

    @Test func anUnrecognisedStopReasonIsPreservedVerbatim() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[],"stop_reason":"something_new","usage":{"input_tokens":1,"output_tokens":1}}"#)
        #expect(r.stopReason == .unknown("something_new"))
        #expect(r.stopReason?.rawValue == "something_new")
    }

    @Test func everyKnownStopReasonMapsBothWays() throws {
        let pairs: [(String, StopReason)] = [
            ("end_turn", .endTurn), ("max_tokens", .maxTokens), ("stop_sequence", .stopSequence),
            ("tool_use", .toolUse), ("pause_turn", .pauseTurn), ("refusal", .refusal),
        ]
        for (raw, expected) in pairs {
            #expect(StopReason(rawValue: raw) == expected)
            #expect(expected.rawValue == raw)
            let encoded = try JSONEncoder().encode(expected)
            #expect(String(data: encoded, encoding: .utf8) == "\"\(raw)\"")
        }
    }

    /// Regression: a strict `Usage` decode would fail on any payload missing a token count,
    /// and inside the SSE parser that failure aborted the user's entire request.
    @Test func usageToleratesMissingTokenCounts() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[],"stop_reason":"end_turn","usage":{"output_tokens":4}}"#)
        #expect(r.usage.inputTokens == 0)
        #expect(r.usage.outputTokens == 4)
        let empty = try decode(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[],"stop_reason":"end_turn","usage":{}}"#)
        #expect(empty.usage == Usage(inputTokens: 0, outputTokens: 0))
    }

    @Test func aTextBlockWithNoTextFieldDecodesAsEmpty() throws {
        let r = try decode(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[{"type":"text"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#)
        #expect(r.content.first == .text(""))
        #expect(r.text.isEmpty)
    }

    @Test func aMissingRequiredFieldIsARealDecodingFailure() {
        // No `model`: this is a malformed response and must not decode silently.
        #expect(throws: (any Error).self) {
            try decode(#"{"id":"m","type":"message","content":[],"usage":{"input_tokens":1,"output_tokens":1}}"#)
        }
    }

    @Test func errorEnvelopesAreMappedToTypedErrors() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#.utf8)
        let resp = HTTPURLResponse(url: ClaudeClient.defaultBaseURL, statusCode: 400, httpVersion: nil, headerFields: nil)!
        #expect(throws: ClaudeError.api(status: 400, type: "invalid_request_error", message: "bad")) {
            try ClaudeClient.check(response: resp, body: body)
        }
    }

    @Test func aSuccessStatusPassesTheCheck() {
        let resp = HTTPURLResponse(url: ClaudeClient.defaultBaseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        #expect(throws: Never.self) { try ClaudeClient.check(response: resp, body: Data()) }
    }

    @Test func aNonHTTPResponseIsRejected() {
        let resp = URLResponse(url: ClaudeClient.defaultBaseURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        #expect(throws: ClaudeError.invalidResponse("not HTTP")) {
            try ClaudeClient.check(response: resp, body: Data())
        }
    }

    @Test func errorDescriptionsAreHumanReadable() {
        #expect(ClaudeError.missingAPIKey.description.contains("ANTHROPIC_API_KEY"))
        #expect(ClaudeError.api(status: 429, type: "rate_limit_error", message: "slow").description
            == "API error 429 (rate_limit_error): slow")
        #expect(ClaudeError.refusal(category: "cyber", explanation: "no").description == "Request declined (cyber): no")
        #expect(ClaudeError.refusal(category: nil, explanation: nil).description == "Request declined")
        #expect(ClaudeError.truncated(partial: "x").description.contains("max_tokens"))
    }
}
