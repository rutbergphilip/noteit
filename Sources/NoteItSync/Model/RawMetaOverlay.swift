import Foundation

/// Keeps fields a newer client wrote to a note or notebook meta when this build re-exports the record
/// (program §4 rule 5). foundations Task 3.5; shared with sync-security.
public struct RawMetaOverlay: Sendable, Equatable {
    /// The last decrypted note or notebook JSON, nil for a new record.
    public let lastDecrypted: Data?

    public init(lastDecrypted: Data?) {
        self.lastDecrypted = lastDecrypted
    }

    /// Keys in `ownedKeys` come from `encoded` (absent there means absent in the result, so a cleared optional
    /// is removed); every other key comes from `lastDecrypted`. `encoded` is returned unchanged when there is
    /// no last decrypted JSON, or when it isn't a JSON object and so has nothing to keep.
    public func merged(with encoded: Data, ownedKeys: Set<String>) throws -> Data {
        guard let lastDecrypted else { return encoded }
        guard let mine = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        guard var merged = (try? JSONSerialization.jsonObject(with: lastDecrypted)) as? [String: Any] else { return encoded }
        for key in ownedKeys { merged[key] = mine[key] }
        return try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }
}
