import Foundation
import NoteItAPI
import NoteItSync

/// Paired Local API clients, kept as one JSON item in the login keychain. Only token hashes are stored.
final class KeychainClientStore: ClientStore, @unchecked Sendable {
    static let account = "clients"
    static let label = "NoteIt Local API"

    private let secrets: LabeledSecretStore
    private let service: String

    init(secrets: LabeledSecretStore = SecItemStore(), service: String = AppIdentity.localAPIKeychainService) {
        self.secrets = secrets
        self.service = service
    }

    func load() -> [ClientRecord] {
        guard let text = secrets.read(service: service, account: Self.account) else { return [] }
        return (try? JSONDecoder().decode([ClientRecord].self, from: Data(text.utf8))) ?? []
    }

    func save(_ records: [ClientRecord]) throws {
        if records.isEmpty {
            try secrets.remove(service: service, account: Self.account)
            return
        }
        let data = try JSONEncoder().encode(records)
        try secrets.write(String(decoding: data, as: UTF8.self), service: service, account: Self.account, label: Self.label)
    }
}
