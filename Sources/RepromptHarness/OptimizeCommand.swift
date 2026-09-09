import ArgumentParser
import Foundation
import RepromptCore

struct OptimizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "optimize", abstract: "Optimize one prompt and print it with timing and usage.")

    @Argument(help: "The prompt text. Use '-' to read stdin.") var text: String
    @OptionGroup var common: CommonModelOptions
    @Flag(name: .long, help: "Clarify mode: ask questions first, read answers from stdin.") var clarify = false

    mutating func run() async throws {
        let original = text == "-" ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? "" : text
        let optimizer = PromptOptimizer(client: try common.client(), config: common.config(), prompts: try common.prompts())
        eprint("model \(optimizer.config.model)  optimizer prompt \(optimizer.prompts.optimizer.shortHash)")

        var answers: [ClarifyAnswer] = []
        if clarify {
            let q = try await optimizer.clarifyingQuestions(for: original)
            eprint("questions in \(fmtMs(q.total)) (served by \(q.servedModel), \(q.usage.inputTokens)/\(q.usage.outputTokens) tokens)")
            for question in q.questions.questions {
                print("\n\(question.question)")
                if !question.why.isEmpty { print("   (\(question.why))") }
                if !question.suggestedAnswers.isEmpty { print("   options: " + question.suggestedAnswers.joined(separator: " | ")) }
                print("> ", terminator: "")
                let a = readLine() ?? ""
                answers.append(ClarifyAnswer(questionID: question.id, question: question.question, answer: a))
            }
            print("")
        }

        let clock = ContinuousClock()
        let start = clock.now
        var first: ContinuousClock.Instant? = nil
        var served = optimizer.config.model
        var out = ""
        var stop: StopReason? = nil
        var outputTokens = 0
        var inputTokens = 0
        for try await event in optimizer.optimizeStream(original, answers: answers) {
            switch event {
            case .messageStart(let m, let input): served = m; inputTokens = input
            case .blockStart(_, let type, let to):
                if type == "fallback", let to { served = to; eprint("[fallback -> \(to)]") }
            case .textDelta(let t):
                if first == nil { first = clock.now }
                out += t
                FileHandle.standardOutput.write(Data(t.utf8))
            case .messageDelta(let reason, let n, let input):
                stop = reason
                outputTokens = n
                if input > 0 { inputTokens = input }
            case .messageStop, .ping: break
            case .error(let e): throw e
            }
        }
        let end = clock.now
        print("")
        eprint("served \(served)  stop \(stop?.rawValue ?? "?")  ttfb \(fmtMs((first ?? end) - start))  total \(fmtMs(end - start))  tokens \(inputTokens)/\(outputTokens)  chars \(original.count) -> \(PromptOptimizer.cleanOutput(out).count)")
    }
}
