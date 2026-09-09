import Foundation
import Testing
@testable import RepromptCore

@Suite struct RetryPolicyTests {
    /// Retrying a 400 or a refusal just burns the user's credit on the same failure.
    @Test func onlyTransientFailuresAreRetryable() {
        let p = RetryPolicy.default
        for status in [408, 409, 500, 502, 503, 529] {
            #expect(p.isRetryable(ClaudeError.api(status: status, type: "t", message: "m")), "\(status)")
        }
        // Retrying a quota error spends more of the quota that is already exhausted.
        #expect(!p.isRetryable(ClaudeError.api(status: 429, type: "RESOURCE_EXHAUSTED", message: "quota")))
        var eager = RetryPolicy.default
        eager.retryRateLimits = true
        #expect(eager.isRetryable(ClaudeError.api(status: 429, type: "t", message: "m")))
        for status in [400, 401, 403, 404, 413, 422] {
            #expect(!p.isRetryable(ClaudeError.api(status: status, type: "t", message: "m")), "\(status)")
        }
        #expect(p.isRetryable(ClaudeError.network("dropped")))
        #expect(!p.isRetryable(ClaudeError.refusal(category: nil, explanation: nil)))
        #expect(!p.isRetryable(ClaudeError.decoding("bad")))
        #expect(!p.isRetryable(ClaudeError.missingAPIKey))
        #expect(!p.isRetryable(ClaudeError.truncated(partial: "x")))
        #expect(!p.isRetryable(CancellationError()))
    }

    @Test func backoffGrowsWithEachAttempt() {
        let p = RetryPolicy(maxAttempts: 4, initialDelay: .milliseconds(100), multiplier: 2)
        #expect(p.delay(beforeAttempt: 1) == .milliseconds(100))
        #expect(p.delay(beforeAttempt: 2) == .milliseconds(200))
        #expect(p.delay(beforeAttempt: 3) == .milliseconds(400))
    }

    @Test func succeedsAfterTransientFailures() async throws {
        let attempts = Counter()
        let value = try await HTTPRetry.run(RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1))) {
            let n = await attempts.next()
            if n < 3 { throw ClaudeError.api(status: 503, type: "UNAVAILABLE", message: "busy") }
            return "ok"
        }
        #expect(value == "ok")
        #expect(await attempts.count == 3)
    }

    @Test func givesUpAfterTheAttemptBudget() async {
        let attempts = Counter()
        let err = await errorFrom {
            try await HTTPRetry.run(RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1))) {
                _ = await attempts.next()
                throw ClaudeError.api(status: 503, type: "UNAVAILABLE", message: "busy")
            }
        }
        #expect(err as? ClaudeError == .api(status: 503, type: "UNAVAILABLE", message: "busy"))
        #expect(await attempts.count == 2, "must not retry past the budget")
    }

    @Test func aNonRetryableFailureIsNotRepeated() async {
        let attempts = Counter()
        _ = await errorFrom {
            try await HTTPRetry.run(RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(1))) {
                _ = await attempts.next()
                throw ClaudeError.api(status: 400, type: "invalid_request_error", message: "bad")
            }
        }
        #expect(await attempts.count == 1, "a 400 will fail identically every time")
    }

    @Test func cancellationIsNeverRetried() async {
        let attempts = Counter()
        _ = await errorFrom {
            try await HTTPRetry.run(RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(1))) {
                _ = await attempts.next()
                throw CancellationError()
            }
        }
        #expect(await attempts.count == 1)
    }
}

actor Counter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

@Suite struct ClientRetryTests {
    func geminiOK() -> String {
        #"{"candidates":[{"content":{"parts":[{"text":"recovered"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2},"modelVersion":"gemini-3.8-flash"}"#
    }

    /// The real behaviour this exists for: Gemini returned 503 on two of our first three
    /// live calls, and a hotkey that surfaces that to the user is not usable.
    @Test func aBusyModelIsRetriedRatherThanSurfaced() async throws {
        var stub = MockURLProtocol.Stub.json(geminiOK())
        stub.transientFailures = 2
        let url = MockURLProtocol.install(stub)
        let client = GeminiClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(),
                                  retry: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1)))
        let r = try await client.send(ChatRequest(model: "gemini-3.8-flash", user: "u", maxTokens: 10))
        #expect(r.text == "recovered")
        #expect(MockURLProtocol.requests(for: url).count == 3, "two failures then a success")
    }

    @Test func exhaustingRetriesSurfacesTheLastError() async throws {
        var stub = MockURLProtocol.Stub.json(geminiOK())
        stub.transientFailures = 5
        let url = MockURLProtocol.install(stub)
        let client = GeminiClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(),
                                  retry: RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1)))
        let err = await errorFrom { try await client.send(ChatRequest(model: "m", user: "u", maxTokens: 10)) }
        guard case .api(let status, _, _)? = err as? ClaudeError else {
            Issue.record("expected .api, got \(String(describing: err))"); return
        }
        #expect(status == 503)
        #expect(MockURLProtocol.requests(for: url).count == 2)
    }

    @Test func streamingRetriesTheConnectAndEmitsTheAnswerOnlyOnce() async throws {
        var stub = MockURLProtocol.Stub.sse(geminiSSE(text: ["one ", "two"]))
        stub.transientFailures = 1
        let url = MockURLProtocol.install(stub)
        let client = GeminiClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(),
                                  retry: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1)))
        var events: [StreamEvent] = []
        for try await e in client.stream(ChatRequest(model: "m", user: "u", maxTokens: 10, stream: true)) {
            events.append(e)
        }
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "one two", "a retried stream must not replay its opening tokens")
        #expect(events.filter { if case .messageStart = $0 { true } else { false } }.count == 1)
        #expect(MockURLProtocol.requests(for: url).count == 2)
    }

    @Test func everyClientCarriesTheRetryPolicy() {
        #expect(ClaudeClient(apiKey: "k").retry == .default)
        #expect(GeminiClient(apiKey: "k").retry == .default)
        #expect(GroqClient(apiKey: "k").retry == .default)
        #expect(RetryPolicy.none.maxAttempts == 1)
    }
}

@Suite struct RateLimitRetryTests {
    /// Observed live against Gemini's free tier: a five-per-minute limit met three retries,
    /// which turned one refusal into a longer lockout. A quota error must surface at once.
    @Test func aQuotaErrorIsSurfacedImmediatelyRatherThanHammered() async throws {
        var stub = MockURLProtocol.Stub.json(
            #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded"}}"#, status: 429)
        stub.chunks = [Data(#"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded"}}"#.utf8)]
        let url = MockURLProtocol.install(stub)
        let client = GeminiClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(),
                                  retry: RetryPolicy(maxAttempts: 4, initialDelay: .milliseconds(1)))
        let err = await errorFrom { try await client.send(ChatRequest(model: "m", user: "u", maxTokens: 10)) }
        guard case .api(let status, _, _)? = err as? ClaudeError else {
            Issue.record("expected .api, got \(String(describing: err))"); return
        }
        #expect(status == 429)
        #expect(MockURLProtocol.requests(for: url).count == 1, "a quota error must not be retried")
    }

    @Test func aBusyModelIsStillRetried() async throws {
        var stub = MockURLProtocol.Stub.json(
            #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}],"modelVersion":"m"}"#)
        stub.transientFailures = 1
        let url = MockURLProtocol.install(stub)
        let client = GeminiClient(apiKey: "k", baseURL: url, session: MockURLProtocol.session(),
                                  retry: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1)))
        #expect(try await client.send(ChatRequest(model: "m", user: "u", maxTokens: 10)).text == "ok")
        #expect(MockURLProtocol.requests(for: url).count == 2)
    }
}
