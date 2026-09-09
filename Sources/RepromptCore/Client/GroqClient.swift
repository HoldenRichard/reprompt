import Foundation

/// Groq exposes an OpenAI-compatible chat-completions endpoint, so this speaks that wire
/// format rather than Anthropic's. Free tier, no per-token charge, and Groq's stated policy
/// is that it does not train on inputs and does not retain them by default.
public struct GroqClient: LLMClient, Sendable {
    public static let defaultBaseURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    public let provider: Provider = .groq
    public let apiKey: String
    public let baseURL: URL
    private let session: URLSession
    public var retry: RetryPolicy

    public init(apiKey: String, baseURL: URL = GroqClient.defaultBaseURL, session: URLSession = .shared, retry: RetryPolicy = .default) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.retry = retry
    }

    // MARK: Wire format

    struct Body: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        struct ResponseFormat: Encodable {
            struct Schema: Encodable {
                let name: String
                let schema: JSONValue
                let strict: Bool
            }
            let type = "json_schema"
            let json_schema: Schema
        }
        let model: String
        let messages: [Msg]
        let max_completion_tokens: Int
        let stream: Bool
        let response_format: ResponseFormat?
        /// Groq exposes reasoning depth on its reasoning models under this name.
        let reasoning_effort: String?
    }

    /// Groq's effort vocabulary is narrower than Anthropic's; anything above `high` clamps.
    static func reasoningEffort(for effort: Effort?, model: String) -> String? {
        guard ModelCatalog.infoOrGeneric(for: model).supportsEffort, let effort else { return nil }
        switch effort {
        case .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh, .max: return "high"
        }
    }

    func body(for request: ChatRequest) -> Body {
        var messages: [Body.Msg] = []
        if let system = request.system, !system.isEmpty {
            messages.append(.init(role: "system", content: system))
        }
        messages.append(.init(role: "user", content: request.user))
        let format = request.jsonSchema.map {
            Body.ResponseFormat(json_schema: .init(name: "response", schema: $0, strict: true))
        }
        return Body(model: request.model, messages: messages,
                    max_completion_tokens: request.maxTokens, stream: request.stream,
                    response_format: format,
                    reasoning_effort: Self.reasoningEffort(for: request.effort, model: request.model))
    }

    public func urlRequest(for request: ChatRequest) throws -> URLRequest {
        var r = URLRequest(url: baseURL)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        r.httpBody = try encoder.encode(body(for: request))
        r.timeoutInterval = 600
        return r
    }

    // MARK: Responses

    struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let finish_reason: String?
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
        }
        let model: String?
        let choices: [Choice]
        let usage: Usage?
    }

    /// OpenAI-style finish reasons mapped onto the shared vocabulary.
    static func stopReason(_ raw: String?) -> StopReason? {
        switch raw {
        case "stop": .endTurn
        case "length": .maxTokens
        case "content_filter": .refusal
        case "tool_calls", "function_call": .toolUse
        case nil: nil
        case .some(let other): .unknown(other)
        }
    }

    public func send(_ request: ChatRequest) async throws -> ChatResponse {
        var req = request
        req.stream = false
        let urlReq = try urlRequest(for: req)
        let data = try await HTTPRetry.run(retry) {
            let (data, response) = try await session.data(for: urlReq)
            try Self.check(response: response, body: data)
            return data
        }
        do {
            let c = try JSONDecoder().decode(Completion.self, from: data)
            let choice = c.choices.first
            return ChatResponse(
                text: choice?.message?.content ?? "",
                servedModel: c.model ?? request.model,
                usage: Usage(inputTokens: c.usage?.prompt_tokens ?? 0,
                             outputTokens: c.usage?.completion_tokens ?? 0),
                stopReason: Self.stopReason(choice?.finish_reason))
        } catch {
            throw ClaudeError.decoding("\(error)")
        }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, any Error> {
        var req = request
        req.stream = true
        let session = self.session
        let retry = self.retry
        let model = request.model
        let urlReq: URLRequest
        do { urlReq = try urlRequest(for: req) } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Retries cover the connect only: retrying after the first token
                    // would emit the beginning of the answer twice.
                    let bytes = try await HTTPRetry.connect(
                        session: session, request: urlReq, policy: retry, check: Self.check)
                    var parser = OpenAISSEParser(requestedModel: model)
                    var sawDone = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in parser.feed(line) {
                            continuation.yield(event)
                            if case .messageStop = event { sawDone = true }
                            if case .error(let e) = event { throw e }
                        }
                        if sawDone { break }
                    }
                    // As with Anthropic, a stream that merely stops is a dropped connection
                    // and must not be reported as a finished message.
                    guard sawDone else {
                        throw ClaudeError.invalidResponse("stream ended without a completion marker")
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

    struct ErrorEnvelope: Decodable {
        struct Inner: Decodable { let type: String?; let message: String?; let code: String? }
        let error: Inner
    }

    static func check(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
                throw ClaudeError.api(status: http.statusCode,
                                      type: env.error.type ?? env.error.code ?? "error",
                                      message: env.error.message ?? "")
            }
            throw ClaudeError.api(status: http.statusCode, type: "http",
                                  message: String(data: body.prefix(500), encoding: .utf8) ?? "")
        }
    }
}

/// Parses OpenAI-style chat-completion SSE into the same `StreamEvent`s the Anthropic parser
/// emits, so everything downstream is provider-agnostic.
public struct OpenAISSEParser: Sendable {
    let requestedModel: String
    private var announcedStart = false

    public init(requestedModel: String) { self.requestedModel = requestedModel }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
            let finish_reason: String?
        }
        struct U: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        let model: String?
        let choices: [Choice]?
        /// Groq reports usage on the final chunk, and under this key when it is nested.
        let usage: U?
        let x_groq: XGroq?
        struct XGroq: Decodable { let usage: U? }
    }
    private struct ErrorChunk: Decodable {
        struct E: Decodable { let type: String?; let message: String? }
        let error: E
    }

    /// One line can complete more than one event, so this returns an array.
    public mutating func feed(_ rawLine: String) -> [StreamEvent] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("data:") else { return [] }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        guard !payload.isEmpty else { return [] }
        // The OpenAI wire format ends with a literal sentinel rather than a JSON event.
        if payload == "[DONE]" { return [.messageStop] }
        guard let data = payload.data(using: .utf8) else { return [] }

        if let e = try? JSONDecoder().decode(ErrorChunk.self, from: data) {
            return [.error(.stream(type: e.error.type ?? "error", message: e.error.message ?? ""))]
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else {
            return [.error(.decoding("chunk: \(payload.prefix(200))"))]
        }
        var events: [StreamEvent] = []
        let usage = chunk.usage ?? chunk.x_groq?.usage
        if !announcedStart {
            announcedStart = true
            events.append(.messageStart(model: chunk.model ?? requestedModel,
                                        inputTokens: usage?.prompt_tokens ?? 0))
        }
        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
            events.append(.textDelta(text))
        }
        if let finish = chunk.choices?.first?.finish_reason {
            events.append(.messageDelta(stopReason: GroqClient.stopReason(finish),
                                        outputTokens: usage?.completion_tokens ?? 0,
                                        inputTokens: usage?.prompt_tokens ?? 0))
        } else if let usage, usage.completion_tokens != nil, chunk.choices?.isEmpty ?? true {
            // A trailing usage-only chunk.
            events.append(.messageDelta(stopReason: nil, outputTokens: usage.completion_tokens ?? 0,
                                        inputTokens: usage.prompt_tokens ?? 0))
        }
        return events
    }
}

extension GroqClient {
    struct ModelList: Decodable {
        struct Entry: Decodable { let id: String; let context_window: Int? }
        let data: [Entry]?
    }

    public func availableModels() async throws -> [RemoteModel] {
        let models = baseURL.absoluteString.replacingOccurrences(of: "/chat/completions", with: "/models")
        var r = URLRequest(url: URL(string: models)!)
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: r)
        try Self.check(response: response, body: data)
        return (try JSONDecoder().decode(ModelList.self, from: data).data ?? [])
            .map { RemoteModel(id: $0.id, displayName: nil, inputTokenLimit: $0.context_window) }
    }
}
