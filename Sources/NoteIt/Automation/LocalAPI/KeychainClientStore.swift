import Foundation
import NoteItAPI
import NoteItSync
import os

/// Paired Local API clients, kept as one JSON item in the login keychain. Only token hashes are stored.
final class KeychainClientStore: ClientStore, @unchecked Sendable {
    static let account = "clients"
    /// Keeps a copy of a saved list that couldn't be decoded, such as one written by a newer version.
    static let unreadableAccount = "clients.unreadable"
    static let label = "NoteIt Local API"

    /// The saved clients couldn't be read, so saving would overwrite them.
    struct Unreadable: Error {}

    private let secrets: LabeledSecretStore
    private let service: String
    private let lock = NSLock()
    private var unreadable = false
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "LocalAPI")

    init(secrets: LabeledSecretStore = SecItemStore(), service: String = AppIdentity.localAPIKeychainService) {
        self.secrets = secrets
        self.service = service
    }

    func load() -> [ClientRecord] {
        let text: String?
        do {
            text = try secrets.readExisting(service: service, account: Self.account)
        } catch {
            lock.withLock { unreadable = true }
            logger.error("Couldn't read the paired Local API clients: \(String(describing: error), privacy: .public)")
            return []
        }
        guard let text else { return [] }
        let decoded = try? JSONDecoder().decode([Lenient].self, from: Data(text.utf8))
        let records = decoded?.compactMap(\.record) ?? []
        if decoded?.count != records.count {
            try? secrets.write(text, service: service, account: Self.unreadableAccount, label: Self.label)
            let skipped = decoded.map { "\($0.count - records.count)" } ?? "all"
            logger.error("Skipped \(skipped, privacy: .public) paired Local API clients that couldn't be decoded; kept a copy")
        }
        return records
    }

    /// Refuses to save after a failed keychain read until the next launch, so a passing keychain problem can't
    /// erase every paired client. A list that was read but couldn't be decoded doesn't block saving; its copy is
    /// kept under `unreadableAccount`.
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

private struct Lenient: Decodable {
    let record: ClientRecord?

    init(from decoder: Decoder) throws {
        record = try? ClientRecord(from: decoder)
    }
}
