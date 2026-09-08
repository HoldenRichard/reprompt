import Foundation
import Testing
@testable import RepromptCore

@Suite struct SSEParserTests {
    func events(_ lines: [String]) -> [StreamEvent] {
        var p = SSEParser()
        return lines.compactMap { p.feed($0) }
    }

    @Test func parsesATypicalStream() {
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
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":1}"}}"#,
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

    @Test func unknownEventTypesAreIgnoredRatherThanFatal() {
        let lines = [
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"some_future_event","payload":{"a":1}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        #expect(events(lines) == [.messageStop])
    }

    /// A `message_delta` carries no `input_tokens`. A strict decode there would abort the
    /// whole stream, which is why `Usage` defaults absent counts to zero.
    @Test func partialUsageObjectsDecodeRatherThanKillingTheStream() {
        #expect(events([#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#])
            == [.messageDelta(stopReason: .endTurn, outputTokens: 7)])
        // message_start whose usage omits output_tokens entirely.
        #expect(events([#"data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"claude-sonnet-5","content":[],"usage":{"input_tokens":9}}}"#])
            == [.messageStart(model: "claude-sonnet-5", inputTokens: 9)])
        // and one with no usage counts at all.
        #expect(events([#"data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"m1","content":[],"usage":{}}}"#])
            == [.messageStart(model: "m1", inputTokens: 0)])
    }

    @Test func messageDeltaWithoutUsageReportsZero() {
        #expect(events([#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#])
            == [.messageDelta(stopReason: .endTurn, outputTokens: 0)])
    }

    @Test func toleratesCRLFLineEndings() {
        #expect(events([#"data: {"type":"message_stop"}"# + "\r"]) == [.messageStop])
        #expect(events(["event: ping\r", #"data: {"type":"ping"}"# + "\r"]) == [.ping])
    }

    @Test func toleratesDataLinesWithoutASpaceAfterTheColon() {
        #expect(events([#"data:{"type":"message_stop"}"#]) == [.messageStop])
    }

    @Test func nonDataLinesAndEmptyPayloadsProduceNothing() {
        #expect(events(["", "event: ping", ": keepalive comment", "id: 42", "data:", "data: "]).isEmpty)
    }

    /// Only ONE leading space is stripped, per the SSE spec, so a payload that legitimately
    /// begins with whitespace is not corrupted.
    @Test func stripsExactlyOneLeadingSpace() {
        var p = SSEParser()
        #expect(p.feed(#"data:  {"type":"ping"}"#) != nil)  // second space is part of the JSON, still valid
        var q = SSEParser()
        if case .error(.decoding)? = q.feed("data:  not json") {} else { Issue.record("expected a decoding error") }
    }

    @Test func malformedDataYieldsDecodingError() {
        let e = events(["data: {not json"])
        #expect(e.count == 1)
        if case .error(.decoding) = e[0] {} else { Issue.record("expected decoding error, got \(e)") }
    }

    @Test func textDeltaPreservesUnicodeAndEscapes() {
        let lines = [#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"café \"q\" \n\ttab 🎯"}}"#]
        #expect(events(lines) == [.textDelta("café \"q\" \n\ttab 🎯")])
    }

    @Test func emptyTextDeltaIsStillAnEvent() {
        #expect(events([#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"#])
            == [.textDelta("")])
    }
}
