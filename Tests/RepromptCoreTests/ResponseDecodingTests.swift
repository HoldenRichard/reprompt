import Foundation
import Testing
@testable import RepromptCore

@Suite struct ResponseDecodingTests {
    @Test func decodesTextResponse() throws {
        let json = #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"hello"},{"type":"text","text":" world"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":8}}"#
        let r = try RequestCoding.decoder().decode(MessageResponse.self, from: Data(json.utf8))
        #expect(r.text == "hello world")
        #expect(r.stopReason == .endTurn)
        #expect(r.usage.cacheReadInputTokens == 8)
        #expect(r.servedModel == "claude-opus-5")
        #expect(r.stopDetails == nil)
    }

    @Test func decodesFallbackAndRefusal() throws {
        let json = #"{"id":"m","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"fallback","from":{"model":"claude-opus-5"},"to":{"model":"claude-opus-4-8"}},{"type":"text","text":"x"},{"type":"thinking","thinking":"..."}],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"nope"},"usage":{"input_tokens":1,"output_tokens":1}}"#
        let r = try RequestCoding.decoder().decode(MessageResponse.self, from: Data(json.utf8))
        #expect(r.servedModel == "claude-opus-4-8")
        #expect(r.text == "x")
        #expect(r.stopReason == .refusal)
        #expect(r.stopDetails?.category == "cyber")
        #expect(r.content.count == 3)
    }

    @Test func apiErrorEnvelope() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#.utf8)
        let resp = HTTPURLResponse(url: ClaudeClient.defaultBaseURL, statusCode: 400, httpVersion: nil, headerFields: nil)!
        #expect(throws: ClaudeError.api(status: 400, type: "invalid_request_error", message: "bad")) {
            try ClaudeClient.check(response: resp, body: body)
        }
    }
}
