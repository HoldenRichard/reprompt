import ArgumentParser
import Foundation
import RepromptCore

struct JudgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "judge", abstract: "Re-judge an existing run directory without re-generating answers.")

    @Option(name: .long, help: "Run directory (runs/<timestamp>).", completion: .directory) var run: String
    @Option(name: .long) var judgeModel: String = ModelCatalog.opus5.id
    @Flag(name: .long) var bothOrders = false
    @Option(name: .long) var concurrency: Int = 3
    @Option(name: .long) var seed: UInt64 = 42
    @Option(name: .long, help: "Prompt override directory (for a revised judge_system.md).", completion: .directory) var promptsDir: String?

    mutating func run() async throws {
        let runDir = URL(fileURLWithPath: run)
        let cases = try RunWriter.loadCases(in: runDir)
        guard !cases.isEmpty else { throw ValidationError("No case.json files under \(run)") }
        let prompts = try PromptLibrary.loadAll(overrideDirectory: promptsDir.map { URL(fileURLWithPath: $0) })
        let judge = PairwiseJudge(client: ClaudeClient(apiKey: try APIKeyProvider.resolve()), prompt: prompts.judge, model: judgeModel)
        var rng = SplitMix64(seed: seed)
        let orders = cases.map { _ in Bool.random(using: &rng) }
        let both = bothOrders
        var results: [CaseResult] = []
        try await withThrowingTaskGroup(of: CaseResult.self) { group in
            var i = 0
            func addNext(_ group: inout ThrowingTaskGroup<CaseResult, any Error>) -> Bool {
                guard i < cases.count else { return false }
                var c = cases[i]; let first = orders[i]; i += 1
                group.addTask {
                    guard let ao = c.answerOriginal, let ap = c.answerOptimized else { return c }
                    c.verdicts = []
                    do {
                        c.verdicts.append(try await judge.verdict(originalRequest: c.original, answerOriginal: ao.text, answerOptimized: ap.text, optimizedFirst: first))
                        if both {
                            c.verdicts.append(try await judge.verdict(originalRequest: c.original, answerOriginal: ao.text, answerOptimized: ap.text, optimizedFirst: !first))
                        }
                        c.settle()
                        c.error = nil
                    } catch { c.error = "judge: \(error)" }
                    return c
                }
                return true
            }
            for _ in 0..<max(1, concurrency) { if !addNext(&group) { break } }
            while let r = try await group.next() {
                try RunWriter.write(r, in: runDir)
                eprint("\(r.promptID) \(r.model): \(r.outcome)")
                results.append(r)
                _ = addNext(&group)
            }
        }
        try Scoreboard.write(results, runDir: runDir, judgeModel: judgeModel)
    }
}
