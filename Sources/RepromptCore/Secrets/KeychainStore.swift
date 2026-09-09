import Foundation
import Security

public enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)
    case unreadable
    public var description: String {
        switch self {
        case .status(let s): "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
        case .unreadable: "Keychain item is not UTF-8 text"
        }
    }
}

/// Generic-password storage for the API key. Never logs the value.
public enum KeychainStore {
    public static let service = "com.holdenrichard.reprompt"
    public static let account = "anthropic-api-key"

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
}
