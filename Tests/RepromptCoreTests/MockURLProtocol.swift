import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A `URLProtocol` that serves canned HTTP responses so `ClaudeClient`'s real request and
/// response path can be exercised without a network. Stubs are keyed by URL path, so each
/// test uses its own path and the suite can still run in parallel.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        /// Delivered in order. One element means a single `didLoad`.
        var chunks: [Data] = []
        /// Pause between chunks, used to exercise cancellation.
        var chunkDelay: TimeInterval = 0
        /// When set, the transport fails instead of responding.
        var transportError: (any Error)?
        /// True once `stopLoading` ran, i.e. the request was cancelled.
        var stopped = false
        /// Serve this many transient failures before the real response, to exercise retry.
        var transientFailures = 0
        var transientStatus = 503

        static func json(_ s: String, status: Int = 200) -> Stub {
            Stub(status: status, chunks: [Data(s.utf8)])
        }
        /// An SSE body split so each line arrives as its own chunk.
        static func sse(_ lines: [String], delay: TimeInterval = 0) -> Stub {
            Stub(headers: ["Content-Type": "text/event-stream"],
                 chunks: lines.map { Data(($0 + "\n").utf8) },
                 chunkDelay: delay)
        }
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [String: Stub] = [:]
        private var requests: [String: [URLRequest]] = [:]
        private var bodies: [String: [Data]] = [:]

        func set(_ stub: Stub, for path: String) {
            lock.lock(); defer { lock.unlock() }
            stubs[path] = stub
            requests[path] = []
            bodies[path] = []
        }
        /// Longest registered prefix wins, so a client that appends to the base URL still
        /// finds its stub.
        private func key(for path: String) -> String? {
            stubs.keys.filter { path.hasPrefix($0) }.max { $0.count < $1.count }
        }
        func stub(for path: String) -> Stub? {
            lock.lock(); defer { lock.unlock() }
            return key(for: path).flatMap { stubs[$0] }
        }
        /// A new request on a path is not the cancelled one that came before it.
        func beginRequest(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            if let k = key(for: path) { stubs[k]?.stopped = false }
        }
        /// Returns true when this request should be served a transient failure.
        func consumeTransientFailure(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let k = key(for: path), let n = stubs[k]?.transientFailures, n > 0 else { return false }
            stubs[k]?.transientFailures = n - 1
            return true
        }
        func markStopped(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            if let k = key(for: path) { stubs[k]?.stopped = true }
        }
        func wasStopped(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return key(for: path).flatMap { stubs[$0]?.stopped } ?? false
        }
        func record(_ request: URLRequest, body: Data, for path: String) {
            lock.lock(); defer { lock.unlock() }
            guard let k = key(for: path) else { return }
            requests[k, default: []].append(request)
            bodies[k, default: []].append(body)
        }
        func requests(for path: String) -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests[path] ?? []
        }
        func bodies(for path: String) -> [Data] {
            lock.lock(); defer { lock.unlock() }
            return bodies[path] ?? []
        }
    }

    private static let registry = Registry()

    // MARK: Test-facing API

    /// Registers `stub` at a fresh unique URL and returns that URL.
    static func install(_ stub: Stub, name: String = #function) -> URL {
        let path = "/" + name.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
            + "-" + UUID().uuidString
        registry.set(stub, for: path)
        return URL(string: "https://mock.invalid" + path)!
    }

    /// A `URLSession` wired to this protocol. Ephemeral so nothing is cached between tests.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }

    static func requests(for url: URL) -> [URLRequest] { registry.requests(for: url.path) }
    static func bodies(for url: URL) -> [Data] { registry.bodies(for: url.path) }
    static func wasCancelled(_ url: URL) -> Bool { registry.wasStopped(url.path) }

    /// The request body, which `URLSession` may have turned into a stream by the time a
    /// `URLProtocol` sees it.
    static func bodyJSON(for url: URL) throws -> [String: Any]? {
        guard let data = bodies(for: url).first else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return registry.stub(for: url.path) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.registry.stub(for: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.registry.beginRequest(url.path)
        Self.registry.record(request, body: Self.readBody(request), for: url.path)

        if Self.registry.consumeTransientFailure(url.path) {
            let r = HTTPURLResponse(url: url, statusCode: stub.transientStatus, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(
                #"{"error":{"code":503,"status":"UNAVAILABLE","message":"overloaded","type":"server_error"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if let error = stub.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let path = url.path
        let chunks = stub.chunks
        let delay = stub.chunkDelay
        // Delivered off the calling queue so a cancellation can interleave.
        DispatchQueue.global().async { [weak self] in
            for chunk in chunks {
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                guard let self, !Self.registry.wasStopped(path) else { return }
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            guard let self, !Self.registry.wasStopped(path) else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if let path = request.url?.path { Self.registry.markStopped(path) }
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Shared helpers

/// Runs `body` and returns the error it threw, or nil. Clearer than `#expect(throws:)` when
/// the test needs to assert the associated values of the error.
func errorFrom<T>(_ body: () async throws -> T) async -> (any Error)? {
    do { _ = try await body(); return nil } catch { return error }
}

/// Correctly quotes and escapes a string as a JSON string literal, including newlines.
func jsonQuoted(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    var out = String(data: data, encoding: .utf8)!
    out.removeFirst()
    out.removeLast()
    return out
}

/// A minimal well-formed SSE body for a successful text response.
func sseLines(model: String = "claude-opus-5", text: [String] = ["Hello"],
              stopReason: String = "end_turn", inputTokens: Int = 25, outputTokens: Int = 5,
              extraBlocks: [String] = [], includeStop: Bool = true) -> [String] {
    var lines: [String] = [
        #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"\#(model)","content":[],"stop_reason":null,"usage":{"input_tokens":\#(inputTokens),"output_tokens":1}}}"#,
    ]
    lines += extraBlocks
    lines.append(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
    for t in text {
        lines.append(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(jsonQuoted(t))}}"#)
    }
    lines.append(#"data: {"type":"content_block_stop","index":0}"#)
    lines.append(#"data: {"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"},"usage":{"output_tokens":\#(outputTokens)}}"#)
    if includeStop { lines.append(#"data: {"type":"message_stop"}"#) }
    return lines
}
