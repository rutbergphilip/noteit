import Foundation
import Security

/// Generic-password storage for sync secrets. Values are never logged.
enum Keychain {
    static let service = "com.inkwell.app.sync"

    enum Account: String, CaseIterable {
        case s3AccessKey = "s3-access-key"
        case s3Secret = "s3-secret"
        case passphrase = "passphrase"
    }

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain: \(message)"
        }
    }

    static func get(_ account: Account) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: Account) throws {
        guard let value, !value.isEmpty else {
            delete(account)
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add.merge(update) { _, new in new }
            add[kSecAttrLabel as String] = "Inkwell Sync"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func delete(_ account: Account) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    static func deleteAll() {
        Account.allCases.forEach(delete)
    }

    private static func baseQuery(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}
