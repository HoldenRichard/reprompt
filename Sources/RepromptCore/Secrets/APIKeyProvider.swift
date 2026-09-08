import Foundation

public enum APIKeyProvider {
    public static let environmentVariable = "ANTHROPIC_API_KEY"

    /// Environment first (harness runs), then Keychain (the app), else `missingAPIKey`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let k = environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        if let k = try KeychainStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        throw ClaudeError.missingAPIKey
    }

    /// For display only: "sk-ant-...ab12".
    public static func redacted(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        return String(key.prefix(6)) + "..." + String(key.suffix(4))
    }
}
