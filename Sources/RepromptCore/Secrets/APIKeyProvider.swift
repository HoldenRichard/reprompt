import Foundation

public enum APIKeyProvider {
    public static let environmentVariable = "ANTHROPIC_API_KEY"

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
