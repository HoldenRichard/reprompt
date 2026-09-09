import Foundation
#if canImport(Security)
import Security
#endif

public enum KeychainError: Error, CustomStringConvertible {
    case status(Int32)
    case unreadable
    /// This platform has no keychain; set the provider's environment variable instead.
    case unavailable

    public var description: String {
        switch self {
        case .status(let s):
            #if canImport(Security)
            return "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
            #else
            return "Keychain error \(s)"
            #endif
        case .unreadable: return "Keychain item is not UTF-8 text"
        case .unavailable: return "No keychain on this platform; set the provider's API key environment variable."
        }
    }
}

/// Generic-password storage for API keys. Never logs the value. On platforms without a
/// keychain every read returns nil and every write throws, so `APIKeyProvider` falls
/// through to the environment variable, which is the documented path there.
public enum KeychainStore {
    public static let service = "com.holdenrichard.reprompt"
    public static let account = "anthropic-api-key"

#if canImport(Security)
    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func read(service: String = service, account: String = account) throws -> String? {
        var q = baseQuery(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { throw KeychainError.unreadable }
        return s
    }

    /// Updates the stored item in place when one exists. Deleting first would leave the
    /// user with no key at all if the subsequent add failed.
    public static func save(_ value: String, service: String = service, account: String = account) throws {
        let q = baseQuery(service: service, account: account)
        let data = Data(value.utf8)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func delete(service: String = service, account: String = account) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
#else
    public static func read(service: String = service, account: String = account) throws -> String? { nil }
    public static func save(_ value: String, service: String = service, account: String = account) throws {
        throw KeychainError.unavailable
    }
    public static func delete(service: String = service, account: String = account) throws {}
#endif
}
