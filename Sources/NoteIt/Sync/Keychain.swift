import Foundation
import NoteItSync
import Security

/// Generic-password storage for sync secrets. Values are never logged.
enum Keychain {
    static let service = AppIdentity.keychainService

    enum Account: String, CaseIterable {
        case s3AccessKey = "s3-access-key"
        case s3Secret = "s3-secret"
        case passphrase = "passphrase"
        /// The keyring data key, base64 (foundations step 3).
        case syncDataKey = "sync-data-key"
    }

    struct Failure: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain: \(message)"
        }
    }

    /// Falls back to (and adopts) secrets saved by Inkwell under its legacy service.
    static func get(_ account: Account) -> String? {
        SecretMigration.read(account: account.rawValue, service: service,
                             legacyService: AppIdentity.Legacy.keychainService, store: SecItemStore())
    }

    static func set(_ value: String?, for account: Account) throws {
        guard let value, !value.isEmpty else {
            delete(account)
            return
        }
        try SecItemStore().write(value, service: service, account: account.rawValue)
    }

    /// Also removes any not-yet-adopted legacy item, so a cleared secret can't come back from it.
    static func delete(_ account: Account) {
        let store = SecItemStore()
        try? store.remove(service: service, account: account.rawValue)
        try? store.remove(service: AppIdentity.Legacy.keychainService, account: account.rawValue)
    }

    static func deleteAll() {
        Account.allCases.forEach(delete)
    }
}

/// A `SecretStore` that names the items it adds, as Keychain Access shows them.
protocol LabeledSecretStore: SecretStore {
    func write(_ value: String, service: String, account: String, label: String) throws
}

/// `SecretStore` over the login keychain's generic passwords.
struct SecItemStore: LabeledSecretStore {
    func read(service: String, account: String) -> String? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, service: String, account: String) throws {
        try write(value, service: service, account: account, label: "NoteIt Sync")
    }

    func write(_ value: String, service: String, account: String, label: String) throws {
        let query = Self.baseQuery(service: service, account: account)
        let update: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(update) { _, new in new }
            add[kSecAttrLabel as String] = label
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
    }

    func remove(service: String, account: String) throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Keychain.Failure(status: status) }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
