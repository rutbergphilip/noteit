import Foundation
import NoteItAPI

/// In-process issue, list and revoke for Local API clients. Revoking here closes the client's event streams the
/// same way `DELETE /v1/clients/{id}` does, because both go through the server's `ClientRegistry`.
@MainActor
final class AutomationClients {
    let registry: ClientRegistry
    private let lastUsed: (UUID) -> Date?

    init(registry: ClientRegistry, lastUsed: @escaping (UUID) -> Date? = { _ in nil }) {
        self.registry = registry
        self.lastUsed = lastUsed
    }

    func issue(name: String, kind: ClientKind, scopes: [APIScope], origin: String?) throws(AutomationError) -> (ClientDTO, token: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(PairingBroker.maxNameLength))
        guard !name.isEmpty else { throw .invalidInput("Give the token a name.") }
        guard !scopes.isEmpty else { throw .invalidInput("Choose what the token can do.") }
        do {
            let (record, token) = try registry.issue(name: name, kind: kind, scopes: scopes, origin: origin)
            return (dto(record), token)
        } catch {
            throw .notChanged
        }
    }

    func list() -> [ClientDTO] {
        registry.clients.map(dto)
    }

    func revoke(_ id: UUID) throws(AutomationError) {
        do {
            try registry.revoke(id)
        } catch APIErrorCode.notFound {
            throw .notFound
        } catch {
            throw .notChanged
        }
    }

    func revokeAll() throws(AutomationError) {
        do {
            try registry.revokeAll()
        } catch {
            throw .notChanged
        }
    }

    private func dto(_ record: ClientRecord) -> ClientDTO {
        ClientDTO(id: record.id, name: record.name, kind: record.kind, scopes: record.scopes, origin: record.origin,
                  tokenHint: record.tokenHint, createdAt: record.createdAt, lastUsedAt: lastUsed(record.id))
    }
}
