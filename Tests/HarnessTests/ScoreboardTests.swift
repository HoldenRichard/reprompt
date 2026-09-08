import Foundation
import Testing
@testable import RepromptCore
@testable import RepromptHarness

@Suite struct ScoreboardTests {
    /// Five Opus cases (2 wins, 1 loss, 1 tie, 1 unjudged) and one Sonnet case.
    func fixture() -> [CaseResult] {
        var cases: [CaseResult] = []
        for (id, outcome) in [("1", "optimized"), ("2", "optimized"), ("3", "original"), ("4", "tie")] {
            var c = makeCase(id: id, outcome: outcome, verdicts: [verdict(outcome)])
            c.optimize = makeCall("opt", ttfb: Double(id)! * 100, total: Double(id)! * 1000)
            cases.append(c)
        }
        var unjudged = makeCase(id: "5")
        unjudged.optimize = makeCall("opt", ttfb: 500, total: 5000)
        cases.append(unjudged)
        cases.append(makeCase(id: "6", model: "claude-sonnet-5", category: "research",
                              outcome: "optimized", verdicts: [verdict("optimized")]))
        return cases
    }

    @Test func outcomesAreCountedPerModel() {
        let scores = Scoreboard.compute(fixture(), judgeModel: nil)
        #expect(scores.map(\.model) == ["claude-opus-5", "claude-sonnet-5"], "models are listed in a stable order")
        let opus = scores[0]
        #expect(opus.cases == 5)
        #expect(opus.wins == 2)
        #expect(opus.losses == 1)
        #expect(opus.ties == 1)
        #expect(opus.unjudged == 1)
        #expect(opus.netPoints == 1)
        #expect(abs(opus.winRate - 0.5) < 1e-9, "win rate counts judged cases only")
        #expect(scores[1].cases == 1)
        #expect(scores[1].wins == 1)
    }

    @Test func latencyPercentilesComeFromTheOptimizerCallsOnly() {
        let opus = Scoreboard.compute(fixture(), judgeModel: nil)[0]
        // totals: 1000, 2000, 3000, 4000, 5000
        #expect(abs(opus.totalP50 - 3000) < 1e-9)
        #expect(abs(opus.totalMean - 3000) < 1e-9)
        #expect(abs(opus.totalP90 - 4600) < 1e-9)
        // ttfb: 100, 200, 300, 400, 500
        #expect(abs(opus.ttfbP50 - 300) < 1e-9)
    }

    @Test func tokensAreSummedForTheOptimizerAndForEveryCall() {
        let opus = Scoreboard.compute(fixture(), judgeModel: nil)[0]
        #expect(opus.optimizerInputTokens == 5 * 100)
        #expect(opus.optimizerOutputTokens == 5 * 200)
        // Each case also has two answer calls at 50/300 and 60/320.
        #expect(opus.allInputTokens == 5 * (100 + 50 + 60))
        #expect(opus.allOutputTokens == 5 * (200 + 300 + 320))
    }

    @Test func costIsPositiveAndScalesWithThePricierModel() {
        let scores = Scoreboard.compute(fixture(), judgeModel: nil)
        #expect(scores[0].estimatedCostUSD > 0)
        #expect(scores[1].estimatedCostUSD > 0)
        // One Sonnet case must cost less than one Opus case at identical token counts.
        let oneOpus = Scoreboard.compute([makeCase(id: "x", model: "claude-opus-5")], judgeModel: nil)[0]
        let oneSonnet = Scoreboard.compute([makeCase(id: "x", model: "claude-sonnet-5")], judgeModel: nil)[0]
        #expect(oneSonnet.estimatedCostUSD < oneOpus.estimatedCostUSD)
    }

    @Test func addingAJudgeIncreasesTheEstimatedCost() {
        var judged = makeCase(id: "1", outcome: "optimized", verdicts: [verdict("optimized")])
        judged.optimize = makeCall()
        let without = Scoreboard.compute([judged], judgeModel: nil)[0].estimatedCostUSD
        let with = Scoreboard.compute([judged], judgeModel: "claude-opus-5")[0].estimatedCostUSD
        #expect(with > without)
    }

    @Test func disagreementsAndErrorsAreCounted() {
        var disagree = makeCase(id: "1", verdicts: [verdict("optimized"), verdict("original", order: "original-first")])
        disagree.settle()
        let failed = makeCase(id: "2", optimize: nil, answers: false, error: "boom")
        let s = Scoreboard.compute([disagree, failed], judgeModel: nil)[0]
        #expect(s.disagreements == 1)
        #expect(s.errors == 1)
        #expect(s.ties == 1)
        #expect(s.unjudged == 1)
    }

    @Test func categoryBreakdownGroupsOutcomes() {
        let cases = [
            makeCase(id: "1", category: "ios-app", outcome: "optimized"),
            makeCase(id: "2", category: "ios-app", outcome: "original"),
            makeCase(id: "3", category: "research", outcome: "optimized"),
        ]
        let s = Scoreboard.compute(cases, judgeModel: nil)[0]
        #expect(s.perCategory["ios-app"]?["optimized"] == 1)
        #expect(s.perCategory["ios-app"]?["original"] == 1)
        #expect(s.perCategory["research"]?["optimized"] == 1)
        #expect(s.perCategory["research"]?["original"] == nil)
    }

    @Test func anEmptyRunProducesNoScoresRatherThanCrashing() {
        #expect(Scoreboard.compute([], judgeModel: nil).isEmpty)
        let noCalls = Scoreboard.compute([makeCase(id: "1", optimize: nil, answers: false)], judgeModel: nil)[0]
        #expect(noCalls.totalP50 == 0)
        #expect(noCalls.totalMean == 0)
        #expect(noCalls.winRate == 0)
    }

    @Test func markdownReportsTheHeadlineNumbersAndThePromptVersion() {
        let scores = Scoreboard.compute(fixture(), judgeModel: nil)
        let md = Scoreboard.markdown(scores, runName: "20260909-120000", promptHash: "abc123def456789")
        #expect(md.contains("# Scoreboard 20260909-120000"))
        #expect(md.contains("`abc123def456`"), "the prompt version must be attributable")
        #expect(md.contains("| claude-opus-5 | 5 | 2 | 1 | 1 | +1 | 50% |"))
        #expect(md.contains("## claude-opus-5 by category"))
        #expect(md.contains("wins = optimized prompt's answer judged better"))
    }

    @Test func markdownOmitsThePromptLineWhenThereIsNoHash() {
        let md = Scoreboard.markdown(Scoreboard.compute(fixture(), judgeModel: nil),
                                     runName: "r", promptHash: nil)
        #expect(!md.contains("Optimizer prompt:"))
    }

    @Test func markdownFlagsFailedCases() {
        let failed = makeCase(id: "1", optimize: nil, answers: false, error: "boom")
        let md = Scoreboard.markdown(Scoreboard.compute([failed], judgeModel: nil), runName: "r", promptHash: nil)
        #expect(md.contains("Errors: 1 case(s) failed"))
    }

    @Test func scoreboardFilesAreWrittenToTheRunDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Scoreboard.write(fixture(), runDir: dir, judgeModel: "claude-opus-5")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("scoreboard.md").path))
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("scoreboard.json"))) as? [[String: Any]]
        #expect(json?.count == 2)
        #expect(json?.first?["model"] as? String == "claude-opus-5")
    }
}

@Suite struct SamplingTests {
    func corpus(_ counts: [String: Int]) -> [CorpusPrompt] {
        var out: [CorpusPrompt] = []
        for (category, n) in counts.sorted(by: { $0.key < $1.key }) {
            for i in 1...n {
                out.append(CorpusPrompt(id: "\(category)-\(String(format: "%03d", i))",
                                        project: "P", category: category, text: "t"))
            }
        }
        return out
    }

    @Test func sequenceIsDeterministicForASeedAndDiffersBetweenSeeds() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42), c = SplitMix64(seed: 43)
        let first = (0..<5).map { _ in a.next() }
        let second = (0..<5).map { _ in b.next() }
        let other = (0..<5).map { _ in c.next() }
        #expect(first == second)
        #expect(first != other)
        #expect(Set(first).count == 5, "a usable generator does not repeat immediately")
    }

    @Test func samplingSpansEveryCategoryBeforeTakingSecondsFromAny() {
        var rng = SplitMix64(seed: 1)
        let pool = corpus(["ios-app": 100, "career-writing": 10, "research": 5, "hackathon": 2])
        let sample = RunCommand.stratifiedSample(pool, n: 8, rng: &rng)
        #expect(sample.count == 8)
        #expect(Set(sample.map(\.category)).count == 4, "a small sample must still span the categories")
        // Round-robin: with four categories, eight picks means two from each.
        let counts = Dictionary(grouping: sample, by: \.category).mapValues(\.count)
        #expect(counts.values.allSatisfy { $0 == 2 })
    }

    @Test func aThinCategoryDoesNotStarveTheSample() {
        var rng = SplitMix64(seed: 7)
        let sample = RunCommand.stratifiedSample(corpus(["big": 50, "tiny": 1]), n: 10, rng: &rng)
        #expect(sample.count == 10)
        #expect(sample.filter { $0.category == "tiny" }.count == 1)
        #expect(sample.filter { $0.category == "big" }.count == 9)
    }

    @Test func askingForMoreThanExistsReturnsEverythingOnce() {
        var rng = SplitMix64(seed: 3)
        let pool = corpus(["a": 3, "b": 2])
        let sample = RunCommand.stratifiedSample(pool, n: 99, rng: &rng)
        #expect(sample.count == 5)
        #expect(Set(sample.map(\.id)).count == 5, "no prompt may appear twice")
    }

    @Test func theSampleIsOrderedByIDSoRunsAreComparable() {
        var rng = SplitMix64(seed: 11)
        let sample = RunCommand.stratifiedSample(corpus(["a": 10, "b": 10]), n: 6, rng: &rng)
        #expect(sample.map(\.id) == sample.map(\.id).sorted())
    }

    @Test func theSameSeedSelectsTheSamePrompts() {
        let pool = corpus(["a": 20, "b": 20])
        var r1 = SplitMix64(seed: 99), r2 = SplitMix64(seed: 99), r3 = SplitMix64(seed: 100)
        let a = RunCommand.stratifiedSample(pool, n: 6, rng: &r1).map(\.id)
        let b = RunCommand.stratifiedSample(pool, n: 6, rng: &r2).map(\.id)
        let c = RunCommand.stratifiedSample(pool, n: 6, rng: &r3).map(\.id)
        #expect(a == b, "a seeded run must be reproducible")
        #expect(a != c)
    }

    @Test func emptyInputsAreHandled() {
        var rng = SplitMix64(seed: 1)
        #expect(RunCommand.stratifiedSample([], n: 5, rng: &rng).isEmpty)
        #expect(RunCommand.stratifiedSample(corpus(["a": 3]), n: 0, rng: &rng).isEmpty)
    }

    @Test func percentilesInterpolateAndHandleEdges() {
        let v: [Double] = [1, 2, 3, 4, 5]
        #expect(abs(percentile(v, 0) - 1) < 1e-9)
        #expect(abs(percentile(v, 50) - 3) < 1e-9)
        #expect(abs(percentile(v, 90) - 4.6) < 1e-9)
        #expect(abs(percentile(v, 100) - 5) < 1e-9)
        #expect(percentile([], 50) == 0)
        #expect(percentile([7], 90) == 7)
        #expect(abs(percentile([5, 1, 3], 50) - 3) < 1e-9, "input order must not matter")
    }
}
