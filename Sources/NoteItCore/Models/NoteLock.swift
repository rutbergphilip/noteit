import Foundation

/// Marks a note as locked: its body is sealed under the key `keyID`, as the sealed record `sealedID`.
/// Data only in wave 0; owned by the sync-security plan (foundations Task 4.3).
public struct NoteLock: Codable, Hashable, Sendable {
    public var keyID: String
    public var sealedID: UUID

    public init(keyID: String, sealedID: UUID) {
        self.keyID = keyID
        self.sealedID = sealedID
    }
}
