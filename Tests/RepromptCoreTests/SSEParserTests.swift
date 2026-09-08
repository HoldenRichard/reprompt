import Foundation
import Testing
@testable import RepromptCore

@Suite struct SSEParserTests {
    func events(_ lines: [String]) -> [StreamEvent] {
        var p = SSEParser()
        return lines.compactMap { p.feed($0) }
    }

    @Test func parsesTypicalStream() {
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5","content":[],"stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1}}}"#,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            "",
            "event: ping",
            #"data: {"type":"ping"}"#,
            "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        #expect(events(lines) == [
            .messageStart(model: "claude-opus-5", inputTokens: 25),
            .blockStart(index: 0, type: "text", fallbackTo: nil),
            .ping,
            .textDelta("Hel"), .textDelta("lo"),
            .messageDelta(stopReason: .endTurn, outputTokens: 12),
            .messageStop,
        ])
    }

    @Test func dropsThinkingDeltasAndSurfacesFallback() {
        let lines = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5"},"to":{"model":"claude-opus-4-8"}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"ok"}}"#,
        ]
        #expect(events(lines) == [
            .blockStart(index: 0, type: "thinking", fallbackTo: nil),
            .blockStart(index: 1, type: "fallback", fallbackTo: "claude-opus-4-8"),
            .textDelta("ok"),
        ])
    }

    @Test func refusalAndErrorEvents() {
        let lines = [
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#,
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ]
        #expect(events(lines) == [
            .messageDelta(stopReason: .refusal, outputTokens: 0),
            .error(.stream(type: "overloaded_error", message: "Overloaded")),
        ])
    }

    @Test func unknownStopReasonIsPreserved() {
        let lines = [#"data: {"type":"message_delta","delta":{"stop_reason":"new_thing"},"usage":{"output_tokens":3}}"#]
        #expect(events(lines) == [.messageDelta(stopReason: .unknown("new_thing"), outputTokens: 3)])
    }

    @Test func malformedDataYieldsDecodingError() {
        let e = events(["data: {not json"])
        #expect(e.count == 1)
        if case .error(.decoding) = e[0] {} else { Issue.record("expected decoding error, got \(e)") }
    }
}
