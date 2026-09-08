import Foundation
import Testing
@testable import RepromptCore

@Suite struct OptimizerTests {
    @Test func embeddedPromptsLoadAndHash() throws {
        let set = try PromptLibrary.loadAll()
        for p in set.all {
            #expect(!p.text.isEmpty)
            #expect(p.sha256.count == 64)
            #expect(p.source == nil)
        }
        #expect(set.optimizer.text.contains("Output only the rewritten prompt"))
        #expect(set.optimizer.sha256 != set.clarifyFinal.sha256)
    }

    @Test func overrideDirectoryWins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reprompt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "OVERRIDE".write(to: dir.appendingPathComponent("optimizer_system.md"), atomically: true, encoding: .utf8)
        let p = try PromptLibrary.load(.optimizer, overrideDirectory: dir)
        #expect(p.text == "OVERRIDE")
        #expect(p.source != nil)
        #expect(p.sha256 == PromptLibrary.sha256("OVERRIDE"))
        // Files not present in the override dir fall back to the embedded copy.
        let j = try PromptLibrary.load(.judge, overrideDirectory: dir)
        #expect(j.source == nil)
    }

    @Test func cleanOutputStripsFencesAndTags() {
        #expect(PromptOptimizer.cleanOutput("```\nhello\n```") == "hello")
        #expect(PromptOptimizer.cleanOutput("```markdown\nhello\nworld\n```\n") == "hello\nworld")
        #expect(PromptOptimizer.cleanOutput("<optimized_prompt>\nx\n</optimized_prompt>") == "x")
        #expect(PromptOptimizer.cleanOutput("  plain  ") == "plain")
        #expect(PromptOptimizer.cleanOutput("use ```code``` inline") == "use ```code``` inline")
    }

    @Test func userMessageIncludesClarifications() {
        let m = PromptOptimizer.userMessage(
            original: "fix it",
            answers: [ClarifyAnswer(questionID: "q1", question: "Which file?", answer: "main.swift"),
                      ClarifyAnswer(questionID: "q2", question: "Tests?", answer: "")])
        #expect(m.contains("<original_prompt>\nfix it\n</original_prompt>"))
        #expect(m.contains("Q: Which file?\nA: main.swift"))
        #expect(m.contains("A: (no answer; use best judgment)"))
        #expect(!PromptOptimizer.userMessage(original: "x", answers: []).contains("<clarifications>"))
    }

    @Test func clarifyQuestionsDecodeSnakeCaseAndClamp() throws {
        let json = #"{"questions":[{"id":"a","question":"A?","why":"w","suggested_answers":["1","2"]},{"id":"b","question":"B?","why":"","suggested_answers":[]},{"id":"c","question":"C?","why":"","suggested_answers":[]},{"id":"d","question":"D?","why":"","suggested_answers":[]}]}"#
        let q = try RequestCoding.decoder().decode(ClarifyQuestions.self, from: Data(json.utf8))
        #expect(q.questions.count == 4)
        #expect(q.questions[0].suggestedAnswers == ["1", "2"])
        #expect(q.clamped().questions.map(\.id) == ["a", "b", "c"])
    }

    @Test func modelCatalogCovers() {
        #expect(ModelCatalog.all.map(\.id) == ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5-1"])
        #expect(ModelCatalog.default.id == "claude-opus-5")
        #expect(ModelCatalog.infoOrGeneric(for: "claude-unknown").supportsEffort == false)
        let cost = ModelCatalog.opus5.cost(usage: Usage(inputTokens: 1_000_000, outputTokens: 1_000_000))
        #expect(cost == 30)
    }

    @Test func apiKeyProviderPrefersEnvironment() throws {
        #expect(try APIKeyProvider.resolve(environment: ["ANTHROPIC_API_KEY": " sk-x "]) == "sk-x")
        #expect(APIKeyProvider.redacted("sk-ant-api03-abcdefgh1234") == "sk-ant...1234")
    }
}
