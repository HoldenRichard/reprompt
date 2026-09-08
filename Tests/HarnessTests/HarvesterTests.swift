import Foundation
import Testing
@testable import RepromptHarness

@Suite struct HarvesterTests {
    var fixture: Data {
        let url = Bundle.module.url(forResource: "sample", withExtension: "jsonl", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    @Test func extractsOnlyHumanPromptsAboveMinLength() {
        let raw = TranscriptHarvester.extract(jsonl: fixture, options: HarvestOptions(minChars: 80, maxChars: 6000))
        #expect(raw.count == 3)
        #expect(raw[0].text.hasPrefix("Please refactor"))
        #expect(raw[0].timestamp == "2026-09-01T10:00:00Z")
        #expect(raw[1].text.hasPrefix("Write me a cover letter"))
        #expect(raw[2].text.hasPrefix("please   REFACTOR"))
    }

    @Test func harvestDedupesByNormalizedText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harvest-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("-Users-holden-Desktop-Resume")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try fixture.write(to: proj.appendingPathComponent("s1.jsonl"))
        try fixture.write(to: proj.appendingPathComponent("s2.jsonl"))
        let got = try TranscriptHarvester.harvest(root: root)
        #expect(got.count == 2)  // case/whitespace-normalized duplicate and the second file are collapsed
        #expect(got.map(\.id) == [1, 2])
        #expect(got[0].project == "Resume")
        #expect(got[0].category == "career-writing")
        #expect(got[0].sessionFile == "-Users-holden-Desktop-Resume/s1.jsonl")
    }

    @Test func projectNamesAndCategories() {
        #expect(TranscriptHarvester.projectName(fromDir: "-Users-holden-Kabu-") == "Kabu")
        #expect(TranscriptHarvester.projectName(fromDir: "-Users-holden-Desktop-ai-development-research") == "ai-development-research")
        #expect(TranscriptHarvester.projectName(fromDir: "-Users-holden-Hackathons-HackathonSF26") == "Hackathons-HackathonSF26")
        #expect(TranscriptHarvester.category(forProject: "Kabu") == "ios-app")
        #expect(TranscriptHarvester.category(forProject: "School-GRS-1105") == "research")
        #expect(TranscriptHarvester.category(forProject: "fix-github") == "misc")
    }

    @Test func corpusRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = HarvestedPrompt(id: 7, project: "Kabu", category: "ios-app", chars: 11, sha256: "abc", sessionFile: "x/y.jsonl", timestamp: nil, text: "hello: world")
        try PromptCorpus.write([p], to: dir)
        let loaded = try PromptCorpus.load(directory: dir)
        #expect(loaded.count == 1)
        #expect(loaded[0].id == "0007-Kabu")
        #expect(loaded[0].category == "ios-app")
        #expect(loaded[0].text == "hello: world")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json").path))
    }

    @Test func caseSettlement() {
        var c = CaseResult(promptID: "1", category: "misc", project: "p", model: "m", original: "o")
        c.settle()
        #expect(c.outcome == "none")
        c.verdicts = [.init(order: "a", winnerRaw: "A", winner: "optimized", reasoning: "", judgeModel: "j")]
        c.settle()
        #expect(c.outcome == "optimized")
        c.verdicts.append(.init(order: "b", winnerRaw: "A", winner: "original", reasoning: "", judgeModel: "j"))
        c.settle()
        #expect(c.outcome == "tie")
        #expect(c.judgeDisagreed)
    }

    @Test func percentiles() {
        #expect(percentile([1, 2, 3, 4, 5], 50) == 3)
        #expect(percentile([1, 2, 3, 4, 5], 90) == 4.6)
        #expect(percentile([], 50) == 0)
    }
}
