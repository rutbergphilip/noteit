import Foundation
import NoteItAPI
import NoteItSync

/// Paired Local API clients, kept as one JSON item in the login keychain. Only token hashes are stored.
final class KeychainClientStore: ClientStore, @unchecked Sendable {
    static let account = "clients"
    static let label = "NoteIt Local API"

    /// The saved clients couldn't be read, so saving would overwrite them.
    struct Unreadable: Error {}

    private let secrets: LabeledSecretStore
    private let service: String
    private let lock = NSLock()
    private var unreadable = false

    init(secrets: LabeledSecretStore = SecItemStore(), service: String = AppIdentity.localAPIKeychainService) {
        self.secrets = secrets
        self.service = service
    }

    func load() -> [ClientRecord] {
        do {
            guard let text = try secrets.readExisting(service: service, account: Self.account) else { return [] }
            return try JSONDecoder().decode([ClientRecord].self, from: Data(text.utf8))
        } catch {
            lock.withLock { unreadable = true }
            NSLog("NoteIt: couldn't read the paired Local API clients: \(error)")
            return []
        }
    }

    /// Refuses to save after a failed `load()` until the next launch, so a passing keychain problem can't erase
    /// every paired client.
    func save(_ records: [ClientRecord]) throws {
        guard !lock.withLock({ unreadable }) else { throw Unreadable() }
        if records.isEmpty {
            try secrets.remove(service: service, account: Self.account)
            return
        }
        let data = try JSONEncoder().encode(records)
        try secrets.write(String(decoding: data, as: UTF8.self), service: service, account: Self.account, label: Self.label)
    }
}
