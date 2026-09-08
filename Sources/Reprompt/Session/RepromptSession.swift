import AppKit
import Foundation
import RepromptCore

/// One hotkey invocation: grab -> (questions) -> stream -> result -> accept or dismiss.
///
/// Every phase transition that guards an action is made SYNCHRONOUSLY, before the async work
/// starts. Setting the phase inside the Task instead left a window in which the guard still
/// passed, so a second Accept pasted the rewrite twice and a second submit ran two streams
/// that interleaved into the same buffer.
@Observable
final class RepromptSession {
    enum Phase: Equatable {
        case grabbing
        case askingQuestions
        case questions
        case streaming
        case result
        case editing
        case accepting
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

    /// Called when the session is finished with the overlay.
    var onFinished: (() -> Void)?
    /// Called once the selection has been read, so the overlay can safely take key focus.
    var onReadyForKeyboard: (() -> Void)?
    /// Called when Reprompt itself must come forward for text entry.
    var onNeedsActivation: (() -> Void)?

    private let reader: any SelectionReading
    private let inserter: any TextInserting
    private let makeOptimizer: (OptimizerConfig) throws -> PromptOptimizer
    private var task: Task<Void, Never>?
    /// True once Reprompt took focus, which makes the captured element unreliable.
    private var didActivate = false
    private let clock = ContinuousClock()

    init(mode: Mode,
         settings: AppSettings,
         reader: any SelectionReading = SelectionReader(),
         inserter: any TextInserting = TextInserter(),
         makeOptimizer: ((OptimizerConfig) throws -> PromptOptimizer)? = nil) {
        self.mode = mode
        self.settings = settings
        self.servedModel = settings.modelID
        self.reader = reader
        self.inserter = inserter
        self.makeOptimizer = makeOptimizer ?? { config in
            PromptOptimizer(client: ClaudeClient(apiKey: try APIKeyProvider.resolve()),
                            config: config, prompts: try PromptLibrary.loadAll())
        }
    }

    var isBusy: Bool {
        switch phase {
        case .grabbing, .askingQuestions, .streaming, .accepting: true
        default: false
        }
    }
    var canAccept: Bool { phase == .result || phase == .editing }
    var canSubmitAnswers: Bool { phase == .questions }
    var finalText: String { phase == .editing ? editText : text }

    // MARK: Flow

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    private func run() async {
        do {
            let sel = try await reader.read()
            selection = sel
            try Task.checkCancellation()
            // The overlay only takes key focus now: doing it before the grab would have
            // routed the synthetic Cmd+C to Reprompt's own panel instead of the target app.
            onReadyForKeyboard?()
            let optimizer = try makeOptimizer(settings.optimizerConfig)
            if mode == .clarify {
                phase = .askingQuestions
                let result = try await optimizer.clarifyingQuestions(for: sel.text)
                servedModel = result.servedModel
                try Task.checkCancellation()
                if result.questions.isEmpty {
                    // Nothing to ask. Falling through to a plain rewrite beats showing an
                    // empty form the user cannot submit.
                    notice = "No clarifying questions were needed."
                    try await stream(optimizer: optimizer, original: sel.text, answers: [])
                    return
                }
                questions = result.questions
                answers = Array(repeating: "", count: result.questions.questions.count)
                phase = .questions
                onNeedsActivation?()
                didActivate = true
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
        let clarifications = zip(qs.questions, answers).map { q, a in
            ClarifyAnswer(questionID: q.id, question: q.question,
                          answer: a.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        phase = .streaming
        task?.cancel()
        task = Task {
            do {
                try await stream(optimizer: try makeOptimizer(settings.optimizerConfig),
                                 original: sel.text, answers: clarifications)
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
                if first == nil { first = clock.now; ttfbMs = Self.ms(first! - start) }
                text += t
            case .messageDelta(let reason, _): stop = reason
            case .messageStop, .ping: break
            case .error(let e): throw e
            }
        }
        // A cancelled stream ends the loop without throwing, so check before committing a
        // result: otherwise Escape mid-stream shows partial text as a finished rewrite.
        try Task.checkCancellation()
        totalMs = Self.ms(clock.now - start)
        if stop == .refusal { throw ClaudeError.refusal(category: nil, explanation: nil) }
        if stop == .maxTokens { notice = "Output was cut off at max tokens; raise the limit in Settings." }
        text = PromptOptimizer.cleanOutput(text)
        phase = .result
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
        didActivate = true
    }

    func accept() {
        guard canAccept, let sel = selection else { return }
        let out = finalText
        guard !out.isEmpty else {
            notice = "Nothing to paste."
            return
        }
        // Claim the phase before any await, so a second Accept cannot start a second paste.
        phase = .accepting
        task?.cancel()
        task = Task {
            do {
                try await inserter.replace(sel, with: out, preferAccessibility: !didActivate)
                onFinished?()
            } catch is CancellationError {
                onFinished?()
            } catch {
                fail(error)
            }
        }
    }

    func copyResult() {
        guard !finalText.isEmpty else { return }
        TextInserter.copyToClipboard(finalText)
        notice = "Copied to clipboard."
    }

    func dismiss() {
        task?.cancel()
        task = nil
        onFinished?()
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
