import Foundation
import Testing
@testable import RepromptCore
@testable import RepromptHarness

@Suite struct TranscriptHarvesterTests {
    var fixture: Data {
        let url = Bundle.module.url(forResource: "sample", withExtension: "jsonl", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("harvest-\(UUID().uuidString)")
    }

    @Test func extractsOnlyHumanPromptsAboveTheMinimumLength() {
        let raw = TranscriptHarvester.extract(jsonl: fixture, options: HarvestOptions(minChars: 80, maxChars: 6000))
        #expect(raw.count == 3)
        #expect(raw[0].text.hasPrefix("Please refactor"))
        #expect(raw[0].timestamp == "2026-09-01T10:00:00Z")
        #expect(raw[1].text.hasPrefix("Write me a cover letter"))
        #expect(raw[2].text.hasPrefix("please   REFACTOR"))
    }

    /// Everything the filter is supposed to reject, in one place: the corpus is the product's
    /// evaluation input, so a leak here quietly changes every score.
    @Test func rejectsNonHumanAndNonPromptLines() {
        let lines = [
            #"{"type":"user","isSidechain":false,"origin":{"kind":"human"},"message":{"role":"user","content":"<command-name>/clear</command-name> padded out to well beyond the minimum length for this filter."}}"#,
            #"{"type":"user","isSidechain":false,"origin":{"kind":"human"},"message":{"role":"user","content":"/compact this is a slash command that is long enough to pass the length filter comfortably."}}"#,
            #"{"type":"user","isSidechain":true,"origin":{"kind":"human"},"message":{"role":"user","content":"A sidechain prompt long enough to pass the minimum length filter without any trouble at all."}}"#,
            #"{"type":"user","isSidechain":false,"origin":{"kind":"task-notification"},"message":{"role":"user","content":"An agent notification that is long enough to pass the minimum length filter easily."}}"#,
            #"{"type":"user","isSidechain":false,"origin":null,"message":{"role":"user","content":"A tool result with a null origin, long enough to pass the minimum length filter easily."}}"#,
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"No origin field at all, but long enough to pass the minimum length filter easily here."}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"An assistant turn long enough to pass the minimum length filter but never harvestable."}]}}"#,
            #"{"type":"user","isSidechain":false,"origin":{"kind":"human"},"message":{"role":"user","content":"too short"}}"#,
            "not json at all",
            "",
        ]
        let raw = TranscriptHarvester.extract(jsonl: Data(lines.joined(separator: "\n").utf8), options: HarvestOptions())
        #expect(raw.isEmpty, "harvested \(raw.map { $0.text.prefix(40) })")
    }

    @Test func joinsTextBlocksAndIgnoresNonTextBlocks() {
        let line = #"{"type":"user","isSidechain":false,"origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"text","text":"First half of a prompt that is definitely long enough,"},{"type":"image","source":{}},{"type":"text","text":"and the second half of it."}]}}"#
        let raw = TranscriptHarvester.extract(jsonl: Data(line.utf8), options: HarvestOptions())
        #expect(raw.count == 1)
        #expect(raw[0].text == "First half of a prompt that is definitely long enough,\nand the second half of it.")
    }

    @Test func lengthBoundsAreInclusiveAndCountCharactersNotBytes() {
        let exactly = String(repeating: "é", count: 100)
        let line = #"{"type":"user","isSidechain":false,"origin":{"kind":"human"},"message":{"role":"user","content":"\#(exactly)"}}"#
        let data = Data(line.utf8)
        #expect(TranscriptHarvester.extract(jsonl: data, options: HarvestOptions(minChars: 100, maxChars: 100)).count == 1)
        #expect(TranscriptHarvester.extract(jsonl: data, options: HarvestOptions(minChars: 101, maxChars: 200)).isEmpty)
        #expect(TranscriptHarvester.extract(jsonl: data, options: HarvestOptions(minChars: 1, maxChars: 99)).isEmpty)
    }

    @Test func harvestDeduplicatesOnNormalisedText() throws {
        let root = tempRoot()
        let proj = root.appendingPathComponent("-Users-example-Desktop-Resume")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try fixture.write(to: proj.appendingPathComponent("s1.jsonl"))
        try fixture.write(to: proj.appendingPathComponent("s2.jsonl"))

        let got = try TranscriptHarvester.harvest(root: root, home: "/Users/example")
        // The case- and whitespace-variant duplicate collapses, and so does the second file.
        #expect(got.count == 2)
        #expect(got.map(\.id) == [1, 2])
        #expect(got[0].project == "Resume")
        #expect(got[0].category == "resume")
        #expect(got[0].sessionFile == "-Users-example-Desktop-Resume/s1.jsonl")
        #expect(Set(got.map(\.sha256)).count == 2)
        #expect(got[0].chars == got[0].text.count)
    }

    /// One prompt per project, each with distinct text, so ordering is observable.
    func line(_ text: String) -> Data {
        Data(#"{"type":"user","isSidechain":false,"origin":{"kind":"human"},"message":{"role":"user","content":"\#(text)"}}"#.utf8)
    }

    @Test func harvestIsDeterministicAcrossRuns() throws {
        let root = tempRoot()
        for name in ["-Users-example-App", "-Users-example-Desktop-Resume", "-Users-example-website"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try line("A unique prompt for \(name) that is comfortably longer than the minimum length filter.")
                .write(to: dir.appendingPathComponent("a.jsonl"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try TranscriptHarvester.harvest(root: root, home: "/Users/example")
        let second = try TranscriptHarvester.harvest(root: root, home: "/Users/example")
        #expect(first == second, "ids and ordering must not depend on directory enumeration order")
        // Directories are walked in sorted raw-name order: "-Users-example-App" sorts before
        // "-Users-example-Desktop-Resume", which sorts before "-Users-example-website".
        #expect(first.map(\.project) == ["App", "Resume", "website"])
        #expect(first.map(\.id) == [1, 2, 3], "ids are assigned in walk order")
    }

    /// The same text typed in two projects is one prompt: the corpus is deduplicated
    /// globally, not per project.
    @Test func identicalPromptsInDifferentProjectsCollapseToOne() throws {
        let root = tempRoot()
        for name in ["-Users-example-App", "-Users-example-Desktop-Resume"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try line("The very same prompt text, long enough to pass the minimum length filter easily.")
                .write(to: dir.appendingPathComponent("a.jsonl"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let got = try TranscriptHarvester.harvest(root: root, home: "/Users/example")
        #expect(got.count == 1)
        #expect(got[0].project == "App", "the first project in walk order keeps it")
    }

    @Test func nonJSONLFilesAndEmptyDirectoriesAreSkipped() throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("-Users-example-App")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-Users-example-Empty"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignore me".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try fixture.write(to: dir.appendingPathComponent("s.jsonl"))
        let got = try TranscriptHarvester.harvest(root: root, home: "/Users/example")
        #expect(got.count == 2)
        #expect(got.allSatisfy { $0.sessionFile.hasSuffix(".jsonl") })
    }

    @Test func anEmptyRootHarvestsNothingRatherThanFailing() throws {
        let root = tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try TranscriptHarvester.harvest(root: root, home: "/Users/example").isEmpty)
    }

    @Test func aMissingRootIsAnError() {
        #expect(throws: (any Error).self) {
            try TranscriptHarvester.harvest(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        }
    }

    @Test func projectNamesStripTheEncodedHomePathForAnyUser() {
        #expect(TranscriptHarvester.projectName(fromDir: "-Users-example-App-", home: "/Users/example") == "App")
        #expect(TranscriptHarvester.projectName(fromDir: "-Users-example-Desktop-research-notes", home: "/Users/example") == "research-notes")
        #expect(TranscriptHarvester.projectName(fromDir: "-Users-example-Hackathons-Spring26", home: "/Users/example") == "Hackathons-Spring26")
        #expect(TranscriptHarvester.projectName(fromDir: "-Users-example-", home: "/Users/example") == "-Users-example-")
        #expect(TranscriptHarvester.projectName(fromDir: "weird", home: "/Users/example") == "weird")
        // A different user's home must be stripped just the same.
        #expect(TranscriptHarvester.projectName(fromDir: "-home-jane-Code-cli", home: "/home/jane") == "cli")
        #expect(TranscriptHarvester.projectName(fromDir: "-Users-jane-Documents-Thesis", home: "/Users/jane") == "Thesis")
    }

    /// Nothing about the harvester may assume whose machine it runs on.
    @Test func harvesterSourceNamesNoParticularUser() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/HarnessTests/HarvesterTests.swift",
            with: "Sources/RepromptHarness/TranscriptHarvester.swift"), encoding: .utf8)
        // No hard-coded macOS home path of any user, and no project names.
        #expect(!source.contains("-Users-"))
        #expect(!source.contains("/Users/"))
        #expect(!source.contains("-home-"))
    }

    @Test func categoryIsTheLowercasedProjectName() {
        #expect(TranscriptHarvester.category(forProject: "Resume") == "resume")
        #expect(TranscriptHarvester.category(forProject: "research-notes") == "research-notes")
        #expect(TranscriptHarvester.category(forProject: "App") == "app")
    }
}

@Suite struct PromptCorpusTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID().uuidString)")
    }
    func prompt(id: Int, project: String = "Kabu", category: String = "ios-app",
                text: String = "hello: world") -> HarvestedPrompt {
        HarvestedPrompt(id: id, project: project, category: category, chars: text.count,
                        sha256: "hash\(id)", sessionFile: "x/y.jsonl", timestamp: nil, text: text)
    }

    @Test func writesAndReloadsAPrompt() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PromptCorpus.write([prompt(id: 7)], to: dir)
        let loaded = try PromptCorpus.load(directory: dir)
        #expect(loaded.count == 1)
        #expect(loaded[0].id == "0007-Kabu")
        #expect(loaded[0].project == "Kabu")
        #expect(loaded[0].category == "ios-app")
        #expect(loaded[0].text == "hello: world", "a colon in the body must not be read as front matter")
        #expect(loaded[0].chars == 12)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json").path))
    }

    @Test func fileNamesAreZeroPaddedAndSanitised() {
        #expect(PromptCorpus.fileName(for: prompt(id: 7)) == "0007-Kabu.md")
        #expect(PromptCorpus.fileName(for: prompt(id: 1234)) == "1234-Kabu.md")
        #expect(PromptCorpus.fileName(for: prompt(id: 1, project: "a b/c:d")) == "0001-a_b_c_d.md")
    }

    /// Regression: re-harvesting used to leave the previous run's files behind, so the
    /// directory and index.json disagreed and stale prompts crept into runs.
    @Test func rewritingTheCorpusClearsThePreviousHarvest() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PromptCorpus.write((1...5).map { prompt(id: $0) }, to: dir)
        #expect(try PromptCorpus.load(directory: dir).count == 5)

        try PromptCorpus.write([prompt(id: 1), prompt(id: 2)], to: dir)
        let after = try PromptCorpus.load(directory: dir)
        #expect(after.count == 2, "stale files survived: \(after.map(\.id))")

        let index = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("index.json"))) as? [[String: Any]]
        #expect(index?.count == 2, "the index and the directory must agree")
    }

    /// A hand-curated file is not named `NNNN-*.md`, so a rewrite must leave it alone.
    @Test func aHandCuratedFileSurvivesARewrite() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PromptCorpus.write([prompt(id: 1)], to: dir)
        try "---\ncategory: writing\n---\nmy own prompt".write(
            to: dir.appendingPathComponent("mine.md"), atomically: true, encoding: .utf8)
        try PromptCorpus.write([prompt(id: 2)], to: dir)
        let ids = try PromptCorpus.load(directory: dir).map(\.id).sorted()
        #expect(ids == ["0002-Kabu", "mine"])
    }

    @Test func generatedFileNamesAreRecognisedPrecisely() {
        #expect(PromptCorpus.isGeneratedFileName("0001-Kabu.md"))
        #expect(PromptCorpus.isGeneratedFileName("9999-a.md"))
        #expect(!PromptCorpus.isGeneratedFileName("mine.md"))
        #expect(!PromptCorpus.isGeneratedFileName("001-Kabu.md"))
        #expect(!PromptCorpus.isGeneratedFileName("index.json"))
        #expect(!PromptCorpus.isGeneratedFileName("0001-Kabu.md.bak"))
    }

    @Test func frontMatterIsParsedAndTheBodyIsKeptVerbatim() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("0001-Test.md")
        try """
        ---
        id: 0001
        project: Test
        category: research
        timestamp: 2026-01-01T00:00:00Z
        ---
        Line one: with a colon.

        Line two.
        """.write(to: file, atomically: true, encoding: .utf8)
        let p = try PromptCorpus.parse(file: file)
        #expect(p.category == "research")
        #expect(p.project == "Test")
        #expect(p.text == "Line one: with a colon.\n\nLine two.")
    }

    @Test func aFileWithoutFrontMatterIsStillUsable() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plain.md")
        try "just a prompt".write(to: file, atomically: true, encoding: .utf8)
        let p = try PromptCorpus.parse(file: file)
        #expect(p.text == "just a prompt")
        #expect(p.category == "misc")
        #expect(p.project == "unknown")
        #expect(p.id == "plain")
    }

    @Test func loadingSortsByFileNameSoRunsAreReproducible() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PromptCorpus.write([prompt(id: 10), prompt(id: 2), prompt(id: 1)], to: dir)
        #expect(try PromptCorpus.load(directory: dir).map(\.id) == ["0001-Kabu", "0002-Kabu", "0010-Kabu"])
    }

    @Test func unicodeAndMultilinePromptsSurviveTheRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "café 🎯\n\n---\nnot front matter\n\nsecond paragraph"
        try PromptCorpus.write([prompt(id: 1, text: text)], to: dir)
        #expect(try PromptCorpus.load(directory: dir)[0].text == text)
    }
}
