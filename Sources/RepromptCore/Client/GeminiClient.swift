import Foundation

/// Google's Generative Language API. Distinct from both other providers: the model lives in
/// the URL path, the system prompt is its own top-level field, and structured output uses an
/// OpenAPI-subset dialect rather than JSON Schema.
///
/// Billing note: paid-tier usage (which is what Google AI Pro's monthly credits buy) is not
/// used to train Google's models. The free tier is, which is why this client is only useful
/// with credits attached.
public struct GeminiClient: LLMClient, Sendable {
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    public let provider: Provider = .gemini
    public let apiKey: String
    public let baseURL: URL
    private let session: URLSession
    public var retry: RetryPolicy

    public init(apiKey: String, baseURL: URL = GeminiClient.defaultBaseURL, session: URLSession = .shared, retry: RetryPolicy = .default) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.retry = retry
    }

    // MARK: Schema translation

    /// Gemini's `responseSchema` is an OpenAPI 3.0 subset, not JSON Schema: type names are
    /// upper-case and `additionalProperties` is rejected. Sending our JSON Schema unchanged
    /// is a 400, so it is translated rather than passed through.
    public static func responseSchema(from schema: JSONValue) -> JSONValue {
        guard case .object(let o) = schema else { return schema }
        var out: [String: JSONValue] = [:]
        for (key, value) in o {
            switch key {
            case "additionalProperties":
                continue  // unsupported by Gemini
            case "type":
                if case .string(let t) = value {
                    out["type"] = .string(t.uppercased())
                } else {
                    out["type"] = value
                }
            case "properties":
                if case .object(let props) = value {
                    out["properties"] = .object(props.mapValues { responseSchema(from: $0) })
                    // Gemini does not guarantee key order unless asked.
                    out["propertyOrdering"] = .array(props.keys.sorted().map { .string($0) })
                } else {
                    out["properties"] = value
                }
            case "items":
                out["items"] = responseSchema(from: value)
            default:
                out[key] = value
            }
        }
        return .object(out)
    }

    // MARK: Wire format

    struct Body: Encodable {
        struct Part: Encodable { let text: String }
        struct Content: Encodable { let role: String?; let parts: [Part] }
        struct SystemInstruction: Encodable { let parts: [Part] }
        struct GenerationConfig: Encodable {
            let maxOutputTokens: Int
            let responseMimeType: String?
            let responseSchema: JSONValue?
        }
        let systemInstruction: SystemInstruction?
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    func body(for request: ChatRequest) -> Body {
        let schema = request.jsonSchema.map { Self.responseSchema(from: $0) }
        return Body(
            systemInstruction: request.system.flatMap { s in
                s.isEmpty ? nil : Body.SystemInstruction(parts: [.init(text: s)])
            },
            contents: [.init(role: "user", parts: [.init(text: request.user)])],
            generationConfig: .init(
                maxOutputTokens: request.maxTokens,
                responseMimeType: schema == nil ? nil : "application/json",
                responseSchema: schema))
    }

    func url(model: String, streaming: Bool) -> URL {
        // The model is part of the path, and ":" is a legal path character here.
        let method = streaming ? "streamGenerateContent?alt=sse" : "generateContent"
        return URL(string: baseURL.absoluteString + "/models/" + model + ":" + method)!
    }

    public func urlRequest(for request: ChatRequest) throws -> URLRequest {
        var r = URLRequest(url: url(model: request.model, streaming: request.stream))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than a ?key= query parameter, so the key stays out of URLs and logs.
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        r.httpBody = try encoder.encode(body(for: request))
        r.timeoutInterval = 600
        return r
    }

    // MARK: Responses

    struct Generation: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        struct PromptFeedback: Decodable { let blockReason: String? }
        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
            let cachedContentTokenCount: Int?
        }
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
        let usageMetadata: UsageMetadata?
        let modelVersion: String?

        var text: String {
            (candidates?.first?.content?.parts ?? []).compactMap(\.text).joined()
        }
        var usage: Usage {
            Usage(inputTokens: usageMetadata?.promptTokenCount ?? 0,
                  // Thinking tokens bill as output, so they belong in the output count.
                  outputTokens: (usageMetadata?.candidatesTokenCount ?? 0)
                      + (usageMetadata?.thoughtsTokenCount ?? 0),
                  cacheCreationInputTokens: nil,
                  cacheReadInputTokens: usageMetadata?.cachedContentTokenCount)
        }
    }

    /// Gemini reports several distinct refusals; all of them mean "no answer is coming".
    static func stopReason(finish: String?, blockReason: String?) -> StopReason? {
        if let blockReason, !blockReason.isEmpty, blockReason != "BLOCK_REASON_UNSPECIFIED" {
            return .refusal
        }
        switch finish {
        case "STOP": return .endTurn
        case "MAX_TOKENS": return .maxTokens
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY":
            return .refusal
        case nil: return nil
        case .some(let other): return .unknown(other)
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
            let g = try JSONDecoder().decode(Generation.self, from: data)
            let stop = Self.stopReason(finish: g.candidates?.first?.finishReason,
                                       blockReason: g.promptFeedback?.blockReason)
            return ChatResponse(
                text: g.text, servedModel: g.modelVersion ?? request.model, usage: g.usage,
                stopReason: stop,
                stopDetails: stop == .refusal
                    ? StopDetails(type: "refusal",
                                  category: g.promptFeedback?.blockReason ?? g.candidates?.first?.finishReason,
                                  explanation: nil)
                    : nil)
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
                    var parser = GeminiSSEParser(requestedModel: model)
                    var finished = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in parser.feed(line) {
                            continuation.yield(event)
                            if case .messageDelta(let reason, _, _) = event, reason != nil { finished = true }
                            if case .error(let e) = event { throw e }
                        }
                    }
                    // Gemini has no end sentinel; the final chunk carries a finishReason.
                    // Without one the connection dropped, which is not a finished message.
                    guard finished else {
                        throw ClaudeError.invalidResponse("stream ended without a finish reason")
                    }
                    continuation.yield(.messageStop)
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
        struct Inner: Decodable { let code: Int?; let message: String?; let status: String? }
        let error: Inner
    }

    static func check(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse("not HTTP") }
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
                throw ClaudeError.api(status: http.statusCode,
                                      type: env.error.status ?? "error",
                                      message: env.error.message ?? "")
            }
            throw ClaudeError.api(status: http.statusCode, type: "http",
                                  message: String(data: body.prefix(500), encoding: .utf8) ?? "")
        }
    }
}

/// Parses Gemini's SSE into the shared `StreamEvent` vocabulary.
public struct GeminiSSEParser: Sendable {
    let requestedModel: String
    private var announcedStart = false

    public init(requestedModel: String) { self.requestedModel = requestedModel }

    public mutating func feed(_ rawLine: String) -> [StreamEvent] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("data:") else { return [] }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return [] }

        if let e = try? JSONDecoder().decode(GeminiClient.ErrorEnvelope.self, from: data) {
            return [.error(.stream(type: e.error.status ?? "error", message: e.error.message ?? ""))]
        }
        guard let g = try? JSONDecoder().decode(GeminiClient.Generation.self, from: data) else {
            return [.error(.decoding("chunk: \(payload.prefix(200))"))]
        }
        var events: [StreamEvent] = []
        if !announcedStart {
            announcedStart = true
            events.append(.messageStart(model: g.modelVersion ?? requestedModel,
                                        inputTokens: g.usage.inputTokens))
        }
        let text = g.text
        if !text.isEmpty { events.append(.textDelta(text)) }
        let stop = GeminiClient.stopReason(finish: g.candidates?.first?.finishReason,
                                           blockReason: g.promptFeedback?.blockReason)
        if stop != nil {
            events.append(.messageDelta(stopReason: stop, outputTokens: g.usage.outputTokens,
                                        inputTokens: g.usage.inputTokens))
        }
        return events
    }
}

extension GeminiClient {
    struct ModelList: Decodable {
        struct Entry: Decodable {
            let name: String
            let displayName: String?
            let inputTokenLimit: Int?
            let outputTokenLimit: Int?
            let supportedGenerationMethods: [String]?
        }
        let models: [Entry]?
    }

    /// Only models that can actually answer a prompt are returned; the list also carries
    /// embedding and other models that would fail at request time.
    public func availableModels() async throws -> [RemoteModel] {
        var r = URLRequest(url: URL(string: baseURL.absoluteString + "/models?pageSize=200")!)
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await session.data(for: r)
        try Self.check(response: response, body: data)
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return (list.models ?? [])
            .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? true }
            .map { RemoteModel(id: $0.name.replacingOccurrences(of: "models/", with: ""),
                               displayName: $0.displayName,
                               inputTokenLimit: $0.inputTokenLimit,
                               outputTokenLimit: $0.outputTokenLimit) }
    }
}
