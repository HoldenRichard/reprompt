import ArgumentParser
import Foundation
import RepromptCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "For each prompt x model: optimize, answer both versions, judge blind, and score.")

    @Option(name: .long, help: "Prompt corpus directory.", completion: .directory) var prompts: String = "prompts/curated"
    @Option(name: .long, help: "Comma-separated optimizer model IDs. Defaults to the provider's default.")
    var models: String?
    @Option(name: .long, help: "Runs root; a timestamped directory is created inside.", completion: .directory) var out: String = "runs"
    @Option(name: .long, help: "Random stratified sample of N prompts.") var sample: Int?
    @Option(name: .long, help: "First N prompts.") var limit: Int?
    @Option(name: .long, help: "Only this category.") var category: String?
    @Flag(name: .long, help: "Run the blind pairwise judge.") var judge = false
    @Flag(name: .long, help: "Judge both A/B orders; disagreement counts as a tie.") var bothOrders = false
    @Option(name: .long) var judgeModel: String = ModelCatalog.defaultModel(for: OptimizerConfig.default.provider).id
    @Option(name: .long) var concurrency: Int = 3
    @Option(name: .long, help: "max_tokens for the two answer calls.") var answerMaxTokens: Int = 3000
    @Flag(name: .long, help: "Exercise the Clarify path unattended (questions recorded, no answers).") var clarify = false
    @Option(name: .long) var seed: UInt64 = 42
    @OptionGroup var common: CommonModelOptions

    mutating func run() async throws {
        let modelIDs = (models ?? common.resolvedModel)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var corpus = try PromptCorpus.load(directory: URL(fileURLWithPath: prompts))
        if let category { corpus = corpus.filter { $0.category == category } }
        var rng = SplitMix64(seed: seed)
        if let sample, sample < corpus.count { corpus = Self.stratifiedSample(corpus, n: sample, rng: &rng) }
        if let limit { corpus = Array(corpus.prefix(limit)) }
        guard !corpus.isEmpty else { throw ValidationError("No prompts found in \(prompts)") }

        let client = try common.client()
        let promptSet = try common.prompts()
        let runDir = try RunWriter.newRunDirectory(under: URL(fileURLWithPath: out))
        let record = RunRecord(
            startedAt: ISO8601DateFormatter().string(from: Date()),
            arguments: Array(CommandLine.arguments.dropFirst()),
            models: modelIDs, config: common.config(), judgeModel: judge ? judgeModel : nil, bothOrders: bothOrders,
            promptHashes: Dictionary(uniqueKeysWithValues: promptSet.all.map { ($0.name.rawValue, $0.sha256) }),
            gitRevision: RunWriter.gitRevision(), promptCount: corpus.count)
        try RunWriter.writeRunRecord(record, prompts: promptSet, to: runDir)
        eprint("run \(runDir.path): \(corpus.count) prompts x \(modelIDs.count) models, optimizer prompt \(promptSet.optimizer.shortHash)")

        // Pre-draw judge orders so results are reproducible regardless of completion order.
        var jobs: [(CorpusPrompt, String, Bool)] = []
        for p in corpus { for m in modelIDs { jobs.append((p, m, Bool.random(using: &rng))) } }

        let judgeRunner = judge ? PairwiseJudge(client: client, prompt: promptSet.judge, model: judgeModel) : nil
        let common = self.common, answerMax = answerMaxTokens, doClarify = clarify, both = bothOrders
        var results: [CaseResult] = []
        var done = 0
        try await withThrowingTaskGroup(of: CaseResult.self) { group in
            var it = jobs.makeIterator()
            func addNext(_ group: inout ThrowingTaskGroup<CaseResult, any Error>) -> Bool {
                guard let (p, m, optFirst) = it.next() else { return false }
                group.addTask {
                    await Self.runCase(
                        prompt: p, model: m, optimizedFirst: optFirst, client: client, promptSet: promptSet,
                        common: common, answerMaxTokens: answerMax, clarify: doClarify, judge: judgeRunner, bothOrders: both)
                }
                return true
            }
            for _ in 0..<max(1, concurrency) { if !addNext(&group) { break } }
            while let r = try await group.next() {
                done += 1
                try RunWriter.write(r, in: runDir)
                let status = r.error.map { "ERROR \($0.prefix(80))" } ?? "\(r.outcome)  opt \(Int(r.optimize?.totalMs ?? 0)) ms"
                eprint("[\(done)/\(jobs.count)] \(r.promptID) \(r.model): \(status)")
                results.append(r)
                _ = addNext(&group)
            }
        }
        try Scoreboard.write(results, runDir: runDir, judgeModel: judge ? judgeModel : nil)
        eprint("wrote \(runDir.path)/scoreboard.md")
    }

    static func runCase(
        prompt: CorpusPrompt, model: String, optimizedFirst: Bool, client: any LLMClient, promptSet: PromptSet,
        common: CommonModelOptions, answerMaxTokens: Int, clarify: Bool, judge: PairwiseJudge?, bothOrders: Bool
    ) async -> CaseResult {
        var c = CaseResult(promptID: prompt.id, category: prompt.category, project: prompt.project, model: model, original: prompt.text)
        let optimizer = PromptOptimizer(client: client, config: common.config(model: model), prompts: promptSet)
        c.optimizerPromptHash = promptSet.optimizer.sha256
        do {
            var answers: [ClarifyAnswer] = []
            if clarify {
                let q = try await optimizer.clarifyingQuestions(for: prompt.text)
                c.clarify = .init(questions: q.questions, totalMs: ms(q.total), inputTokens: q.usage.inputTokens, outputTokens: q.usage.outputTokens)
                answers = q.questions.questions.map { ClarifyAnswer(questionID: $0.id, question: $0.question, answer: "") }
                c.optimizerPromptHash = promptSet.clarifyFinal.sha256
            }
            let o = try await optimizer.optimize(prompt.text, answers: answers)
            c.optimize = .init(text: o.text, servedModel: o.servedModel, ttfbMs: ms(o.ttfb), totalMs: ms(o.total),
                               inputTokens: o.usage.inputTokens, outputTokens: o.usage.outputTokens, stopReason: o.stopReason?.rawValue)

            async let a1 = Self.answer(client: client, model: model, text: prompt.text, maxTokens: answerMaxTokens)
            async let a2 = Self.answer(client: client, model: model, text: o.text, maxTokens: answerMaxTokens)
            c.answerOriginal = try await a1
            c.answerOptimized = try await a2

            if let judge {
                c.verdicts.append(try await judge.verdict(
                    originalRequest: prompt.text, answerOriginal: c.answerOriginal!.text,
                    answerOptimized: c.answerOptimized!.text, optimizedFirst: optimizedFirst))
                if bothOrders {
                    c.verdicts.append(try await judge.verdict(
                        originalRequest: prompt.text, answerOriginal: c.answerOriginal!.text,
                        answerOptimized: c.answerOptimized!.text, optimizedFirst: !optimizedFirst))
                }
                c.settle()
            }
        } catch {
            c.error = "\(error)"
        }
        return c
    }

    static func answer(client: any LLMClient, model: String, text: String, maxTokens: Int) async throws -> CaseResult.Call {
        let req = ChatRequest(
            model: model, system: nil, user: text, maxTokens: maxTokens, stream: false,
            effort: .medium, thinking: .adaptive)
        let clock = ContinuousClock()
        let start = clock.now
        let r = try await client.send(req)
        let total = clock.now - start
        if r.stopReason == .refusal {
            throw ClaudeError.refusal(category: r.stopDetails?.category, explanation: r.stopDetails?.explanation)
        }
        return .init(text: r.text, servedModel: r.servedModel, ttfbMs: nil, totalMs: ms(total),
                     inputTokens: r.usage.inputTokens, outputTokens: r.usage.outputTokens, stopReason: r.stopReason?.rawValue)
    }

    /// Round-robin across categories so a small sample still spans them.
    static func stratifiedSample(_ prompts: [CorpusPrompt], n: Int, rng: inout SplitMix64) -> [CorpusPrompt] {
        var buckets: [String: [CorpusPrompt]] = [:]
        for p in prompts { buckets[p.category, default: []].append(p) }
        var queues = buckets.keys.sorted().map { buckets[$0]!.shuffled(using: &rng) }
        var out: [CorpusPrompt] = []
        while out.count < n, queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where !queues[i].isEmpty && out.count < n { out.append(queues[i].removeFirst()) }
        }
        return out.sorted { $0.id < $1.id }
    }
}
