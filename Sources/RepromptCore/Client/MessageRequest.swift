import Foundation

public enum Role: String, Codable, Sendable { case user, assistant }

public struct Message: Codable, Sendable, Equatable {
    public var role: Role
    public var content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
    public static func user(_ text: String) -> Message { Message(role: .user, content: text) }
}

public struct CacheControl: Codable, Sendable, Equatable {
    public var type: String = "ephemeral"
    public init() {}
}

public struct SystemBlock: Codable, Sendable, Equatable {
    public var type: String = "text"
    public var text: String
    public var cacheControl: CacheControl?
    public init(text: String, cached: Bool = true) {
        self.text = text
        self.cacheControl = cached ? CacheControl() : nil
    }
}

/// Thinking configuration for 4.6+ models. `nil` omits the parameter entirely.
public enum Thinking: Codable, Sendable, Equatable {
    case adaptive
    case disabled

    private enum CodingKeys: String, CodingKey { case type }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .adaptive: try c.encode("adaptive", forKey: .type)
        case .disabled: try c.encode("disabled", forKey: .type)
        }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .type)
        switch t {
        case "adaptive": self = .adaptive
        case "disabled": self = .disabled
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown thinking type \(t)")
        }
    }
}

public enum Effort: String, Codable, Sendable, CaseIterable { case low, medium, high, xhigh, max }

public struct OutputFormat: Codable, Sendable, Equatable {
    public var type: String = "json_schema"
    public var schema: JSONValue
    public init(schema: JSONValue) { self.schema = schema }
}

public struct OutputConfig: Codable, Sendable, Equatable {
    public var effort: Effort?
    public var format: OutputFormat?
    public init(effort: Effort? = nil, format: OutputFormat? = nil) {
        self.effort = effort
        self.format = format
    }
}

/// Server-side refusal fallbacks. Only the `"default"` scalar form is used.
public enum Fallbacks: Codable, Sendable, Equatable {
    case `default`
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode("default")
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        guard try c.decode(String.self) == "default" else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported fallbacks value")
        }
        self = .default
    }
    public static let betaHeader = "server-side-fallback-2026-07-01"
}

public enum Speed: String, Codable, Sendable {
    case fast
    public static let betaHeader = "fast-mode-2026-02-01"
}

public struct MessageRequest: Codable, Sendable, Equatable {
    public var model: String
    public var maxTokens: Int
    public var system: [SystemBlock]?
    public var messages: [Message]
    public var stream: Bool
    public var thinking: Thinking?
    public var outputConfig: OutputConfig?
    public var fallbacks: Fallbacks?
    public var speed: Speed?

    public init(
        model: String,
        maxTokens: Int,
        system: [SystemBlock]? = nil,
        messages: [Message],
        stream: Bool = false,
        thinking: Thinking? = nil,
        outputConfig: OutputConfig? = nil,
        fallbacks: Fallbacks? = nil,
        speed: Speed? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.stream = stream
        self.thinking = thinking
        self.outputConfig = outputConfig
        self.fallbacks = fallbacks
        self.speed = speed
    }

    /// Beta header values implied by the request body.
    public var betaHeaders: [String] {
        var h: [String] = []
        if fallbacks != nil { h.append(Fallbacks.betaHeader) }
        if speed != nil { h.append(Speed.betaHeader) }
        return h
    }
}

public enum RequestCoding {
    /// Deterministic encoding (snake_case keys, sorted) so identical requests produce identical bytes.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
