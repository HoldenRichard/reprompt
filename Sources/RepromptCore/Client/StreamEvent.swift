import Foundation

public enum StreamEvent: Sendable, Equatable {
    case messageStart(model: String, inputTokens: Int)
    /// `fallbackTo` is set when the block is a server-side fallback marker.
    case blockStart(index: Int, type: String, fallbackTo: String?)
    case textDelta(String)
    case messageDelta(stopReason: StopReason?, outputTokens: Int)
    case messageStop
    case ping
    case error(ClaudeError)
}
