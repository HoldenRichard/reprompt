import Foundation

/// Which service answers a request. Each provider has its own wire format, its own model
/// list, and its own stored credential.
public enum Provider: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic
    case gemini
    case groq

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .groq: "Groq"
        }
    }
    /// Keychain account, so two providers' keys can coexist.
    public var keychainAccount: String {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .gemini: "gemini-api-key"
        case .groq: "groq-api-key"
        }
    }
    public var consoleURL: String {
        switch self {
        case .anthropic: "https://console.anthropic.com/settings/keys"
        case .gemini: "https://aistudio.google.com/apikey"
        case .groq: "https://console.groq.com/keys"
        }
    }
    /// True when the provider bills per token rather than offering a free tier.
    public var isPaid: Bool { self == .anthropic }
}

/// A provider-neutral request. Each client translates this into its own wire format and
/// drops whatever that provider does not support, rather than the caller having to know.
public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var system: String?
    public var user: String
    public var maxTokens: Int
    public var stream: Bool
    /// Structured output. Providers that cannot enforce a schema fall back to instruction.
    public var jsonSchema: JSONValue?
    /// Honoured only where the model supports it.
    public var effort: Effort?
    public var thinking: ThinkingMode?
    public var fastMode: Bool
    public var useFallbacks: Bool

    public init(model: String, system: String? = nil, user: String, maxTokens: Int,
                stream: Bool = false, jsonSchema: JSONValue? = nil, effort: Effort? = nil,
                thinking: ThinkingMode? = nil, fastMode: Bool = false, useFallbacks: Bool = true) {
        self.model = model
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.stream = stream
        self.jsonSchema = jsonSchema
        self.effort = effort
        self.thinking = thinking
        self.fastMode = fastMode
        self.useFallbacks = useFallbacks
    }
}

/// A provider-neutral completed response.
public struct ChatResponse: Sendable, Equatable {
    public var text: String
    public var servedModel: String
    public var usage: Usage
    public var stopReason: StopReason?
    public var stopDetails: StopDetails?

    public init(text: String, servedModel: String, usage: Usage,
                stopReason: StopReason? = nil, stopDetails: StopDetails? = nil) {
        self.text = text
        self.servedModel = servedModel
        self.usage = usage
        self.stopReason = stopReason
        self.stopDetails = stopDetails
    }
}

/// What the optimizer needs from a provider. Both clients emit the same `StreamEvent`s, so
/// everything above this line is provider-agnostic.
public protocol LLMClient: Sendable {
    var provider: Provider { get }
    func send(_ request: ChatRequest) async throws -> ChatResponse
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, any Error>
    /// Declared here, not only in the extension below: a method that exists solely in a
    /// protocol extension is dispatched STATICALLY, so calling it through `any LLMClient`
    /// would silently run the default and never reach the real implementation.
    func availableModels() async throws -> [RemoteModel]
}

public enum LLMClientFactory {
    /// Builds the client for `provider`, reading that provider's own stored key.
    public static func make(provider: Provider, session: URLSession = .shared) throws -> any LLMClient {
        let key = try APIKeyProvider.resolve(provider: provider)
        switch provider {
        case .anthropic: return ClaudeClient(apiKey: key, session: session)
        case .gemini: return GeminiClient(apiKey: key, session: session)
        case .groq: return GroqClient(apiKey: key, session: session)
        }
    }
}

/// A model as the provider itself reports it, so the catalog can be checked against reality
/// rather than against what was true when the catalog was written.
public struct RemoteModel: Sendable, Equatable {
    public let id: String
    public let displayName: String?
    public let inputTokenLimit: Int?
    public let outputTokenLimit: Int?
    public init(id: String, displayName: String? = nil, inputTokenLimit: Int? = nil, outputTokenLimit: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.inputTokenLimit = inputTokenLimit
        self.outputTokenLimit = outputTokenLimit
    }
}

extension LLMClient {
    /// Listing models generates no tokens, so this is free to call on every provider.
    public func availableModels() async throws -> [RemoteModel] { [] }
}

/// Busy models return 503 often enough that a hotkey which gives up on the first one is not
/// usable. Only failures that could plausibly succeed on a second attempt are retried; a 400
/// or a refusal is retried never, because repeating it just wastes the user's credit.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var multiplier: Double
    /// Off by default. A 429 means the quota is already spent, and retrying inside a
    /// per-minute window spends more of it and can extend the lockout. Observed live: three
    /// retries against a five-requests-per-minute limit turned one refusal into a longer one.
    public var retryRateLimits: Bool

    public init(maxAttempts: Int = 3, initialDelay: Duration = .milliseconds(400),
                multiplier: Double = 2.5, retryRateLimits: Bool = false) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.retryRateLimits = retryRateLimits
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1)

    public func isRetryable(_ error: any Error) -> Bool {
        guard let e = error as? ClaudeError else { return false }
        switch e {
        case .api(let status, _, _):
            if status == 429 { return retryRateLimits }
            // 408 timeout, 409 conflict, and anything 5xx: transient, and retrying is free.
            return status == 408 || status == 409 || (500...599).contains(status)
        case .network:
            return true
        default:
            return false
        }
    }

    /// `attempt` is 1 for the delay before the second try.
    public func delay(beforeAttempt attempt: Int) -> Duration {
        let factor = pow(multiplier, Double(max(0, attempt - 1)))
        return .milliseconds(Int(Double(initialDelay.components.seconds) * 1000 * factor
            + Double(initialDelay.components.attoseconds) / 1e15 * factor))
    }
}

public enum HTTPRetry {
    /// Runs `body`, retrying only retryable failures. Cancellation is never retried.
    public static func run<T>(_ policy: RetryPolicy, _ body: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < policy.maxAttempts, policy.isRetryable(error) else { throw error }
                try await Task.sleep(for: policy.delay(beforeAttempt: attempt))
                attempt += 1
            }
        }
    }

    /// Opens a streaming connection, retrying before any event has been emitted. Retrying
    /// after the first token would duplicate output, so only the connect phase is covered.
    public static func connect(
        session: URLSession, request: URLRequest, policy: RetryPolicy,
        check: @Sendable (URLResponse, Data) throws -> Void
    ) async throws -> URLSession.AsyncBytes {
        try await run(policy) {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var body = Data()
                for try await b in bytes { body.append(b) }
                try check(response, body)
            }
            return bytes
        }
    }
}
