import Foundation

public enum ClaudeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Non-2xx HTTP response with the API's error envelope.
    case api(status: Int, type: String, message: String)
    /// An `error` event arrived mid-stream.
    case stream(type: String, message: String)
    case decoding(String)
    case network(String)
    case missingAPIKey
    /// The model (or the whole fallback chain) declined the request.
    case refusal(category: String?, explanation: String?)
    /// Output hit `max_tokens` before finishing.
    case truncated(partial: String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .api(let status, let type, let message): "API error \(status) (\(type)): \(message)"
        case .stream(let type, let message): "Stream error (\(type)): \(message)"
        case .decoding(let s): "Decoding error: \(s)"
        case .network(let s): "Network error: \(s)"
        case .missingAPIKey: "No API key. Export ANTHROPIC_API_KEY or save one in Settings."
        case .refusal(let category, let explanation):
            "Request declined" + (category.map { " (\($0))" } ?? "") + (explanation.map { ": \($0)" } ?? "")
        case .truncated: "Output was cut off at max_tokens; raise the limit."
        case .invalidResponse(let s): "Invalid response: \(s)"
        }
    }
}
