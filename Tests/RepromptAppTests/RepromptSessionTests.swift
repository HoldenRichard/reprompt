import Foundation
import Testing
@testable import Reprompt
@testable import RepromptCore

@Suite @MainActor struct RepromptSessionTests {
    func makeSession(mode: Mode = .quick,
                     url: URL,
                     reader: FakeReader = FakeReader(),
                     inserter: FakeInserter = FakeInserter()) -> (RepromptSession, AppSettings, () -> Void) {
        let (settings, cleanup) = scratchSettings()
        let session = RepromptSession(
            mode: mode, settings: settings, reader: reader, inserter: inserter,
            makeOptimizer: { config in stubOptimizer(url, config: config) })
        return (session, settings, cleanup)
    }

    // MARK: Quick mode

    @Test func quickModeRunsGrabThenStreamThenResult() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["A rewritten ", "prompt."])))
        let reader = FakeReader(text: "make it better")
        let (session, _, cleanup) = makeSession(url: url, reader: reader)
        defer { cleanup() }

        #expect(session.phase == .grabbing)
        session.start()
        #expect(await waitUntil { session.phase == .result })
        #expect(session.text == "A rewritten prompt.")
        #expect(reader.readCount == 1)
        #expect(session.selection?.text == "make it better")
        #expect(session.canAccept)
        #expect(!session.isBusy)
        #expect(session.ttfbMs != nil)
        #expect(session.totalMs != nil)
    }

    /// The overlay must not take key focus until the selection has been read, or the
    /// synthetic Cmd+C lands on Reprompt's own panel instead of the target app.
    @Test func keyboardFocusIsRequestedOnlyAfterTheGrab() async throws {
        let url = MockURLProtocol.install(.sse(sseLines()))
        let reader = FakeReader()
        reader.delay = .milliseconds(80)
        let (session, _, cleanup) = makeSession(url: url, reader: reader)
        defer { cleanup() }

        var readyAt: Int?
        var tick = 0
        session.onReadyForKeyboard = { readyAt = tick }

        session.start()
        // While the grab is still running the overlay must not have been made key.
        tick = 1
        #expect(readyAt == nil)
        #expect(await waitUntil { session.phase == .result })
        #expect(readyAt == 1, "focus was requested before the grab finished")
    }

    @Test func aFailedGrabSurfacesTheReadersError() async throws {
        let url = MockURLProtocol.install(.sse(sseLines()))
        let (session, _, cleanup) = makeSession(url: url, reader: FakeReader(error: SelectionError.noSelection))
        defer { cleanup() }
        session.start()
        #expect(await waitUntil { if case .failed = session.phase { true } else { false } })
        guard case .failed(let message, let missingKey) = session.phase else { Issue.record("wrong phase"); return }
        #expect(message.contains("Nothing is selected"))
        #expect(!missingKey)
        #expect(!session.canAccept)
    }

    @Test func aMissingAPIKeyIsFlaggedSoTheOverlayCanOfferSettings() async throws {
        let (settings, cleanup) = scratchSettings()
        defer { cleanup() }
        let session = RepromptSession(mode: .quick, settings: settings, reader: FakeReader(),
                                      inserter: FakeInserter(),
                                      makeOptimizer: { _ in throw ClaudeError.missingAPIKey })
        session.start()
        #expect(await waitUntil { if case .failed = session.phase { true } else { false } })
        guard case .failed(_, let missingKey) = session.phase else { Issue.record("wrong phase"); return }
        #expect(missingKey)
    }

    @Test func startIsIdempotentSoTheSelectionIsReadOnce() async throws {
        let url = MockURLProtocol.install(.sse(sseLines()))
        let reader = FakeReader()
        let (session, _, cleanup) = makeSession(url: url, reader: reader)
        defer { cleanup() }
        session.start()
        session.start()
        session.start()
        #expect(await waitUntil { session.phase == .result })
        #expect(reader.readCount == 1)
    }

    // MARK: Accept

    /// Regression: `accept()` mutated no state synchronously, so the Accept button and its
    /// Cmd+Return shortcut stayed live for the whole ~300 ms paste and the rewrite was
    /// inserted two or three times.
    @Test func acceptIsNotReEntrant() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["result text"])))
        let inserter = FakeInserter()
        inserter.delay = .milliseconds(150)
        let (session, _, cleanup) = makeSession(url: url, inserter: inserter)
        defer { cleanup() }
        session.start()
        #expect(await waitUntil { session.phase == .result })

        session.accept()
        session.accept()
        session.accept()
        #expect(session.phase == .accepting, "the phase must be claimed synchronously")
        #expect(!session.canAccept)
        #expect(session.isBusy)
        #expect(await waitUntil { inserter.calls.count > 0 })
        try await Task.sleep(for: .milliseconds(250))
        #expect(inserter.calls.count == 1, "pasted \(inserter.calls.count) times")
        #expect(inserter.calls.first?.text == "result text")
    }

    @Test func acceptPastesTheEditedTextWhenTheUserEditedIt() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["generated"])))
        let inserter = FakeInserter()
        let (session, _, cleanup) = makeSession(url: url, inserter: inserter)
        defer { cleanup() }
        session.start()
        #expect(await waitUntil { session.phase == .result })

        session.beginEdit()
        #expect(session.phase == .editing)
        #expect(session.editText == "generated")
        session.editText = "hand edited"
        session.accept()
        #expect(await waitUntil { inserter.calls.count == 1 })
        #expect(inserter.calls.first?.text == "hand edited")
    }

    /// Once Reprompt has taken focus for editing, the element captured at grab time may no
    /// longer be the one the user is in, so the write must go through the paste path.
    @Test func editingDisablesTheAccessibilityWriteBack() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["x"])))
        let inserter = FakeInserter()
        let (session, _, cleanup) = makeSession(url: url, inserter: inserter)
        defer { cleanup() }
        session.start()
        #expect(await waitUntil { session.phase == .result })

        session.accept()
        #expect(await waitUntil { inserter.calls.count == 1 })
        #expect(inserter.calls[0].preferAccessibility, "an untouched selection can be written directly")

        let url2 = MockURLProtocol.install(.sse(sseLines(text: ["y"])))
        let inserter2 = FakeInserter()
        let (session2, _, cleanup2) = makeSession(url: url2, inserter: inserter2)
        defer { cleanup2() }
        session2.start()
        #expect(await waitUntil { session2.phase == .result })
        session2.beginEdit()
        session2.accept()
        #expect(await waitUntil { inserter2.calls.count == 1 })
        #expect(!inserter2.calls[0].preferAccessibility, "after activation the captured element is stale")
    }

    /// Regression: the overlay panel holds keyboard focus while it is open, and a synthetic
    /// Cmd+V follows focus rather than activation. With the panel still key the paste landed
    /// on Reprompt itself, so Accept appeared to do nothing and the user had to paste by hand.
    @Test func focusIsHandedBackBeforeTheTextIsWritten() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["rewritten"])))
        let inserter = FakeInserter()
        let (session, _, cleanup) = makeSession(url: url, inserter: inserter)
        defer { cleanup() }
        var order: [String] = []
        session.onWillInsertText = { order.append("relinquish focus") }
        inserter.onReplace = { order.append("write text") }

        session.start()
        #expect(await waitUntil { session.phase == .result })
        session.accept()
        #expect(order.first == "relinquish focus", "focus must be given up before the paste")
        #expect(await waitUntil { order.count == 2 })
        #expect(order == ["relinquish focus", "write text"])
    }

    @Test func focusIsHandedBackOnlyOnceEvenIfAcceptIsPressedRepeatedly() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["x"])))
        let inserter = FakeInserter()
        inserter.delay = .milliseconds(120)
        let (session, _, cleanup) = makeSession(url: url, inserter: inserter)
        defer { cleanup() }
        var hides = 0
        session.onWillInsertText = { hides += 1 }
        session.start()
        #expect(await waitUntil { session.phase == .result })
        session.accept()
        session.accept()
        session.accept()
        #expect(hides == 1)
    }

    @Test func aFailedWriteAsksForTheOverlayBack() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["x"])))
        let inserter = FakeInserter()
        inserter.error = InsertError.cannotPostEvents
        let (session, _, cleanup) = makeSession(url: url, inserter: inserter)
        defer { cleanup() }
        var revealed = 0
        session.onInsertFailed = { revealed += 1 }
        session.start()
        #expect(await waitUntil { session.phase == .result })
        session.accept()
        #expect(await waitUntil { revealed == 1 }, "a hidden overlay must come back to show the error")
        if case .failed = session.phase {} else { Issue.record("expected .failed, got \(session.phase)") }
    }

    @Test func acceptDoesNothingBeforeThereIsAResult() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(), delay: 0.05))
        let inserter = FakeInserter()
        let (session, _, cleanup) = makeSession(url: url, inserter: inserter)
        defer { cleanup() }
        session.accept()
        #expect(inserter.calls.isEmpty)
        session.start()
        session.accept()
        #expect(inserter.calls.isEmpty, "accept must be inert while still streaming")
        #expect(await waitUntil { session.phase == .result })
    }

    @Test func aFailedPasteIsReportedRatherThanLookingLikeSuccess() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["x"])))
        let inserter = FakeInserter()
        inserter.error = InsertError.cannotPostEvents
        let (session, _, cleanup) = makeSession(url: url, inserter: inserter)
        defer { cleanup() }
        var finished = false
        session.onFinished = { finished = true }
        session.start()
        #expect(await waitUntil { session.phase == .result })
        session.accept()
        #expect(await waitUntil { if case .failed = session.phase { true } else { false } })
        #expect(!finished, "a failed paste must not close the overlay silently")
    }

    @Test func acceptClosesTheOverlayOnSuccess() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["x"])))
        let (session, _, cleanup) = makeSession(url: url)
        defer { cleanup() }
        var finishedCount = 0
        session.onFinished = { finishedCount += 1 }
        session.start()
        #expect(await waitUntil { session.phase == .result })
        session.accept()
        #expect(await waitUntil { finishedCount == 1 })
        try await Task.sleep(for: .milliseconds(80))
        #expect(finishedCount == 1, "onFinished fired \(finishedCount) times")
    }

    // MARK: Clarify

    @Test func clarifyModeShowsTheQuestionsAndSizesTheAnswers() async throws {
        let url = MockURLProtocol.install(questionsResponse(
            #"{"questions":[{"id":"a","question":"Who?","why":"tone","suggested_answers":["client"]},{"id":"b","question":"How long?","why":"","suggested_answers":[]}]}"#))
        let (session, _, cleanup) = makeSession(mode: .clarify, url: url)
        defer { cleanup() }
        var activated = 0
        session.onNeedsActivation = { activated += 1 }
        session.start()
        #expect(await waitUntil { session.phase == .questions })
        #expect(session.questions?.questions.count == 2)
        #expect(session.answers == ["", ""])
        #expect(session.canSubmitAnswers)
        #expect(activated == 1, "the panel must come forward for typing")
    }

    /// Regression: an empty question set left the user on a form with no fields and no
    /// submit control, able only to dismiss.
    @Test func clarifyWithNoQuestionsFallsThroughToAPlainRewrite() async throws {
        let url = MockURLProtocol.install(questionsResponse(#"{"questions":[]}"#))
        let (session, _, cleanup) = makeSession(mode: .clarify, url: url)
        defer { cleanup() }
        session.start()
        // The same stubbed URL serves the follow-up rewrite; it is a non-SSE body, so the
        // stream fails rather than hanging. Either way the user must not be left stranded.
        #expect(await waitUntil {
            session.phase != .grabbing && session.phase != .askingQuestions && session.phase != .questions
        })
        #expect(session.phase != .questions, "an empty form is a dead end")
        #expect(session.notice?.contains("No clarifying questions") == true)
    }

    /// Regression: the guard read `phase == .questions` but the phase only changed inside the
    /// Task, so holding Return in the last field started two streams writing one buffer.
    @Test func submitAnswersIsNotReEntrant() async throws {
        let url = MockURLProtocol.install(questionsResponse(
            #"{"questions":[{"id":"a","question":"Who?","why":"","suggested_answers":[]}]}"#))
        let (session, _, cleanup) = makeSession(mode: .clarify, url: url)
        defer { cleanup() }
        session.start()
        #expect(await waitUntil { session.phase == .questions })

        let before = MockURLProtocol.requests(for: url).count
        session.submitAnswers()
        session.submitAnswers()
        session.submitAnswers()
        #expect(session.phase == .streaming, "the phase must be claimed synchronously")
        #expect(!session.canSubmitAnswers)
        try await Task.sleep(for: .milliseconds(250))
        let issued = MockURLProtocol.requests(for: url).count - before
        #expect(issued == 1, "issued \(issued) rewrite requests")
    }

    @Test func submitAnswersIsInertOutsideTheQuestionsPhase() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["x"])))
        let (session, _, cleanup) = makeSession(url: url)
        defer { cleanup() }
        session.start()
        #expect(await waitUntil { session.phase == .result })
        let before = MockURLProtocol.requests(for: url).count
        session.submitAnswers()
        try await Task.sleep(for: .milliseconds(100))
        #expect(MockURLProtocol.requests(for: url).count == before)
        #expect(session.phase == .result)
    }

    // MARK: Dismiss

    @Test func dismissCancelsInFlightWorkAndClosesTheOverlay() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: (1...40).map { "c\($0) " }), delay: 0.02))
        let (session, _, cleanup) = makeSession(url: url)
        defer { cleanup() }
        var finished = 0
        session.onFinished = { finished += 1 }
        session.start()
        #expect(await waitUntil { session.phase == .streaming })
        session.dismiss()
        #expect(finished == 1)
        let textAtDismiss = session.text
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.phase != .result, "a dismissed session must not complete afterwards")
        #expect(session.text == textAtDismiss, "the cancelled stream kept writing")
    }

    @Test func copyingPutsTheResultOnTheClipboardAndSaysSo() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["copy me"])))
        let (session, _, cleanup) = makeSession(url: url)
        defer { cleanup() }
        session.start()
        #expect(await waitUntil { session.phase == .result })
        session.copyResult()
        #expect(session.notice == "Copied to clipboard.")
    }
}
