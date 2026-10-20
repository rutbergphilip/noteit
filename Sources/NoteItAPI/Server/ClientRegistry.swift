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
