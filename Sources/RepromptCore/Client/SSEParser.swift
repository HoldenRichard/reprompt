import Foundation

/// Parses Anthropic SSE lines into `StreamEvent`s. Every `data:` line carries a complete
/// JSON object with a `type` field, so `event:` lines and blank separators are ignored.
public struct SSEParser: Sendable {
    public init() {}

    private struct Envelope: Decodable { let type: String }
    private struct MessageStart: Decodable {
        struct Msg: Decodable { let model: String; let usage: Usage }
        let message: Msg
    }
    private struct BlockStart: Decodable {
        struct ModelRef: Decodable { let model: String? }
        struct Block: Decodable { let type: String; let to: ModelRef? }
        let index: Int
        let contentBlock: Block
    }
    private struct BlockDelta: Decodable {
        struct Delta: Decodable { let type: String; let text: String? }
        let index: Int
        let delta: Delta
    }
    private struct MessageDelta: Decodable {
        struct Delta: Decodable { let stopReason: StopReason? }
        struct U: Decodable { let outputTokens: Int? }
        let delta: Delta
        let usage: U?
    }
    private struct ErrorEvent: Decodable {
        struct E: Decodable { let type: String; let message: String }
        let error: E
    }

    /// Feed one line (without its trailing newline). Returns an event when the line completes one.
    public mutating func feed(_ line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        guard let data = payload.data(using: .utf8), !payload.isEmpty else { return nil }
        let dec = RequestCoding.decoder()
        do {
            let type = try dec.decode(Envelope.self, from: data).type
            switch type {
            case "message_start":
                let m = try dec.decode(MessageStart.self, from: data).message
                return .messageStart(model: m.model, inputTokens: m.usage.inputTokens)
            case "content_block_start":
                let b = try dec.decode(BlockStart.self, from: data)
                return .blockStart(index: b.index, type: b.contentBlock.type, fallbackTo: b.contentBlock.to?.model)
            case "content_block_delta":
                let d = try dec.decode(BlockDelta.self, from: data)
                if d.delta.type == "text_delta", let t = d.delta.text { return .textDelta(t) }
                return nil  // thinking_delta, signature_delta, input_json_delta: dropped
            case "message_delta":
                let d = try dec.decode(MessageDelta.self, from: data)
                return .messageDelta(stopReason: d.delta.stopReason, outputTokens: d.usage?.outputTokens ?? 0)
            case "message_stop":
                return .messageStop
            case "ping":
                return .ping
            case "error":
                let e = try dec.decode(ErrorEvent.self, from: data).error
                return .error(.stream(type: e.type, message: e.message))
            default:
                return nil  // content_block_stop and unknown events
            }
        } catch {
            return .error(.decoding("\(error) in: \(payload.prefix(200))"))
        }
    }
}
