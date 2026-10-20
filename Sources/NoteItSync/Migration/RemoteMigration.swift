import Foundation

/// Copies a remote store written under Inkwell's prefix (`inkwell/v1/`) to `noteit/v1/` the first time a
/// device connects to it. Objects are copied byte for byte: cipher contexts are relative to the root, so
/// sealed objects stay valid. The manifest goes last, so an interrupted copy is never mistaken for a
/// complete store and is simply redone on the next connect. The legacy objects are left in place.
public enum RemoteMigration {
    /// Returns whether a legacy store was copied. Does nothing when `noteit/v1/` already has a manifest.
    @discardableResult
    public static func migrateLegacyStoreIfNeeded(_ backend: StorageBackend, log: (String) -> Void = { NSLog("%@", $0) }) async throws -> Bool {
        if try await exists(RemoteLayout.manifest(), in: backend) { return false }
        let legacyManifest = RemoteLayout.legacyRoot + "manifest.json"
        let objects = try await backend.list(prefix: RemoteLayout.legacyRoot)
        guard objects.contains(where: { $0.key == legacyManifest }) else { return false }

        for object in objects where object.key != legacyManifest {
            let key = RemoteLayout.root + object.key.dropFirst(RemoteLayout.legacyRoot.count)
            let data: Data
            do {
                data = try await backend.get(object.key).data
            } catch StorageError.notFound {
                continue  // Deleted by another device since the listing.
            }
            try await backend.put(key, data: data, ifMatch: nil, ifNoneMatch: false)
        }
        do {
            let manifest = try await backend.get(legacyManifest).data
            try await backend.put(RemoteLayout.manifest(), data: manifest, ifMatch: nil, ifNoneMatch: true)
        } catch StorageError.preconditionFailed {
            // Another device finished the same copy first.
        }
        log("NoteItSync: copied \(objects.count) object(s) from \(RemoteLayout.legacyRoot) to \(RemoteLayout.root)")
        return true
    }

    private static func exists(_ key: String, in backend: StorageBackend) async throws -> Bool {
        do {
            _ = try await backend.get(key)
            return true
        } catch StorageError.notFound {
            return false
        }
    }
}
