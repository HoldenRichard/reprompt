import Foundation

public enum StreamEvent: Sendable, Equatable {
    case messageStart(model: String, inputTokens: Int)
    /// `fallbackTo` is set when the block is a server-side fallback marker.
    case blockStart(index: Int, type: String, fallbackTo: String?)
    case textDelta(String)
    /// `inputTokens` is 0 until known: Anthropic reports it up front on `messageStart`,
    /// while Groq and Gemini only report it in the final chunk.
    case messageDelta(stopReason: StopReason?, outputTokens: Int, inputTokens: Int)
    case messageStop
    case ping
    case error(ClaudeError)
}
