import AppKit
import Foundation
import RepromptCore

/// One hotkey invocation: grab -> (questions) -> stream -> result -> accept/dismiss.
@Observable
final class RepromptSession {
    enum Phase: Equatable {
        case grabbing
        case askingQuestions
        case questions
        case streaming
        case result
        case editing
        case failed(String, missingKey: Bool)
    }

    let mode: Mode
    let settings: AppSettings
    private(set) var phase: Phase = .grabbing
    private(set) var text = ""
    var editText = ""
    private(set) var selection: Selection?
    private(set) var questions: ClarifyQuestions?
    var answers: [String] = []
    private(set) var servedModel: String
    private(set) var ttfbMs: Double?
    private(set) var totalMs: Double?
    private(set) var notice: String?

    var onFinished: (() -> Void)?
    var onNeedsActivation: (() -> Void)?

    private var task: Task<Void, Never>?
    private let clock = ContinuousClock()

    init(mode: Mode, settings: AppSettings) {
        self.mode = mode
        self.settings = settings
        self.servedModel = settings.modelID
    }

    var isBusy: Bool { phase == .grabbing || phase == .askingQuestions || phase == .streaming }
    var canAccept: Bool { phase == .result || phase == .editing }
    var finalText: String { phase == .editing ? editText : text }

    // MARK: Flow

    func start() {
        task = Task { await run() }
    }

    private func run() async {
        do {
            let sel = try await SelectionReader().read()
            selection = sel
            try Task.checkCancellation()
            let optimizer = try makeOptimizer()
            if mode == .clarify {
                phase = .askingQuestions
                let q = try await optimizer.clarifyingQuestions(for: sel.text)
                questions = q.questions
                answers = Array(repeating: "", count: q.questions.questions.count)
                servedModel = q.servedModel
                phase = .questions
                onNeedsActivation?()
                return
            }
            try await stream(optimizer: optimizer, original: sel.text, answers: [])
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    func submitAnswers() {
        guard phase == .questions, let sel = selection, let qs = questions else { return }
        let clar = zip(qs.questions, answers).map { q, a in
            ClarifyAnswer(questionID: q.id, question: q.question, answer: a.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        task = Task {
            do {
                try await stream(optimizer: try makeOptimizer(), original: sel.text, answers: clar)
            } catch is CancellationError {
            } catch {
                fail(error)
            }
        }
    }

    private func stream(optimizer: PromptOptimizer, original: String, answers: [ClarifyAnswer]) async throws {
        phase = .streaming
        text = ""
        let start = clock.now
        var first: ContinuousClock.Instant?
        var stop: StopReason?
        for try await event in optimizer.optimizeStream(original, answers: answers) {
            try Task.checkCancellation()
            switch event {
            case .messageStart(let model, _): servedModel = model
            case .blockStart(_, let type, let to):
                if type == "fallback", let to { servedModel = to; notice = "Served by \(to) after a fallback." }
            case .textDelta(let t):
                if first == nil { first = clock.now; ttfbMs = ms(first! - start) }
                text += t
            case .messageDelta(let reason, _): stop = reason
            case .messageStop, .ping: break
            case .error(let e): throw e
            }
        }
        totalMs = ms(clock.now - start)
        if stop == .refusal { throw ClaudeError.refusal(category: nil, explanation: nil) }
        if stop == .maxTokens { notice = "Output was cut off at max tokens; raise it in Settings." }
        text = PromptOptimizer.cleanOutput(text)
        phase = .result
    }

    private func makeOptimizer() throws -> PromptOptimizer {
        let key = try APIKeyProvider.resolve()
        return PromptOptimizer(client: ClaudeClient(apiKey: key), config: settings.optimizerConfig, prompts: try PromptLibrary.loadAll())
    }

    private func fail(_ error: any Error) {
        let missing = (error as? ClaudeError) == .missingAPIKey
        phase = .failed("\(error)", missingKey: missing)
    }

    // MARK: Actions

    func beginEdit() {
        guard phase == .result else { return }
        editText = text
        phase = .editing
        onNeedsActivation?()
    }

    func accept() {
        guard canAccept, let sel = selection else { return }
        let out = finalText
        task = Task {
            do {
                try await TextInserter().replace(sel, with: out)
                onFinished?()
            } catch {
                phase = .failed("\(error)", missingKey: false)
            }
        }
    }

    func copyResult() {
        TextInserter.copyToClipboard(finalText)
        notice = "Copied to clipboard."
    }

    func dismiss() {
        task?.cancel()
        task = nil
        onFinished?()
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
