import Foundation

/// Minimal generic-password store, keyed by service and account (the keychain in the app; a fake in tests).
public protocol SecretStore {
    func read(service: String, account: String) -> String?
    func write(_ value: String, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

/// Reads a secret under `service`, adopting it from `legacyService` on a miss.
public enum SecretMigration {
    /// On a miss under `service`, looks under `legacyService`; a hit is re-saved under `service`
    /// and the legacy item deleted (a failed delete is ignored). If re-saving fails, the legacy
    /// item is kept and its value still returned.
    public static func read(account: String, service: String, legacyService: String, store: SecretStore) -> String? {
        if let value = store.read(service: service, account: account) { return value }
        guard let legacy = store.read(service: legacyService, account: account) else { return nil }
        do {
            try store.write(legacy, service: service, account: account)
        } catch {
            return legacy
        }
        try? store.remove(service: legacyService, account: account)
        return legacy
    }
}
