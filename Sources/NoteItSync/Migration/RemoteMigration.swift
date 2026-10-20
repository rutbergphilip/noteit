import CryptoKit
import Foundation

/// Copies a remote store written under Inkwell's prefix (`inkwell/v1/`) to `noteit/v1/` the first time a
/// device connects to it. Objects are copied byte for byte: cipher contexts are relative to the root, so
/// sealed objects stay valid. The manifest goes last, so an interrupted copy is never mistaken for a
/// complete store and is simply resumed on the next connect. The legacy objects are left in place.
///
/// Several devices may migrate at once, and once one of them writes the manifest it starts syncing under
/// the new root. So objects are only created, never blindly replaced, and the manifest is checked before
/// every create. Once it appears the copy stops. A note or notebook deleted under the new root keeps its
/// tombstone (written before its meta and body are deleted), so its objects are not created while one exists,
/// and those created since the last check that saw no manifest are deleted again (unless changed since).
/// Other copies are kept: they are identical to what the finishing device copied or skipped. A sync tool may
/// deliver another device's tombstones before the manifest, so the only tombstones removed before copying are
/// ones this device's earlier attempt created (per `record`, still holding the etag that put returned) that no
/// longer match the legacy ones. A crash between such a create and saving its etag leaves a tombstone treated as foreign.
public enum RemoteMigration {
    /// Returns whether a legacy store was copied, by this device or another one during the copy.
    /// Does nothing when `noteit/v1/` already has a manifest.
    /// record: the tombstones this device's attempts put; cleared once the store is migrated.
    @discardableResult
    public static func migrateLegacyStoreIfNeeded(_ backend: StorageBackend,
                                                  record: MigrationTombstoneRecord = InMemoryMigrationTombstoneRecord(),
                                                  log: (String) -> Void = { NSLog("%@", $0) }) async throws -> Bool {
        if try await exists(RemoteLayout.manifest(), in: backend) {
            if !record.load().isEmpty { try? record.save([:]) }
            return false
        }
        let legacyManifest = RemoteLayout.legacyRoot + "manifest.json"
        let objects = try await backend.list(prefix: RemoteLayout.legacyRoot)
        guard objects.contains(where: { $0.key == legacyManifest }) else { return false }

        var recorded = record.load()
        func finished() -> Bool {
            try? record.save([:])
            return true
        }
        if try await removeStaleTombstones(&recorded, in: backend) {
            log("NoteItSync: another device finished copying \(RemoteLayout.legacyRoot) first")
            return finished()
        }
        try record.save(recorded)

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
            if try await manifestAppeared() { return finished() }
            let tombstone = tombstoneKey(for: key)
            if let tombstone, try await foreignTombstone(tombstone, recorded: recorded, in: backend) { continue }
            let isTombstone = key.hasPrefix(RemoteLayout.root + "tombstones/")
            var owned: String?
            if isTombstone {
                let digest = sha256(data)
                if case .confirmed(let etag, let hash) = recorded[key] {
                    if hash == digest, try await currentEtag(key, in: backend) == etag { continue }
                    owned = etag
                } else if recorded[key] != .pending(hash: digest) {
                    recorded[key] = .pending(hash: digest)
                    try record.save(recorded)
                }
            }
            let result = try await copy(data, to: key, in: backend)
            if isTombstone {
                switch result {
                case .created(let etag):
                    recorded[key] = .confirmed(etag: etag, hash: sha256(data))
                case .replaced(let etag, let previous) where owned != nil && previous == owned:
                    recorded[key] = .confirmed(etag: etag, hash: sha256(data))
                default:
                    recorded[key] = nil
                }
                try record.save(recorded)
            }
            switch result {
            case .created(let etag):
                if let tombstone { unconfirmed.append((key, etag, tombstone)) }
                copied += 1
            case .replaced: copied += 1
            case .skipped: break
            case .storeMigrated:
                log("NoteItSync: another device finished copying \(RemoteLayout.legacyRoot) first")
                return finished()
            }
        }
        if try await manifestAppeared() { return finished() }
        do {
            let manifest = try await backend.get(legacyManifest).data
            try await backend.put(RemoteLayout.manifest(), data: manifest, ifMatch: nil, ifNoneMatch: true)
        } catch StorageError.preconditionFailed {
            return finished()  // Another device finished the same copy first.
        }
        log("NoteItSync: copied \(copied) object(s) from \(RemoteLayout.legacyRoot) to \(RemoteLayout.root)")
        return finished()
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

    /// Deletes this device's owned tombstones that no longer match their legacy copy, and drops pending entries and
    /// those gone or rewritten since from `recorded`. Returns whether the manifest appeared, which ends the cleanup.
    private static func removeStaleTombstones(_ recorded: inout [String: MigrationTombstoneEntry],
                                              in backend: StorageBackend) async throws -> Bool {
        for (key, entry) in recorded.sorted(by: { $0.key < $1.key }) {
            guard case .confirmed(let etag, _) = entry else {
                recorded[key] = nil
                continue
            }
            let current: Data
            do {
                let object = try await backend.get(key)
                guard object.etag == etag else {
                    recorded[key] = nil
                    continue
                }
                current = object.data
            } catch StorageError.notFound {
                recorded[key] = nil
                continue
            }
            let legacy = RemoteLayout.legacyRoot + key.dropFirst(RemoteLayout.root.count)
            do {
                if try await backend.get(legacy).data == current { continue }
            } catch StorageError.notFound {}
            if try await exists(RemoteLayout.manifest(), in: backend) { return true }
            do {
                try await backend.delete(key, ifMatch: etag)
            } catch StorageError.notFound {
            } catch StorageError.preconditionFailed {}
            recorded[key] = nil
        }
        return false
    }

    /// Whether `tombstone` exists and isn't one this device created and nobody rewrote since, which hides the record.
    private static func foreignTombstone(_ tombstone: String, recorded: [String: MigrationTombstoneEntry],
                                         in backend: StorageBackend) async throws -> Bool {
        do {
            let current = try await backend.get(tombstone).etag
            guard case .confirmed(let etag, _) = recorded[tombstone] else { return true }
            return etag != current
        } catch StorageError.notFound {
            return false
        }
    }

    private static func currentEtag(_ key: String, in backend: StorageBackend) async throws -> String? {
        do {
            return try await backend.get(key).etag
        } catch StorageError.notFound {
            return nil
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// `replaced` carries the new etag and the one the replacement was conditioned on.
    private enum CopyResult { case created(etag: String), replaced(etag: String, previous: String), skipped, storeMigrated }

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
            let etag = try await backend.put(key, data: data, ifMatch: existing.etag, ifNoneMatch: false)
            return .replaced(etag: etag, previous: existing.etag)
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
