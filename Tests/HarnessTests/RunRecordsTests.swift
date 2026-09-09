import Foundation
import Testing
@testable import RepromptCore
@testable import RepromptHarness

func makeCall(_ text: String = "answer", ttfb: Double? = nil, total: Double = 1000,
              input: Int = 100, output: Int = 200, stop: String? = "end_turn",
              served: String = "claude-opus-5") -> CaseResult.Call {
    CaseResult.Call(text: text, servedModel: served, ttfbMs: ttfb, totalMs: total,
                    inputTokens: input, outputTokens: output, stopReason: stop)
}

func makeCase(id: String, model: String = "claude-opus-5", category: String = "ios-app",
              outcome: String = "none", verdicts: [CaseResult.Verdict] = [],
              optimize: CaseResult.Call? = makeCall(ttfb: 500, total: 1200),
              answers: Bool = true, error: String? = nil) -> CaseResult {
    var c = CaseResult(promptID: id, category: category, project: "P", model: model, original: "ORIGINAL")
    c.optimize = optimize
    if answers {
        c.answerOriginal = makeCall("A-orig", total: 2000, input: 50, output: 300)
        c.answerOptimized = makeCall("A-opt", total: 2100, input: 60, output: 320)
    }
    c.verdicts = verdicts
    c.outcome = outcome
    c.error = error
    c.optimizerPromptHash = "abc123def456789"
    return c
}

func verdict(_ winner: String, order: String = "optimized-first") -> CaseResult.Verdict {
    CaseResult.Verdict(order: order, winnerRaw: winner == "optimized" ? "A" : "B",
                       winner: winner, reasoning: "r", judgeModel: "claude-opus-5")
}

@Suite struct CaseResultTests {
    @Test func aSingleVerdictSettlesToItsWinner() {
        for winner in ["optimized", "original", "tie"] {
            var c = makeCase(id: "1", verdicts: [verdict(winner)])
            c.settle()
            #expect(c.outcome == winner)
            #expect(!c.judgeDisagreed)
        }
    }

    @Test func twoAgreeingVerdictsSettleToThatWinner() {
        var c = makeCase(id: "1", verdicts: [verdict("optimized"), verdict("optimized", order: "original-first")])
        c.settle()
        #expect(c.outcome == "optimized")
        #expect(!c.judgeDisagreed)
    }

    /// Order-dependence means the judge is reacting to presentation, not quality, so the
    /// case must not count as a win for either side.
    @Test func twoDisagreeingVerdictsSettleToATie() {
        var c = makeCase(id: "1", verdicts: [verdict("optimized"), verdict("original", order: "original-first")])
        c.settle()
        #expect(c.outcome == "tie")
        #expect(c.judgeDisagreed)

        var soft = makeCase(id: "2", verdicts: [verdict("optimized"), verdict("tie", order: "original-first")])
        soft.settle()
        #expect(soft.outcome == "tie")
        #expect(soft.judgeDisagreed)
    }

    @Test func noVerdictsMeansUnjudged() {
        var c = makeCase(id: "1")
        c.settle()
        #expect(c.outcome == "none")
        #expect(!c.judgeDisagreed)
    }

    @Test func theCaseDirectoryKeepsPromptAndModelSeparate() {
        #expect(makeCase(id: "0007-Kabu", model: "claude-sonnet-5").dirName == "0007-Kabu/claude-sonnet-5")
    }

    @Test func casesRoundTripThroughJSONWithEveryField() throws {
        var c = makeCase(id: "0001-Kabu", outcome: "optimized", verdicts: [verdict("optimized")])
        c.clarify = CaseResult.Clarify(
            questions: ClarifyQuestions(questions: [
                ClarifyQuestion(id: "q", question: "Who?", why: "w", suggestedAnswers: ["a", "b"]),
            ]), totalMs: 900, inputTokens: 10, outputTokens: 20)
        let data = try RunWriter.jsonEncoder().encode(c)
        let back = try JSONDecoder().decode(CaseResult.self, from: data)
        #expect(back.promptID == c.promptID)
        #expect(back.outcome == "optimized")
        #expect(back.optimize?.ttfbMs == 500)
        #expect(back.answerOptimized?.text == "A-opt")
        #expect(back.verdicts.count == 1)
        #expect(back.clarify?.questions.questions.first?.suggestedAnswers == ["a", "b"])
        #expect(back.optimizerPromptHash == "abc123def456789")
    }
}

@Suite struct RunWriterTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Regression: two runs launched in the same second shared a directory and mixed results.
    @Test func twoRunsInTheSameSecondGetSeparateDirectories() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try RunWriter.newRunDirectory(under: root, now: now)
        let b = try RunWriter.newRunDirectory(under: root, now: now)
        let c = try RunWriter.newRunDirectory(under: root, now: now)
        #expect(Set([a.path, b.path, c.path]).count == 3)
        #expect(a.lastPathComponent == "20270115-080000")
        #expect(b.lastPathComponent == "20270115-080000-2")
        #expect(c.lastPathComponent == "20270115-080000-3")
        for d in [a, b, c] { #expect(FileManager.default.fileExists(atPath: d.path)) }
    }

    @Test func runDirectoriesAreNamedInUTCRegardlessOfLocale() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try RunWriter.newRunDirectory(under: root, now: Date(timeIntervalSince1970: 0))
        #expect(d.lastPathComponent == "19700101-000000")
    }

    @Test func aRunRecordFreezesTheConfigAndThePromptsItUsed() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let prompts = PromptSet(
            optimizer: SystemPrompt(name: .optimizer, text: "OPT", sha256: "h1", source: nil),
            clarifyQuestions: SystemPrompt(name: .clarifyQuestions, text: "QQ", sha256: "h2", source: nil),
            clarifyFinal: SystemPrompt(name: .clarifyFinal, text: "FIN", sha256: "h3", source: nil),
            judge: SystemPrompt(name: .judge, text: "JDG", sha256: "h4", source: nil))
        let record = RunRecord(
            startedAt: "2026-09-09T00:00:00Z", arguments: ["run", "--judge"],
            models: ["claude-opus-5"], config: .default, judgeModel: "claude-opus-5",
            bothOrders: true, promptHashes: ["optimizer_system": "h1"], gitRevision: "abc1234",
            promptCount: 3)
        try RunWriter.writeRunRecord(record, prompts: prompts, to: root)

        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("run.json"))) as? [String: Any]
        #expect(json?["promptCount"] as? Int == 3)
        #expect(json?["gitRevision"] as? String == "abc1234")
        #expect((json?["config"] as? [String: Any])?["model"] as? String == OptimizerConfig.default.model)
        // The exact prompt text used is frozen alongside the results.
        let frozen = root.appendingPathComponent("prompts/optimizer_system.md")
        #expect(try String(contentsOf: frozen, encoding: .utf8) == "OPT")
        #expect(try String(contentsOf: root.appendingPathComponent("prompts/judge_system.md"), encoding: .utf8) == "JDG")
    }

    @Test func casesAreWrittenAsBothJSONAndReadableFiles() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var c = makeCase(id: "0001-Kabu", outcome: "optimized", verdicts: [verdict("optimized")])
        c.optimize = makeCall("OPTIMIZED PROMPT", ttfb: 400, total: 1100)
        try RunWriter.write(c, in: root)

        let dir = root.appendingPathComponent("0001-Kabu/claude-opus-5")
        #expect(try String(contentsOf: dir.appendingPathComponent("original.md"), encoding: .utf8) == "ORIGINAL")
        #expect(try String(contentsOf: dir.appendingPathComponent("optimized.md"), encoding: .utf8) == "OPTIMIZED PROMPT")
        #expect(try String(contentsOf: dir.appendingPathComponent("answer_original.md"), encoding: .utf8) == "A-orig")
        #expect(try String(contentsOf: dir.appendingPathComponent("answer_optimized.md"), encoding: .utf8) == "A-opt")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("judge.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("case.json").path))
    }

    @Test func loadCasesFindsEveryCaseAndSortsThemStably() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, model) in [("0002-A", "claude-sonnet-5"), ("0001-A", "claude-opus-5"),
                            ("0001-A", "claude-sonnet-5"), ("0002-A", "claude-opus-5")] {
            try RunWriter.write(makeCase(id: id, model: model), in: root)
        }
        let loaded = try RunWriter.loadCases(in: root)
        #expect(loaded.map { "\($0.promptID)/\($0.model)" } == [
            "0001-A/claude-opus-5", "0001-A/claude-sonnet-5",
            "0002-A/claude-opus-5", "0002-A/claude-sonnet-5",
        ])
    }

    @Test func loadingAnEmptyRunDirectoryYieldsNothing() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try RunWriter.loadCases(in: root).isEmpty)
    }

    @Test func aCaseWithoutOptionalCallsStillWrites() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = makeCase(id: "0003-X", optimize: nil, answers: false, error: "boom")
        try RunWriter.write(c, in: root)
        let back = try RunWriter.loadCases(in: root)
        #expect(back.count == 1)
        #expect(back[0].error == "boom")
        #expect(back[0].optimize == nil)
        let dir = root.appendingPathComponent("0003-X/claude-opus-5")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("optimized.md").path))
    }
}
