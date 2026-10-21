import Foundation
import LocalAuthentication
import NoteItSync
import Security

/// The CLI's tokens, one Keychain generic password per profile under `AppIdentity.cliKeychainService`.
struct CLIKeychain {
    var store: SecretStore
    var service: String

    init(store: SecretStore = CLISecItemStore(), service: String = AppIdentity.cliKeychainService) {
        self.store = store
        self.service = service
    }

    /// The same Keychain, but reads fail instead of asking the user to allow access.
    func nonInteractive() -> CLIKeychain {
        guard var live = store as? CLISecItemStore else { return self }
        live.allowsInteraction = false
        return CLIKeychain(store: live, service: service)
    }

    func token(profile: String) -> String? {
        guard let token = store.read(service: service, account: profile), !token.isEmpty else { return nil }
        return token
    }

    func save(_ token: String, profile: String) throws {
        try store.write(token, service: service, account: profile)
    }

    func remove(profile: String) throws {
        try store.remove(service: service, account: profile)
    }
}

struct CLIKeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
    }
}

/// The same three Security calls as the app's `SecItemStore`, which lives in the app target.
struct CLISecItemStore: SecretStore {
    static let label = "noteit command line tool"

    var allowsInteraction = true

    func read(service: String, account: String) -> String? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = allowsInteraction ? SecItemCopyMatching(query as CFDictionary, &item)
            : (LegacyKeychain.self as KeychainInteraction.Type).withoutInteraction { SecItemCopyMatching(query as CFDictionary, &item) }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, service: String, account: String) throws {
        let query = Self.baseQuery(service: service, account: account)
        let update: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(update) { _, new in new }
            add[kSecAttrLabel as String] = Self.label
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CLIKeychainError(status: status) }
    }

    func remove(service: String, account: String) throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CLIKeychainError(status: status) }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private protocol KeychainInteraction {
    static func withoutInteraction(_ body: () -> OSStatus) -> OSStatus
}

/// The login keychain is a file-based keychain, where only the deprecated SecKeychain switch keeps a read from showing
/// an "allow access" dialog; the LAContext setting covers the data protection keychain. Called through
/// `KeychainInteraction` so the deprecation warning stays here.
private enum LegacyKeychain: KeychainInteraction {
    @available(macOS, deprecated: 10.10)
    static func withoutInteraction(_ body: () -> OSStatus) -> OSStatus {
        var allowed: DarwinBoolean = true
        let known = SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(known ? allowed.boolValue : true) }
        return body()
    }
}
