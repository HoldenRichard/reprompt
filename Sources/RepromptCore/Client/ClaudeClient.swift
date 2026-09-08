import Foundation

/// Raw-HTTPS client for `POST /v1/messages`. No SDK exists for Swift.
public struct ClaudeClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"

    public let apiKey: String
    public let baseURL: URL
    private let session: URLSession

    public init(apiKey: String, baseURL: URL = ClaudeClient.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public func urlRequest(for request: MessageRequest) throws -> URLRequest {
        var r = URLRequest(url: baseURL)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let betas = request.betaHeaders
        if !betas.isEmpty { r.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        r.httpBody = try RequestCoding.encoder().encode(request)
        r.timeoutInterval = 600
        return r
    }

    /// Non-streaming request. Forces `stream = false`.
    public func send(_ request: MessageRequest) async throws -> MessageResponse {
        var req = request
        req.stream = false
        let (data, response) = try await session.data(for: try urlRequest(for: req))
        try Self.check(response: response, body: data)
        do {
            return try RequestCoding.decoder().decode(MessageResponse.self, from: data)
        } catch {
            throw ClaudeError.decoding("\(error)")
        }
    }

    /// Streaming request. Forces `stream = true`. Cancelling the consuming task cancels the request.
    public func stream(_ request: MessageRequest) -> AsyncThrowingStream<StreamEvent, any Error> {
        var req = request
        req.stream = true
        let session = self.session
        let urlReq: URLRequest
        do { urlReq = try urlRequest(for: req) } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlReq)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        try Self.check(response: response, body: body)
                    }
                    var parser = SSEParser()
                    var sawStop = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = parser.feed(line) {
                            continuation.yield(event)
                            if case .messageStop = event { sawStop = true; break }
                            if case .error(let e) = event { throw e }
                        }
                    }
                    // A stream that just stops is a dropped connection, not a finished
                    // message. Reporting success here would hand the user a silently
                    // truncated prompt.
                    guard sawStop else {
                        throw ClaudeError.invalidResponse("stream ended without message_stop")
                    }
                    continuation.finish()
                } catch let e as ClaudeError {
                    continuation.finish(throwing: e)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ClaudeError.network("\(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func check(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(APIErrorEnvelope.self, from: body) {
                throw ClaudeError.api(status: http.statusCode, type: env.error.type, message: env.error.message)
            }
            let text = String(data: body.prefix(500), encoding: .utf8) ?? ""
            throw ClaudeError.api(status: http.statusCode, type: "http", message: text)
        }
    }
}
