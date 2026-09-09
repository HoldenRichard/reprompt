import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RepromptCore
import Testing
@testable import RepromptHarness

@Suite struct PairwiseJudgeTests {
    func judge(_ url: URL, model: String = "claude-opus-5") -> PairwiseJudge {
        PairwiseJudge(
            client: ClaudeClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(), retry: .none),
            prompt: SystemPrompt(name: .judge, text: "JUDGE-PROMPT",
                                 sha256: PromptLibrary.sha256("JUDGE-PROMPT"), source: nil),
            model: model)
    }

    /// A response whose only text block is the judge's JSON verdict.
    func verdictResponse(_ winner: String, reasoning: String = "because") -> MockURLProtocol.Stub {
        let inner = #"{"winner":"\#(winner)","reasoning":"\#(reasoning)"}"#
        let escaped = inner.replacingOccurrences(of: "\"", with: "\\\"")
        return .json(#"{"id":"m","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"\#(escaped)"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20}}"#)
    }

    /// If this mapping were inverted every scoreboard would read backwards, so all four
    /// combinations of presentation order and raw winner are pinned.
    @Test(arguments: [
        (true, "A", "optimized"), (true, "B", "original"),
        (false, "A", "original"), (false, "B", "optimized"),
        (true, "tie", "tie"), (false, "tie", "tie"),
    ])
    func rawWinnerMapsBackThroughThePresentationOrder(optimizedFirst: Bool, raw: String, expected: String) async throws {
        let url = MockURLProtocol.install(verdictResponse(raw))
        let v = try await judge(url).verdict(
            originalRequest: "REQ", answerOriginal: "ORIGINAL-ANSWER",
            answerOptimized: "OPTIMIZED-ANSWER", optimizedFirst: optimizedFirst)
        #expect(v.winner == expected)
        #expect(v.winnerRaw == raw)
        #expect(v.order == (optimizedFirst ? "optimized-first" : "original-first"))
        #expect(v.reasoning == "because")
        #expect(v.judgeModel == "claude-opus-5")
    }

    @Test func theJudgeSeesTheAnswersInTheStatedOrderAndNeverTheOptimizedPrompt() async throws {
        let url = MockURLProtocol.install(verdictResponse("A"))
        _ = try await judge(url).verdict(
            originalRequest: "THE-REQUEST", answerOriginal: "ORIGINAL-ANSWER",
            answerOptimized: "OPTIMIZED-ANSWER", optimizedFirst: true)
        let body = try #require(try MockURLProtocol.bodyJSON(for: url))
        let user = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)

        #expect(user.contains("<original_request>\nTHE-REQUEST\n</original_request>"))
        let aRange = try #require(user.range(of: "<response_a>"))
        let bRange = try #require(user.range(of: "<response_b>"))
        let a = String(user[aRange.upperBound..<bRange.lowerBound])
        #expect(a.contains("OPTIMIZED-ANSWER"), "optimizedFirst means the optimized answer is A")
        #expect(!a.contains("ORIGINAL-ANSWER"))
        // Blindness: the judge must never be shown the rewritten prompt itself.
        #expect(!user.contains("JUDGE-PROMPT") || (body["system"] as? [[String: Any]])?.first?["text"] as? String == "JUDGE-PROMPT")
        #expect((body["system"] as? [[String: Any]])?.first?["text"] as? String == "JUDGE-PROMPT")
    }

    @Test func reversingTheOrderSwapsWhichAnswerIsA() async throws {
        let url = MockURLProtocol.install(verdictResponse("A"))
        _ = try await judge(url).verdict(
            originalRequest: "R", answerOriginal: "ORIGINAL-ANSWER",
            answerOptimized: "OPTIMIZED-ANSWER", optimizedFirst: false)
        let user = try #require((try MockURLProtocol.bodyJSON(for: url)?["messages"] as? [[String: Any]])?.first?["content"] as? String)
        let a = String(user[user.range(of: "<response_a>")!.upperBound..<user.range(of: "<response_b>")!.lowerBound])
        #expect(a.contains("ORIGINAL-ANSWER"))
        #expect(!a.contains("OPTIMIZED-ANSWER"))
    }

    @Test func theJudgeRequestIsStructuredAndNonStreaming() async throws {
        let url = MockURLProtocol.install(verdictResponse("tie"))
        _ = try await judge(url).verdict(originalRequest: "R", answerOriginal: "a", answerOptimized: "b", optimizedFirst: true)
        let body = try #require(try MockURLProtocol.bodyJSON(for: url))
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_tokens"] as? Int == 1024)
        let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        let schema = try #require(format?["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        let winner = (schema["properties"] as? [String: Any])?["winner"] as? [String: Any]
        #expect(winner?["enum"] as? [String] == ["A", "B", "tie"])
    }

    @Test func aNonJSONVerdictIsADecodingError() async throws {
        let url = MockURLProtocol.install(.json(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"I prefer A."}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#))
        let err = await errorFrom {
            try await judge(url).verdict(originalRequest: "R", answerOriginal: "a", answerOptimized: "b", optimizedFirst: true)
        }
        guard case .decoding? = err as? ClaudeError else {
            Issue.record("expected .decoding, got \(String(describing: err))"); return
        }
    }

    @Test func aRefusedJudgementPropagates() async throws {
        let url = MockURLProtocol.install(.json(#"{"id":"m","type":"message","role":"assistant","model":"m","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"other","explanation":"no"},"usage":{"input_tokens":1,"output_tokens":0}}"#))
        let err = await errorFrom {
            try await judge(url).verdict(originalRequest: "R", answerOriginal: "a", answerOptimized: "b", optimizedFirst: true)
        }
        #expect(err as? ClaudeError == .refusal(category: "other", explanation: "no"))
    }

    @Test func verdictSchemaIsAValidStrictSchema() {
        guard case .object(let o) = JudgeVerdict.jsonSchema else { Issue.record("not an object"); return }
        #expect(o["additionalProperties"] == .bool(false))
        #expect(o["required"] == .array([.string("winner"), .string("reasoning")]))
        guard case .object(let props)? = o["properties"] else { Issue.record("no properties"); return }
        #expect(Set(props.keys) == ["winner", "reasoning"])
    }
}
