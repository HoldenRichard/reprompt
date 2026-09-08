import Foundation
import RepromptCore

/// Everything recorded for one (prompt, model) case. Written as case.json so `judge` can
/// re-score a run without re-paying for answers.
struct CaseResult: Codable, Sendable {
    struct Call: Codable, Sendable {
        var text: String
        var servedModel: String
        var ttfbMs: Double?
        var totalMs: Double
        var inputTokens: Int
        var outputTokens: Int
        var stopReason: String?
    }
    struct Clarify: Codable, Sendable {
        var questions: ClarifyQuestions
        var totalMs: Double
        var inputTokens: Int
        var outputTokens: Int
    }
    struct Verdict: Codable, Sendable {
        /// "optimized-first" or "original-first": which answer was shown as A.
        var order: String
        var winnerRaw: String
        /// "optimized", "original", or "tie".
        var winner: String
        var reasoning: String
        var judgeModel: String
    }

    var promptID: String
    var category: String
    var project: String
    var model: String
    var original: String
    var optimize: Call?
    var clarify: Clarify?
    var answerOriginal: Call?
    var answerOptimized: Call?
    var verdicts: [Verdict] = []
    /// Final outcome after combining verdicts: optimized | original | tie | none.
    var outcome: String = "none"
    var error: String?
    var optimizerPromptHash: String?

    var dirName: String { promptID + "/" + model }

    /// Combine verdicts: a single verdict stands; two that disagree count as a tie.
    mutating func settle() {
        guard !verdicts.isEmpty else { outcome = "none"; return }
        let winners = Set(verdicts.map(\.winner))
        outcome = winners.count == 1 ? winners.first! : "tie"
    }
    var judgeDisagreed: Bool { verdicts.count > 1 && Set(verdicts.map(\.winner)).count > 1 }
}

struct RunRecord: Codable, Sendable {
    var startedAt: String
    var arguments: [String]
    var models: [String]
    var config: OptimizerConfig
    var judgeModel: String?
    var bothOrders: Bool
    var promptHashes: [String: String]
    var gitRevision: String?
    var promptCount: Int
}

enum RunWriter {
    static func newRunDirectory(under root: URL) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        let dir = root.appendingPathComponent(f.string(from: Date()))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func writeRunRecord(_ r: RunRecord, prompts: PromptSet, to dir: URL) throws {
        try jsonEncoder().encode(r).write(to: dir.appendingPathComponent("run.json"))
        let pdir = dir.appendingPathComponent("prompts")
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        for p in prompts.all {
            try p.text.write(to: pdir.appendingPathComponent(p.name.fileName), atomically: true, encoding: .utf8)
        }
    }

    static func write(_ c: CaseResult, in runDir: URL) throws {
        let dir = runDir.appendingPathComponent(c.dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jsonEncoder().encode(c).write(to: dir.appendingPathComponent("case.json"))
        try c.original.write(to: dir.appendingPathComponent("original.md"), atomically: true, encoding: .utf8)
        if let o = c.optimize { try o.text.write(to: dir.appendingPathComponent("optimized.md"), atomically: true, encoding: .utf8) }
        if let a = c.answerOriginal { try a.text.write(to: dir.appendingPathComponent("answer_original.md"), atomically: true, encoding: .utf8) }
        if let a = c.answerOptimized { try a.text.write(to: dir.appendingPathComponent("answer_optimized.md"), atomically: true, encoding: .utf8) }
        if !c.verdicts.isEmpty { try jsonEncoder().encode(c.verdicts).write(to: dir.appendingPathComponent("judge.json")) }
    }

    static func loadCases(in runDir: URL) throws -> [CaseResult] {
        let fm = FileManager.default
        var out: [CaseResult] = []
        guard let e = fm.enumerator(at: runDir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in e where url.lastPathComponent == "case.json" {
            out.append(try JSONDecoder().decode(CaseResult.self, from: Data(contentsOf: url)))
        }
        return out.sorted { ($0.promptID, $0.model) < ($1.promptID, $1.model) }
    }

    static func gitRevision() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
