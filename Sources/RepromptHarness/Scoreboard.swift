import Foundation
import RepromptCore

struct ModelScore: Codable, Sendable {
    var model: String
    var cases: Int
    var errors: Int
    var wins: Int
    var losses: Int
    var ties: Int
    var unjudged: Int
    var disagreements: Int
    var ttfbP50: Double
    var ttfbP90: Double
    var totalP50: Double
    var totalP90: Double
    var totalMean: Double
    var optimizerInputTokens: Int
    var optimizerOutputTokens: Int
    var allInputTokens: Int
    var allOutputTokens: Int
    var estimatedCostUSD: Double
    var perCategory: [String: [String: Int]]

    var netPoints: Int { wins - losses }
    var winRate: Double { let j = wins + losses + ties; return j == 0 ? 0 : Double(wins) / Double(j) }
}

enum Scoreboard {
    static func compute(_ cases: [CaseResult], judgeModel: String?) -> [ModelScore] {
        let models = Array(Set(cases.map(\.model))).sorted()
        return models.map { model in
            let cs = cases.filter { $0.model == model }
            let info = ModelCatalog.infoOrGeneric(for: model)
            let judgeInfo = judgeModel.map(ModelCatalog.infoOrGeneric(for:))
            var wins = 0, losses = 0, ties = 0, unjudged = 0, errors = 0, disagreements = 0
            var ttfb: [Double] = [], total: [Double] = []
            var optIn = 0, optOut = 0, allIn = 0, allOut = 0
            var cost = 0.0
            var perCategory: [String: [String: Int]] = [:]
            for c in cs {
                if c.error != nil { errors += 1 }
                switch c.outcome {
                case "optimized": wins += 1
                case "original": losses += 1
                case "tie": ties += 1
                default: unjudged += 1
                }
                if c.judgeDisagreed { disagreements += 1 }
                perCategory[c.category, default: [:]][c.outcome, default: 0] += 1
                if let o = c.optimize {
                    if let t = o.ttfbMs { ttfb.append(t) }
                    total.append(o.totalMs)
                    optIn += o.inputTokens; optOut += o.outputTokens
                    cost += info.cost(usage: Usage(inputTokens: o.inputTokens, outputTokens: o.outputTokens))
                }
                for call in [c.optimize, c.answerOriginal, c.answerOptimized].compactMap({ $0 }) {
                    allIn += call.inputTokens; allOut += call.outputTokens
                }
                for call in [c.answerOriginal, c.answerOptimized].compactMap({ $0 }) {
                    cost += info.cost(usage: Usage(inputTokens: call.inputTokens, outputTokens: call.outputTokens))
                }
                if let cl = c.clarify {
                    allIn += cl.inputTokens; allOut += cl.outputTokens
                    cost += info.cost(usage: Usage(inputTokens: cl.inputTokens, outputTokens: cl.outputTokens))
                }
                // Judge calls are not recorded with usage; estimate from text sizes.
                if let j = judgeInfo, !c.verdicts.isEmpty {
                    let approxIn = (c.original.count + (c.answerOriginal?.text.count ?? 0) + (c.answerOptimized?.text.count ?? 0)) / 4 + 400
                    cost += Double(c.verdicts.count) * j.cost(usage: Usage(inputTokens: approxIn, outputTokens: 150))
                }
            }
            return ModelScore(
                model: model, cases: cs.count, errors: errors, wins: wins, losses: losses, ties: ties,
                unjudged: unjudged, disagreements: disagreements,
                ttfbP50: percentile(ttfb, 50), ttfbP90: percentile(ttfb, 90),
                totalP50: percentile(total, 50), totalP90: percentile(total, 90),
                totalMean: total.isEmpty ? 0 : total.reduce(0, +) / Double(total.count),
                optimizerInputTokens: optIn, optimizerOutputTokens: optOut,
                allInputTokens: allIn, allOutputTokens: allOut, estimatedCostUSD: cost,
                perCategory: perCategory)
        }
    }

    static func markdown(_ scores: [ModelScore], runName: String, promptHash: String?) -> String {
        var s = "# Scoreboard \(runName)\n\n"
        if let h = promptHash { s += "Optimizer prompt: `\(h.prefix(12))`\n\n" }
        s += "| model | cases | wins | losses | ties | net | win rate | disagree | ttfb p50 | ttfb p90 | total p50 | total p90 | opt tokens in/out | est. cost |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for m in scores {
            // Interpolation rather than %@: on Linux String(format:) does not bridge a Swift String.
            let numbers = String(format: "%d | %d | %d | %d | %+d | %.0f%% | %d | %.0f ms | %.0f ms | %.0f ms | %.0f ms | %d/%d | $%.2f",
                                 m.cases, m.wins, m.losses, m.ties, m.netPoints, m.winRate * 100, m.disagreements,
                                 m.ttfbP50, m.ttfbP90, m.totalP50, m.totalP90,
                                 m.optimizerInputTokens, m.optimizerOutputTokens, m.estimatedCostUSD)
            s += "| \(m.model) | \(numbers) |\n"
        }
        s += "\nwins = optimized prompt's answer judged better. `total` is optimizer latency to last token.\n"
        for m in scores where !m.perCategory.isEmpty {
            s += "\n## \(m.model) by category\n\n| category | optimized | original | tie | none |\n|---|---|---|---|---|\n"
            for (cat, counts) in m.perCategory.sorted(by: { $0.key < $1.key }) {
                s += "| \(cat) | \(counts["optimized"] ?? 0) | \(counts["original"] ?? 0) | \(counts["tie"] ?? 0) | \(counts["none"] ?? 0) |\n"
            }
            if m.errors > 0 { s += "\nErrors: \(m.errors) case(s) failed; see case.json `error`.\n" }
        }
        return s
    }

    static func write(_ cases: [CaseResult], runDir: URL, judgeModel: String?) throws {
        let scores = compute(cases, judgeModel: judgeModel)
        let hash = cases.compactMap(\.optimizerPromptHash).first
        let md = markdown(scores, runName: runDir.lastPathComponent, promptHash: hash)
        try md.write(to: runDir.appendingPathComponent("scoreboard.md"), atomically: true, encoding: .utf8)
        try RunWriter.jsonEncoder().encode(scores).write(to: runDir.appendingPathComponent("scoreboard.json"))
        print(md)
    }
}
