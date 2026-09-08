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

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func read() throws -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { throw KeychainError.unreadable }
        return s
    }

    public static func save(_ value: String) throws {
        try delete()
        var q = baseQuery
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
