import Foundation
import RepromptCore

struct JudgeVerdict: Codable, Sendable {
    var winner: String
    var reasoning: String

    static let jsonSchema: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["winner", "reasoning"],
        "properties": [
            "winner": ["type": "string", "enum": ["A", "B", "tie"]],
            "reasoning": ["type": "string"],
        ],
    ]
}

/// Blind pairwise comparison. The judge sees the original request and two answers; it never
/// sees the optimized prompt. The caller decides which answer is A and records it.
struct PairwiseJudge: Sendable {
    var client: any LLMClient
    var prompt: SystemPrompt
    var model: String

    func judge(originalRequest: String, a: String, b: String) async throws -> JudgeVerdict {
        let user = """
        <original_request>
        \(originalRequest)
        </original_request>

        <response_a>
        \(a)
        </response_a>

        <response_b>
        \(b)
        </response_b>
        """
        let req = ChatRequest(
            model: model, system: prompt.text, user: user, maxTokens: 1024, stream: false,
            jsonSchema: JudgeVerdict.jsonSchema, effort: .medium, thinking: .adaptive)
        let resp = try await client.send(req)
        if resp.stopReason == .refusal {
            throw ClaudeError.refusal(category: resp.stopDetails?.category, explanation: resp.stopDetails?.explanation)
        }
        guard let data = resp.text.data(using: .utf8) else { throw ClaudeError.decoding("judge output not UTF-8") }
        do { return try JSONDecoder().decode(JudgeVerdict.self, from: data) } catch {
            throw ClaudeError.decoding("judge JSON: \(error); text: \(resp.text.prefix(200))")
        }
    }

    /// Run the comparison with a chosen order and map the raw A/B winner back to original/optimized.
    func verdict(originalRequest: String, answerOriginal: String, answerOptimized: String, optimizedFirst: Bool) async throws -> CaseResult.Verdict {
        let (a, b) = optimizedFirst ? (answerOptimized, answerOriginal) : (answerOriginal, answerOptimized)
        let v = try await judge(originalRequest: originalRequest, a: a, b: b)
        let mapped: String
        switch v.winner {
        case "A": mapped = optimizedFirst ? "optimized" : "original"
        case "B": mapped = optimizedFirst ? "original" : "optimized"
        default: mapped = "tie"
        }
        return CaseResult.Verdict(
            order: optimizedFirst ? "optimized-first" : "original-first",
            winnerRaw: v.winner, winner: mapped, reasoning: v.reasoning, judgeModel: model)
    }
}
