import AppKit
import Foundation
@testable import Reprompt
@testable import RepromptCore

@MainActor
final class FakeReader: SelectionReading {
    var result: Result<Selection, any Error>
    private(set) var readCount = 0
    var delay: Duration = .zero

    init(text: String = "original prompt", source: Selection.Source = .clipboard) {
        result = .success(Selection(text: text, app: nil, source: source, element: nil))
    }
    init(error: any Error) { result = .failure(error) }

    func read() async throws -> Selection {
        readCount += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

@MainActor
final class FakeInserter: TextInserting {
    struct Call: Equatable { var text: String; var preferAccessibility: Bool }
    private(set) var calls: [Call] = []
    var error: (any Error)?
    var delay: Duration = .zero

    func replace(_ selection: Selection, with text: String, preferAccessibility: Bool) async throws {
        calls.append(Call(text: text, preferAccessibility: preferAccessibility))
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
    }
}

/// A settings object backed by a throwaway defaults suite, so tests never touch the real one.
@MainActor
func scratchSettings(_ configure: (AppSettings) -> Void = { _ in }) -> (AppSettings, () -> Void) {
    let name = "com.holdenrichard.reprompt.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    let settings = AppSettings(defaults: defaults)
    configure(settings)
    return (settings, { UserDefaults.standard.removePersistentDomain(forName: name) })
}

@MainActor
func stubOptimizer(_ url: URL, config: OptimizerConfig) -> PromptOptimizer {
    PromptOptimizer(
        client: ClaudeClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session()),
        config: config,
        prompts: PromptSet(
            optimizer: SystemPrompt(name: .optimizer, text: "O", sha256: "o", source: nil),
            clarifyQuestions: SystemPrompt(name: .clarifyQuestions, text: "Q", sha256: "q", source: nil),
            clarifyFinal: SystemPrompt(name: .clarifyFinal, text: "F", sha256: "f", source: nil),
            judge: SystemPrompt(name: .judge, text: "J", sha256: "j", source: nil)))
}

/// Polls until `condition` holds or the timeout expires. Returns whether it held.
@MainActor
@discardableResult
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A message whose single text block is the given JSON, for the Clarify questions step.
func questionsResponse(_ json: String) -> MockURLProtocol.Stub {
    .json(#"{"id":"m","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":\#(jsonQuoted(json))}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":10}}"#)
}
