import Foundation
import Testing
@testable import RepromptCore

@Suite struct PromptLibraryTests {
    @Test func everyPromptIsCompiledInAndLoadable() throws {
        let set = try PromptLibrary.loadAll()
        #expect(set.all.count == PromptName.allCases.count)
        for p in set.all {
            #expect(!p.text.isEmpty, "\(p.name.fileName) is empty")
            #expect(p.text.count > 200, "\(p.name.fileName) looks truncated")
            #expect(p.sha256.count == 64)
            #expect(p.shortHash == String(p.sha256.prefix(12)))
            #expect(p.source == nil, "the compiled-in copy has no file source")
        }
    }

    @Test func promptsAreDistinctFromOneAnother() throws {
        let set = try PromptLibrary.loadAll()
        #expect(Set(set.all.map(\.sha256)).count == set.all.count, "two prompts have identical text")
    }

    /// The prompt files are the product. These assertions pin the instructions the optimizer
    /// depends on, so an edit that removes one fails here instead of at runtime.
    @Test func promptsCarryTheirDefiningInstructions() throws {
        let set = try PromptLibrary.loadAll()
        #expect(set.optimizer.text.contains("Output only the rewritten prompt"))
        #expect(set.optimizer.text.lowercased().contains("never answer the prompt"))
        #expect(set.clarifyQuestions.text.contains("Return the JSON object only"))
        #expect(set.clarifyQuestions.text.lowercased().contains("never return more than three"))
        #expect(set.clarifyFinal.text.contains("Output only the rewritten prompt"))
        #expect(set.clarifyFinal.text.contains("<clarifications>"))
        #expect(set.judge.text.contains("Return the JSON object only"))
        #expect(set.judge.text.contains("\"tie\""))
    }

    @Test func fileNamesMatchThePromptNames() {
        #expect(PromptName.optimizer.fileName == "optimizer_system.md")
        #expect(PromptName.clarifyQuestions.fileName == "clarify_questions_system.md")
        #expect(PromptName.clarifyFinal.fileName == "clarify_final_system.md")
        #expect(PromptName.judge.fileName == "judge_system.md")
    }

    @Test func hashingIsStableAndContentAddressed() throws {
        let a = try PromptLibrary.loadAll().optimizer
        let b = try PromptLibrary.loadAll().optimizer
        #expect(a.sha256 == b.sha256, "the same bytes must hash the same on every load")
        #expect(a.sha256 == PromptLibrary.sha256(a.text))
        // Known-answer check against the SHA-256 of the empty string.
        #expect(PromptLibrary.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(PromptLibrary.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func anOverrideDirectoryReplacesOnlyTheFilesItContains() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reprompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "OVERRIDE TEXT".write(to: dir.appendingPathComponent("optimizer_system.md"), atomically: true, encoding: .utf8)

        let set = try PromptLibrary.loadAll(overrideDirectory: dir)
        #expect(set.optimizer.text == "OVERRIDE TEXT")
        #expect(set.optimizer.source?.lastPathComponent == "optimizer_system.md")
        #expect(set.optimizer.sha256 == PromptLibrary.sha256("OVERRIDE TEXT"))
        // The other three fall back to the compiled-in copies.
        #expect(set.judge.source == nil)
        #expect(set.clarifyFinal.source == nil)
        #expect(set.judge.sha256 == (try PromptLibrary.load(.judge).sha256))
    }

    @Test func aMissingOverrideDirectoryIsNotAnError() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let p = try PromptLibrary.load(.optimizer, overrideDirectory: missing)
        #expect(p.source == nil)
        #expect(p.sha256 == (try PromptLibrary.load(.optimizer).sha256))
    }

    @Test func aNonUTF8OverrideIsRejectedRatherThanSilentlyMangled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reprompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0xFF, 0xFE, 0x00, 0x9C]).write(to: dir.appendingPathComponent("optimizer_system.md"))
        #expect(throws: PromptLibraryError.self) {
            try PromptLibrary.load(.optimizer, overrideDirectory: dir)
        }
    }

    @Test func anEmptyOverrideFileIsLoadedAsEmptyNotIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reprompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "".write(to: dir.appendingPathComponent("judge_system.md"), atomically: true, encoding: .utf8)
        let p = try PromptLibrary.load(.judge, overrideDirectory: dir)
        #expect(p.text.isEmpty)
        #expect(p.source != nil, "an empty override is still an override, not a fallback")
    }
}
