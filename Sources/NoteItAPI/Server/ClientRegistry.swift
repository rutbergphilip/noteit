import Foundation

/// A paired client as the app stores it: only the token's hash and hint, never the token. Shape owned by the
/// automation plan; built in foundations Task 5.2. Automation adds the store and verification to this file.
public struct ClientRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ClientKind
    public var scopes: [APIScope]
    public var origin: String?
    public var tokenHash: String
    public var tokenHint: String
    public var createdAt: Date

    public init(id: UUID, name: String, kind: ClientKind, scopes: [APIScope], origin: String?, tokenHash: String,
                tokenHint: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scopes = scopes
        self.origin = origin
        self.tokenHash = tokenHash
        self.tokenHint = tokenHint
        self.createdAt = createdAt
    }
}

/// Where the registry keeps its records: the Keychain in the app, memory in tests.
public protocol ClientStore: Sendable {
    func load() -> [ClientRecord]
    func save(_ records: [ClientRecord]) throws
}

public final class InMemoryClientStore: ClientStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ClientRecord]

    public init(_ records: [ClientRecord] = []) {
        self.records = records
    }

    public func load() -> [ClientRecord] { lock.withLock { records } }

    public func save(_ records: [ClientRecord]) throws { lock.withLock { self.records = records } }
}

/// Paired clients and token verification. Tokens are never kept: only their SHA-256 hashes.
public final class ClientRegistry: @unchecked Sendable {
    private let store: ClientStore
    private let lock = NSLock()
    private var records: [ClientRecord]
    /// Hashes of tokens revoked during this launch, so their next request gets `token_revoked`.
    private var revokedHashes: Set<String> = []
    private var revokeHandler: (@Sendable (UUID) -> Void)?

    public init(store: ClientStore) {
        self.store = store
        self.records = store.load()
    }

    public var clients: [ClientRecord] { lock.withLock { records } }

    /// Called after a client is revoked, outside the registry's lock.
    public var onRevoke: (@Sendable (UUID) -> Void)? {
        get { lock.withLock { revokeHandler } }
        set { lock.withLock { revokeHandler = newValue } }
    }

    /// Takes the `Authorization` value with or without the `Bearer ` prefix. Every record is compared, in constant
    /// time, whatever matches first.
    public func authenticate(bearer: String?) -> ClientRecord? {
        guard let token = Self.token(from: bearer) else { return nil }
        let snapshot = clients
        var found: ClientRecord?
        for record in snapshot where APIToken.matches(token, hash: record.tokenHash) {
            found = record
        }
        return found
    }

    /// True when this token belonged to a client revoked during this launch.
    public func wasRevoked(bearer: String?) -> Bool {
        guard let token = Self.token(from: bearer) else { return false }
        let hash = APIToken.hash(token)
        return lock.withLock { revokedHashes.contains(hash) }
    }

    public func issue(name: String, kind: ClientKind, scopes: [APIScope], origin: String?,
                      now: Date = Date()) throws -> (ClientRecord, token: String) {
        let token = APIToken.generate()
        let record = ClientRecord(id: UUID(), name: name, kind: kind, scopes: APIScope.normalized(scopes), origin: origin,
                                  tokenHash: APIToken.hash(token), tokenHint: APIToken.hint(token), createdAt: now)
        try lock.withLock {
            try store.save(records + [record])
            records.append(record)
        }
        return (record, token)
    }

    /// Throws `APIErrorCode.notFound` for an unknown id.
    public func revoke(_ id: UUID) throws {
        let handler = try lock.withLock { () throws -> (@Sendable (UUID) -> Void)? in
            guard let record = records.first(where: { $0.id == id }) else { throw APIErrorCode.notFound }
            let remaining = records.filter { $0.id != id }
            try store.save(remaining)
            records = remaining
            revokedHashes.insert(record.tokenHash)
            return revokeHandler
        }
        handler?(id)
    }

    public func revokeAll() throws {
        let (removed, handler) = try lock.withLock { () throws -> ([ClientRecord], (@Sendable (UUID) -> Void)?) in
            try store.save([])
            let removed = records
            records = []
            revokedHashes.formUnion(removed.map(\.tokenHash))
            return (removed, revokeHandler)
        }
        for record in removed { handler?(record.id) }
    }

    private static func token(from bearer: String?) -> String? {
        guard var value = bearer?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("bearer ") {
            value = value.dropFirst(7).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? nil : value
    }
}
