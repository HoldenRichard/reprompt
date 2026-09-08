import Foundation

public enum StopReason: Sendable, Equatable, Codable {
    case endTurn, maxTokens, stopSequence, toolUse, pauseTurn, refusal
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = StopReason(rawValue: s)
    }
    public init(rawValue s: String) {
        switch s {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "tool_use": self = .toolUse
        case "pause_turn": self = .pauseTurn
        case "refusal": self = .refusal
        default: self = .unknown(s)
        }
    }
    public var rawValue: String {
        switch self {
        case .endTurn: "end_turn"
        case .maxTokens: "max_tokens"
        case .stopSequence: "stop_sequence"
        case .toolUse: "tool_use"
        case .pauseTurn: "pause_turn"
        case .refusal: "refusal"
        case .unknown(let s): s
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct StopDetails: Codable, Sendable, Equatable {
    public var type: String?
    public var category: String?
    public var explanation: String?
}

public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int?
    public var cacheReadInputTokens: Int?
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int? = nil, cacheReadInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    /// Absent token counts decode as zero rather than failing. `message_delta` omits
    /// `input_tokens`, and a strict decode there would abort the entire stream.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreationInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
        cacheReadInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
    }
}

public enum ContentBlock: Sendable, Equatable, Decodable {
    case text(String)
    /// The server switched to a fallback model mid-request.
    case fallback(from: String?, to: String?)
    case other(type: String)

    private enum CodingKeys: String, CodingKey { case type, text, from, to }
    private struct ModelRef: Decodable { let model: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "fallback":
            let from = try c.decodeIfPresent(ModelRef.self, forKey: .from)?.model
            let to = try c.decodeIfPresent(ModelRef.self, forKey: .to)?.model
            self = .fallback(from: from, to: to)
        default:
            self = .other(type: type)
        }
    }
}

public struct MessageResponse: Decodable, Sendable {
    public var id: String
    public var model: String
    public var content: [ContentBlock]
    public var stopReason: StopReason?
    public var stopDetails: StopDetails?
    public var usage: Usage

    /// All text blocks joined.
    public var text: String {
        content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }
    /// Model that actually served. One fallback block is emitted per model that declined,
    /// so the LAST block names the model that finally answered.
    public var servedModel: String {
        var served = model
        for block in content { if case .fallback(_, let to) = block, let to { served = to } }
        return served
    }
}

/// The API's error envelope for non-2xx responses.
struct APIErrorEnvelope: Decodable {
    struct Inner: Decodable { let type: String; let message: String }
    let error: Inner
}
