import Foundation

/// Copies a remote store written under Inkwell's prefix (`inkwell/v1/`) to `noteit/v1/` the first time a
/// device connects to it. Objects are copied byte for byte: cipher contexts are relative to the root, so
/// sealed objects stay valid. The manifest goes last, so an interrupted copy is never mistaken for a
/// complete store and is simply resumed on the next connect. The legacy objects are left in place.
///
/// Several devices may migrate at once, and once one of them writes the manifest it starts syncing under
/// the new root. So objects are only created, never blindly replaced, and the manifest is checked before
/// every create. Once it appears the copy stops. A note or notebook deleted under the new root keeps its
/// tombstone (written before its meta and body are deleted), so its objects created since the last check that
/// saw no manifest are deleted again (unless changed since). Other copies are kept: they are identical to what
/// the finishing device copied or skipped. Before the manifest exists nothing syncs under the new root, so
/// tombstones there that differ from the legacy ones are left over from an interrupted copy and are removed.
public enum RemoteMigration {
    /// Returns whether a legacy store was copied, by this device or another one during the copy.
    /// Does nothing when `noteit/v1/` already has a manifest.
    @discardableResult
    public static func migrateLegacyStoreIfNeeded(_ backend: StorageBackend, log: (String) -> Void = { NSLog("%@", $0) }) async throws -> Bool {
        if try await exists(RemoteLayout.manifest(), in: backend) { return false }
        let legacyManifest = RemoteLayout.legacyRoot + "manifest.json"
        let objects = try await backend.list(prefix: RemoteLayout.legacyRoot)
        guard objects.contains(where: { $0.key == legacyManifest }) else { return false }

        if try await removeStaleTombstones(in: backend) {
            log("NoteItSync: another device finished copying \(RemoteLayout.legacyRoot) first")
            return true
        }

        var copied = 0
        var unconfirmed: [(key: String, etag: String, tombstone: String)] = []
        func manifestAppeared() async throws -> Bool {
            guard try await exists(RemoteLayout.manifest(), in: backend) else {
                unconfirmed.removeAll()
                return false
            }
            for object in unconfirmed {
                guard try await tombstoneDeleted(object.tombstone, in: backend) else { continue }
                do {
                    try await backend.delete(object.key, ifMatch: object.etag)
                } catch StorageError.notFound {
                } catch StorageError.preconditionFailed {}
            }
            unconfirmed.removeAll()
            log("NoteItSync: another device finished copying \(RemoteLayout.legacyRoot) first")
            return true
        }

        for object in objects where object.key != legacyManifest {
            let key = RemoteLayout.root + object.key.dropFirst(RemoteLayout.legacyRoot.count)
            let data: Data
            do {
                data = try await backend.get(object.key).data
            } catch StorageError.notFound {
                continue  // Deleted by another device since the listing.
            }
            if try await manifestAppeared() { return true }
            let tombstone = tombstoneKey(for: key)
            switch try await copy(data, to: key, in: backend) {
            case .created(let etag):
                if let tombstone { unconfirmed.append((key, etag, tombstone)) }
                copied += 1
            case .replaced: copied += 1
            case .skipped: break
            case .storeMigrated:
                log("NoteItSync: another device finished copying \(RemoteLayout.legacyRoot) first")
                return true
            }
        }
        if try await manifestAppeared() { return true }
        do {
            let manifest = try await backend.get(legacyManifest).data
            try await backend.put(RemoteLayout.manifest(), data: manifest, ifMatch: nil, ifNoneMatch: true)
        } catch StorageError.preconditionFailed {
            return true  // Another device finished the same copy first.
        }
        log("NoteItSync: copied \(copied) object(s) from \(RemoteLayout.legacyRoot) to \(RemoteLayout.root)")
        return true
    }

    /// The tombstone of the note or notebook `key` belongs to; nil for objects that are not per record.
    private static func tombstoneKey(for key: String) -> String? {
        for folder in ["notes/", "notebooks/"] where key.hasPrefix(RemoteLayout.root + folder) {
            let name = key.dropFirst((RemoteLayout.root + folder).count)
            guard !name.contains("/"), let id = UUID(uuidString: String(name.prefix(36))) else { return nil }
            return RemoteLayout.tombstone(id)
        }
        return nil
    }

    /// Returns whether the manifest appeared, which ends the cleanup.
    private static func removeStaleTombstones(in backend: StorageBackend) async throws -> Bool {
        for object in try await backend.list(prefix: RemoteLayout.root + "tombstones/") {
            let current: (data: Data, etag: String)
            do {
                current = try await backend.get(object.key)
            } catch StorageError.notFound {
                continue
            }
            let legacy = RemoteLayout.legacyRoot + object.key.dropFirst(RemoteLayout.root.count)
            do {
                if try await backend.get(legacy).data == current.data { continue }
            } catch StorageError.notFound {}
            if try await exists(RemoteLayout.manifest(), in: backend) { return true }
            do {
                try await backend.delete(object.key, ifMatch: current.etag)
            } catch StorageError.notFound {
            } catch StorageError.preconditionFailed {}
        }
        return false
    }

    private static func tombstoneDeleted(_ tombstone: String, in backend: StorageBackend) async throws -> Bool {
        let current: Data
        do {
            current = try await backend.get(tombstone).data
        } catch StorageError.notFound {
            return false
        }
        // A byte-for-byte copy of a legacy tombstone records no deletion made under the new root.
        let legacy = RemoteLayout.legacyRoot + tombstone.dropFirst(RemoteLayout.root.count)
        do {
            return try await backend.get(legacy).data != current
        } catch StorageError.notFound {
            return true
        }
    }

    private enum CopyResult { case created(etag: String), replaced, skipped, storeMigrated }

    private static func copy(_ data: Data, to key: String, in backend: StorageBackend) async throws -> CopyResult {
        do {
            return .created(etag: try await backend.put(key, data: data, ifMatch: nil, ifNoneMatch: true))
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
            return .replaced
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
