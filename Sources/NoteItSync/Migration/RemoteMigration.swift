import Foundation

/// Copies a remote store written under Inkwell's prefix (`inkwell/v1/`) to `noteit/v1/` the first time a
/// device connects to it. Objects are copied byte for byte: cipher contexts are relative to the root, so
/// sealed objects stay valid. The manifest goes last, so an interrupted copy is never mistaken for a
/// complete store and is simply resumed on the next connect. The legacy objects are left in place.
///
/// Several devices may migrate at once, and once one of them writes the manifest it starts syncing under
/// the new root. So objects are only created, never blindly replaced, and the copy stops as soon as the
/// manifest appears: a slower device must not undo edits made under the new root.
public enum RemoteMigration {
    /// How many objects are copied between checks for a manifest written by another device.
    static let manifestCheckInterval = 50

    /// Returns whether a legacy store was copied, by this device or another one during the copy.
    /// Does nothing when `noteit/v1/` already has a manifest.
    @discardableResult
    public static func migrateLegacyStoreIfNeeded(_ backend: StorageBackend, log: (String) -> Void = { NSLog("%@", $0) }) async throws -> Bool {
        if try await exists(RemoteLayout.manifest(), in: backend) { return false }
        let legacyManifest = RemoteLayout.legacyRoot + "manifest.json"
        let objects = try await backend.list(prefix: RemoteLayout.legacyRoot)
        guard objects.contains(where: { $0.key == legacyManifest }) else { return false }

        var copied = 0
        for (index, object) in objects.enumerated() where object.key != legacyManifest {
            if index > 0, index % manifestCheckInterval == 0, try await exists(RemoteLayout.manifest(), in: backend) {
                log("NoteItSync: another device finished copying \(RemoteLayout.legacyRoot) first")
                return true
            }
            let key = RemoteLayout.root + object.key.dropFirst(RemoteLayout.legacyRoot.count)
            let data: Data
            do {
                data = try await backend.get(object.key).data
            } catch StorageError.notFound {
                continue  // Deleted by another device since the listing.
            }
            switch try await copy(data, to: key, in: backend) {
            case .copied: copied += 1
            case .skipped: break
            case .storeMigrated:
                log("NoteItSync: another device finished copying \(RemoteLayout.legacyRoot) first")
                return true
            }
        }
        if try await exists(RemoteLayout.manifest(), in: backend) { return true }
        do {
            let manifest = try await backend.get(legacyManifest).data
            try await backend.put(RemoteLayout.manifest(), data: manifest, ifMatch: nil, ifNoneMatch: true)
        } catch StorageError.preconditionFailed {
            return true  // Another device finished the same copy first.
        }
        log("NoteItSync: copied \(copied) object(s) from \(RemoteLayout.legacyRoot) to \(RemoteLayout.root)")
        return true
    }

    private enum CopyResult { case copied, skipped, storeMigrated }

    private static func copy(_ data: Data, to key: String, in backend: StorageBackend) async throws -> CopyResult {
        do {
            try await backend.put(key, data: data, ifMatch: nil, ifNoneMatch: true)
            return .copied
        } catch StorageError.preconditionFailed {}
        let existing: (data: Data, etag: String)
        do {
            existing = try await backend.get(key)
        } catch StorageError.notFound {
            return .skipped
        }
        if existing.data == data { return .skipped }
        // A different copy from an earlier attempt is refreshed only while no device syncs under the new
        // root, and only if it is still the object just read.
        if try await exists(RemoteLayout.manifest(), in: backend) { return .storeMigrated }
        do {
            try await backend.put(key, data: data, ifMatch: existing.etag, ifNoneMatch: false)
            return .copied
        } catch StorageError.preconditionFailed {
            return .skipped
        }
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
