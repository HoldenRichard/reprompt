import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RepromptCore

/// Collects stream output from a cancellable task.
actor Collected {
    private(set) var events: [StreamEvent] = []
    private(set) var failure: (any Error)?
    func add(_ e: StreamEvent) { events.append(e) }
    func fail(_ e: any Error) { failure = e }
    var count: Int { events.count }
    var text: String {
        events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
    }
}

@Suite struct ClaudeClientSendTests {
    func client(_ url: URL, key: String = "sk-test-key") -> ClaudeClient {
        ClaudeClient(apiKey: key, baseURL: url, session: MockURLProtocol.session(), retry: .none)
    }

    var okResponse: String {
        #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":3}}"#
    }

    @Test func sendPutsTheRequestOnTheWireCorrectly() async throws {
        let url = MockURLProtocol.install(.json(okResponse))
        let req = RequestBuilder.build(
            model: "claude-opus-5", system: "SYS", user: "USER", maxTokens: 512, effort: .low,
            thinking: .adaptive, fastMode: true, useFallbacks: true, stream: true)
        _ = try await client(url).send(req)

        let sent = try #require(MockURLProtocol.requests(for: url).first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url == url)
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-test-key")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "anthropic-beta")
            == "server-side-fallback-2026-07-01,fast-mode-2026-02-01")

        let body = try #require(try MockURLProtocol.bodyJSON(for: url))
        // send() must force stream:false even though the caller built a streaming request.
        #expect(body["stream"] as? Bool == false)
        #expect(body["model"] as? String == "claude-opus-5")
        #expect(body["max_tokens"] as? Int == 512)
        #expect((body["messages"] as? [[String: Any]])?.first?["content"] as? String == "USER")
    }

    @Test func sendDecodesASuccessfulResponse() async throws {
        let url = MockURLProtocol.install(.json(okResponse))
        let r = try await client(url).send(MessageRequest(model: "m", maxTokens: 10, messages: [.user("x")]))
        #expect(r.text == "hi")
        #expect(r.stopReason == .endTurn)
        #expect(r.usage.inputTokens == 10)
        #expect(r.servedModel == "claude-opus-5")
    }

    @Test func sendOmitsTheBetaHeaderWhenNoBetaIsUsed() async throws {
        let url = MockURLProtocol.install(.json(okResponse))
        let req = RequestBuilder.build(
            model: "claude-haiku-4-5", system: nil, user: "u", maxTokens: 10, effort: .low,
            thinking: .adaptive, fastMode: true, useFallbacks: true, stream: false)
        _ = try await client(url).send(req)
        let sent = try #require(MockURLProtocol.requests(for: url).first)
        #expect(sent.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func apiErrorEnvelopeBecomesATypedError() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"type":"error","error":{"type":"invalid_request_error","message":"bad model"}}"#, status: 400))
        let err = await errorFrom { try await client(url).send(MessageRequest(model: "m", maxTokens: 1, messages: [.user("x")])) }
        #expect(err as? ClaudeError == .api(status: 400, type: "invalid_request_error", message: "bad model"))
    }

    @Test func nonJSONErrorBodyStillSurfacesTheStatus() async throws {
        let url = MockURLProtocol.install(Stub502())
        let err = await errorFrom { try await client(url).send(MessageRequest(model: "m", maxTokens: 1, messages: [.user("x")])) }
        guard case .api(let status, let type, let message)? = err as? ClaudeError else {
            Issue.record("expected .api, got \(String(describing: err))"); return
        }
        #expect(status == 502)
        #expect(type == "http")
        #expect(message.contains("gateway"))
    }
    private func Stub502() -> MockURLProtocol.Stub {
        MockURLProtocol.Stub(status: 502, headers: ["Content-Type": "text/html"],
                             chunks: [Data("<html>bad gateway</html>".utf8)])
    }

    @Test func malformedSuccessBodyBecomesADecodingError() async throws {
        let url = MockURLProtocol.install(.json(#"{"unexpected":true}"#))
        let err = await errorFrom { try await client(url).send(MessageRequest(model: "m", maxTokens: 1, messages: [.user("x")])) }
        guard case .decoding? = err as? ClaudeError else {
            Issue.record("expected .decoding, got \(String(describing: err))"); return
        }
    }

    @Test func transportFailureBecomesANetworkError() async throws {
        var stub = MockURLProtocol.Stub()
        stub.transportError = URLError(.notConnectedToInternet)
        let url = MockURLProtocol.install(stub)
        let err = await errorFrom { try await client(url).send(MessageRequest(model: "m", maxTokens: 1, messages: [.user("x")])) }
        // send() surfaces URLSession's own error rather than wrapping it.
        #expect(err != nil)
        #expect((err as? URLError)?.code == .notConnectedToInternet)
    }
}

@Suite struct ClaudeClientStreamTests {
    func client(_ url: URL) -> ClaudeClient {
        ClaudeClient(apiKey: "sk-test", baseURL: url, session: MockURLProtocol.session(), retry: .none)
    }
    var request: MessageRequest {
        MessageRequest(model: "claude-opus-5", maxTokens: 100, messages: [.user("x")], stream: false)
    }

    func drain(_ url: URL) async throws -> [StreamEvent] {
        var out: [StreamEvent] = []
        for try await e in client(url).stream(request) { out.append(e) }
        return out
    }

    @Test func streamForcesStreamTrueOnTheWire() async throws {
        let url = MockURLProtocol.install(.sse(sseLines()))
        _ = try await drain(url)
        let body = try #require(try MockURLProtocol.bodyJSON(for: url))
        #expect(body["stream"] as? Bool == true)
    }

    @Test func happyPathYieldsEventsInOrder() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["Hel", "lo ", "world"], outputTokens: 12)))
        let events = try await drain(url)
        #expect(events.first == .messageStart(model: "claude-opus-5", inputTokens: 25))
        #expect(events.contains(.blockStart(index: 0, type: "text", fallbackTo: nil)))
        #expect(events.contains(.messageDelta(stopReason: .endTurn, outputTokens: 12, inputTokens: 0)))
        #expect(events.last == .messageStop)
        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Hello world")
    }

    @Test func fallbackBlockIsSurfaced() async throws {
        let fallback = #"data: {"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-fable-5-1"},"to":{"model":"claude-opus-5"}}}"#
        let url = MockURLProtocol.install(.sse(sseLines(model: "claude-fable-5-1", extraBlocks: [fallback])))
        let events = try await drain(url)
        #expect(events.contains(.blockStart(index: 0, type: "fallback", fallbackTo: "claude-opus-5")))
    }

    @Test func midStreamErrorEventThrows() async throws {
        var lines = sseLines(text: ["partial"])
        lines.insert(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, at: 3)
        let url = MockURLProtocol.install(.sse(lines))
        let err = await errorFrom { try await drain(url) }
        #expect(err as? ClaudeError == .stream(type: "overloaded_error", message: "Overloaded"))
    }

    /// The defect this guards: a dropped connection used to look like a finished message,
    /// so the user could accept and paste a silently truncated prompt.
    @Test func streamEndingWithoutMessageStopIsAnError() async throws {
        let url = MockURLProtocol.install(.sse(sseLines(text: ["half a promp"], includeStop: false)))
        let err = await errorFrom { try await drain(url) }
        guard case .invalidResponse(let m)? = err as? ClaudeError else {
            Issue.record("expected .invalidResponse, got \(String(describing: err))"); return
        }
        #expect(m.contains("message_stop"))
    }

    @Test func nonSuccessStatusDuringStreamingSurfacesTheAPIError() async throws {
        let url = MockURLProtocol.install(.json(
            #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, status: 429))
        let err = await errorFrom { try await drain(url) }
        #expect(err as? ClaudeError == .api(status: 429, type: "rate_limit_error", message: "slow down"))
    }

    @Test func unparseableDataLineIsReportedRatherThanSilentlyDropped() async throws {
        let url = MockURLProtocol.install(.sse(["data: {not json", #"data: {"type":"message_stop"}"#]))
        let err = await errorFrom { try await drain(url) }
        guard case .decoding? = err as? ClaudeError else {
            Issue.record("expected .decoding, got \(String(describing: err))"); return
        }
    }

    #if canImport(Darwin)
    // Needs incremental delivery, which only Apple's streaming URLSession provides.
    @Test func cancellingTheConsumerStopsTheUnderlyingRequest() async throws {
        let many = (1...40).map { "chunk\($0) " }
        let url = MockURLProtocol.install(.sse(sseLines(text: many), delay: 0.02))
        let collected = Collected()
        let c = client(url)
        let req = request
        let task = Task {
            do {
                for try await e in c.stream(req) { await collected.add(e) }
            } catch { await collected.fail(error) }
        }
        // Wait for the stream to actually start, then cancel mid-flight.
        for _ in 0..<200 where await collected.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        _ = await task.value

        let seen = await collected.count
        #expect(seen > 0, "the stream should have started before cancellation")
        #expect(seen < many.count + 4, "cancellation should stop delivery early, saw \(seen)")
        // Give URLSession a moment to tear the request down.
        for _ in 0..<100 where !MockURLProtocol.wasCancelled(url) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(MockURLProtocol.wasCancelled(url), "the HTTP request should have been cancelled")
    }
    #endif
}
