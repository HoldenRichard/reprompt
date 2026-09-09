import Foundation

public enum APIKeyProvider {
    public static let environmentVariable = "ANTHROPIC_API_KEY"

    public static func environmentVariable(for provider: Provider) -> String {
        switch provider {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        case .groq: "GROQ_API_KEY"
        }
    }

    /// Resolves the key for one provider: its environment variable first, then its own
    /// Keychain entry. Two providers' keys never collide because the account differs.
    public static func resolve(
        provider: Provider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: ((Provider) throws -> String?)? = nil
    ) throws -> String {
        let lookup = keychain ?? { p in try KeychainStore.read(account: p.keychainAccount) }
        if let k = environment[environmentVariable(for: provider)]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        if let k = try lookup(provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        throw ClaudeError.missingAPIKey
    }

    /// Environment first (harness runs), then Keychain (the app), else `missingAPIKey`.
    /// `keychain` is injectable so tests never touch the user's real stored key.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: () throws -> String? = { try KeychainStore.read() }
    ) throws -> String {
        if let k = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        if let k = try keychain()?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        throw ClaudeError.missingAPIKey
    }

    /// For display only: "sk-ant...ab12". Short keys are masked entirely rather than
    /// shown twice by an overlapping prefix and suffix.
    public static func redacted(_ key: String) -> String {
        guard key.count >= 12 else { return String(repeating: "*", count: Swift.max(4, key.count)) }
        return String(key.prefix(6)) + "..." + String(key.suffix(4))
    }
}
