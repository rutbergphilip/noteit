import CryptoKit
import XCTest
@testable import NoteItSync

/// Stores created by Inkwell live under `inkwell/v1/` and are copied to `noteit/v1/` on connect.
final class RemoteMigrationTests: XCTestCase {
    /// Moves every object under `noteit/v1/` to `inkwell/v1/`, as if Inkwell had written the store.
    static func moveToLegacyRoot(_ backend: InMemoryBackend) async throws {
        for object in try await backend.list(prefix: RemoteLayout.root) {
            let data = try await backend.get(object.key).data
            let legacyKey = RemoteLayout.legacyRoot + object.key.dropFirst(RemoteLayout.root.count)
            try await backend.put(legacyKey, data: data, ifMatch: nil, ifNoneMatch: false)
            try await backend.delete(object.key)
        }
    }

    private func legacyManifest(passphrase: String) throws -> Data {
        let salt = Data(repeating: 7, count: 16)
        let cipher = XORTestCipher(passphrase: passphrase, salt: salt)
        let check = try cipher.seal(SyncEngine.legacyKeyCheckPlaintext, context: SyncEngine.keyCheckContext)
        let manifest = Manifest(encryption: .init(salt: salt, iterations: SyncEngine.defaultIterations, keyCheck: check))
        return try SyncEngine.encode(manifest)
    }

    func testCopiesLegacyStoreAndLeavesItInPlace() async throws {
        let backend = InMemoryBackend()
        let manifest = try legacyManifest(passphrase: "pw")
        try await backend.put("inkwell/v1/manifest.json", data: manifest, ifMatch: nil, ifNoneMatch: true)
        try await backend.put("inkwell/v1/notes/a.meta", data: Data([1, 2]), ifMatch: nil, ifNoneMatch: true)
        try await backend.put("inkwell/v1/devices/mac.json", data: Data([3]), ifMatch: nil, ifNoneMatch: true)

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(backend, log: { _ in })
        XCTAssertTrue(migrated)

        let copied = try await backend.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertEqual(copied, ["noteit/v1/devices/mac.json", "noteit/v1/manifest.json", "noteit/v1/notes/a.meta"])
        let body = try await backend.get("noteit/v1/notes/a.meta").data
        XCTAssertEqual(body, Data([1, 2]))
        let newManifest = try await backend.get(RemoteLayout.manifest()).data
        XCTAssertEqual(newManifest, manifest)
        let legacy = try await backend.list(prefix: RemoteLayout.legacyRoot)
        XCTAssertEqual(legacy.count, 3)

        let again = try await RemoteMigration.migrateLegacyStoreIfNeeded(backend, log: { _ in })
        XCTAssertFalse(again)
    }

    func testConnectSessionOpensAnInkwellStore() async throws {
        let backend = InMemoryBackend()
        let manifest = try legacyManifest(passphrase: "pw")
        try await backend.put("inkwell/v1/manifest.json", data: manifest, ifMatch: nil, ifNoneMatch: true)
        let makeCipher: SyncEngine.CipherFactory = { passphrase, salt, _ in XORTestCipher(passphrase: passphrase, salt: salt) }

        let opened = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: .passphrase("pw"),
                                                         deviceName: "Mac", createIfMissing: false, encrypted: true,
                                                         makeCipher: makeCipher, now: Date())
        XCTAssertFalse(opened.created)
        let copied = try await backend.get(RemoteLayout.manifest()).data
        XCTAssertEqual(copied, manifest)

        let passed = XORTestCipher(passphrase: "pw", salt: Data(repeating: 7, count: 16))
        let withCipher = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: nil, deviceName: "Mac",
                                                             createIfMissing: false, encrypted: true, cipher: passed,
                                                             makeCipher: makeCipher, now: Date())
        XCTAssertEqual(withCipher.session.keyID, opened.session.keyID)

        do {
            _ = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: .passphrase("wrong"),
                                                    deviceName: "Mac", createIfMissing: false, encrypted: true,
                                                    makeCipher: makeCipher, now: Date())
            XCTFail("expected wrongPassphrase")
        } catch SyncError.wrongPassphrase {}
    }

    func testExistingNoteItStoreIsNotOverwritten() async throws {
        let backend = InMemoryBackend()
        try await backend.put("noteit/v1/manifest.json", data: Data("new".utf8), ifMatch: nil, ifNoneMatch: true)
        try await backend.put("inkwell/v1/manifest.json", data: Data("old".utf8), ifMatch: nil, ifNoneMatch: true)
        try await backend.put("inkwell/v1/notes/a.meta", data: Data([1]), ifMatch: nil, ifNoneMatch: true)

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(backend, log: { _ in })
        XCTAssertFalse(migrated)
        let keys = try await backend.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertEqual(keys, ["noteit/v1/manifest.json"])
    }

    func testEmptyRemoteIsLeftAlone() async throws {
        let backend = InMemoryBackend()
        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(backend, log: { _ in })
        XCTAssertFalse(migrated)
        let keys = try await backend.list(prefix: "")
        XCTAssertTrue(keys.isEmpty)
    }

    func testInterruptedCopyIsRedoneOnNextConnect() async throws {
        let backend = InMemoryBackend()
        try await backend.put("inkwell/v1/manifest.json", data: try legacyManifest(passphrase: "pw"), ifMatch: nil, ifNoneMatch: true)
        try await backend.put("inkwell/v1/notes/a.meta", data: Data([1]), ifMatch: nil, ifNoneMatch: true)
        try await backend.put("inkwell/v1/notes/b.meta", data: Data([2]), ifMatch: nil, ifNoneMatch: true)
        // A copy that stopped after the first object: no manifest under the new root yet.
        try await backend.put("noteit/v1/notes/a.meta", data: Data([1]), ifMatch: nil, ifNoneMatch: true)

        let (_, _, created) = try await SyncEngine.connectReportingCreation(
            backend: backend, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
        XCTAssertFalse(created, "a copied store is joined, not created")
        let keys = try await backend.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertEqual(keys, ["noteit/v1/manifest.json", "noteit/v1/notes/a.meta", "noteit/v1/notes/b.meta"])
    }

    func testLegacyKeyCheckStillVerifiesThePassphrase() async throws {
        let backend = InMemoryBackend()
        try await backend.put("inkwell/v1/manifest.json", data: try legacyManifest(passphrase: "pw"), ifMatch: nil, ifNoneMatch: true)

        do {
            _ = try await SyncEngine.connect(backend: backend, passphrase: "wrong", encryptNew: true, makeCipher: XORTestCipher.factory)
            XCTFail("wrong passphrase must be rejected")
        } catch SyncError.wrongPassphrase {}
        _ = try await SyncEngine.connect(backend: backend, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
    }

    func testNewStoresSealTheNoteItKeyCheck() async throws {
        let backend = InMemoryBackend()
        let (manifest, cipher) = try await SyncEngine.connect(backend: backend, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
        let check = try cipher.open(try XCTUnwrap(manifest.encryption).keyCheck, context: SyncEngine.keyCheckContext)
        XCTAssertEqual(check, Data("noteit-key-check".utf8))
    }

    private static func noteID(_ index: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", index) }

    private func seedLegacyStore(_ backend: InMemoryBackend, notes: Int) async throws -> [String: Data] {
        var objects = ["inkwell/v1/manifest.json": try legacyManifest(passphrase: "pw"), "inkwell/v1/devices/mac.json": Data([9])]
        for index in 0..<notes {
            objects["inkwell/v1/notes/\(Self.noteID(index)).meta"] = Data([UInt8(index), 1])
        }
        for (key, data) in objects {
            try await backend.put(key, data: data, ifMatch: nil, ifNoneMatch: true)
        }
        return objects
    }

    func testSlowerMigratorKeepsObjectsWrittenAfterTheFirstMigrationFinished() async throws {
        let inner = InMemoryBackend()
        _ = try await seedLegacyStore(inner, notes: 3)
        let newer = Data("edited on A".utf8)
        let deviceB = FaultyBackend(inner)
        // B has listed the legacy store; before its first write, A migrates and syncs an edit.
        await deviceB.onNextPut(keyContaining: RemoteLayout.root, .before({
            _ = try? await RemoteMigration.migrateLegacyStoreIfNeeded(inner, log: { _ in })
            _ = try? await inner.put("noteit/v1/notes/\(Self.noteID(1)).meta", data: newer, ifMatch: nil, ifNoneMatch: false)
        }))

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(deviceB, log: { _ in })
        XCTAssertTrue(migrated)
        let kept = try await inner.get("noteit/v1/notes/\(Self.noteID(1)).meta").data
        XCTAssertEqual(kept, newer)
    }

    func testInterruptedCopyResumesWithoutRewritingCopiedObjects() async throws {
        let inner = InMemoryBackend()
        let legacy = try await seedLegacyStore(inner, notes: 5)
        let flaky = FaultyBackend(inner)
        await flaky.failPuts(after: 2)
        do {
            try await RemoteMigration.migrateLegacyStoreIfNeeded(flaky, log: { _ in })
            XCTFail("expected the copy to be interrupted")
        } catch StorageError.network {}
        let partial = try await inner.list(prefix: RemoteLayout.root)
        XCTAssertEqual(partial.count, 2)
        XCTAssertFalse(partial.contains { $0.key == RemoteLayout.manifest() })

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(inner, log: { _ in })
        XCTAssertTrue(migrated)
        var copied: [String: Data] = [:]
        for object in try await inner.list(prefix: RemoteLayout.root) {
            copied[RemoteLayout.legacyRoot + object.key.dropFirst(RemoteLayout.root.count)] = try await inner.get(object.key).data
        }
        XCTAssertEqual(copied, legacy)
        let after = try await inner.list(prefix: RemoteLayout.root)
        for object in partial {
            XCTAssertEqual(after.first { $0.key == object.key }?.etag, object.etag, "\(object.key) was rewritten")
        }
    }

    func testCopyStopsOnceAnotherDeviceWritesTheManifest() async throws {
        let inner = InMemoryBackend()
        _ = try await seedLegacyStore(inner, notes: 60)
        let otherManifest = Data("written by another device".utf8)
        let flaky = FaultyBackend(inner)
        await flaky.onNextPut(keyContaining: "noteit/v1/notes/\(Self.noteID(5)).meta", .before({
            _ = try? await inner.put(RemoteLayout.manifest(), data: otherManifest, ifMatch: nil, ifNoneMatch: true)
        }))

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(flaky, log: { _ in })
        XCTAssertTrue(migrated)
        let copied = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        let expected = ["noteit/v1/devices/mac.json", "noteit/v1/manifest.json"] + (0...5).map { "noteit/v1/notes/\(Self.noteID($0)).meta" }
        XCTAssertEqual(copied, expected, "005 was created as the manifest appeared; an identical copy is kept, nothing after it")
        let manifest = try await inner.get(RemoteLayout.manifest()).data
        XCTAssertEqual(manifest, otherManifest)
    }

    func testSlowerMigratorDoesNotBringBackObjectsDeletedUnderTheNewRoot() async throws {
        let inner = InMemoryBackend()
        _ = try await seedLegacyStore(inner, notes: 10)
        let deviceB = FaultyBackend(inner)
        // B has checked for the manifest and is about to create 004; meanwhile A finishes, syncs and deletes 004.
        await deviceB.onNextPut(keyContaining: "noteit/v1/notes/\(Self.noteID(4)).meta", .before({
            _ = try? await RemoteMigration.migrateLegacyStoreIfNeeded(inner, log: { _ in })
            _ = try? await inner.put("noteit/v1/tombstones/\(Self.noteID(4)).json", data: Data("deleted on A".utf8), ifMatch: nil, ifNoneMatch: false)
            try? await inner.delete("noteit/v1/notes/\(Self.noteID(4)).meta")
        }))

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(deviceB, log: { _ in })
        XCTAssertTrue(migrated)
        let keys = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains("noteit/v1/notes/\(Self.noteID(4)).meta"), "a deleted note came back")
        XCTAssertTrue(keys.contains("noteit/v1/tombstones/\(Self.noteID(4)).json"))
        XCTAssertTrue(keys.contains("noteit/v1/notes/\(Self.noteID(3)).meta"), "an identical copy was rolled back")
    }

    func testSlowerMigratorKeepsCopiesTheFinishingMigratorSkipped() async throws {
        let inner = InMemoryBackend()
        let legacy = try await seedLegacyStore(inner, notes: 10)
        let deviceB = FaultyBackend(inner)
        // B creates 003; A then copies the rest, skips B's identical 003 and writes the manifest.
        await deviceB.onNextPut(keyContaining: "noteit/v1/notes/\(Self.noteID(3)).meta", .after({
            _ = try? await RemoteMigration.migrateLegacyStoreIfNeeded(inner, log: { _ in })
        }))

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(deviceB, log: { _ in })
        XCTAssertTrue(migrated)
        var copied: [String: Data] = [:]
        for object in try await inner.list(prefix: RemoteLayout.root) {
            copied[RemoteLayout.legacyRoot + object.key.dropFirst(RemoteLayout.root.count)] = try await inner.get(object.key).data
        }
        XCTAssertEqual(copied, legacy, "the migrated store lost an object")
    }

    func testRollbackKeepsObjectsChangedByAnotherDevice() async throws {
        let inner = InMemoryBackend()
        _ = try await seedLegacyStore(inner, notes: 10)
        let edited = Data("edited on A".utf8)
        let deviceB = FaultyBackend(inner)
        await deviceB.onNextPut(keyContaining: "noteit/v1/notes/\(Self.noteID(3)).meta", .after({
            _ = try? await inner.put(RemoteLayout.manifest(), data: Data("A".utf8), ifMatch: nil, ifNoneMatch: true)
            _ = try? await inner.put("noteit/v1/notes/\(Self.noteID(3)).meta", data: edited, ifMatch: nil, ifNoneMatch: false)
        }))

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(deviceB, log: { _ in })
        XCTAssertTrue(migrated)
        let kept = try await inner.get("noteit/v1/notes/\(Self.noteID(3)).meta").data
        XCTAssertEqual(kept, edited)
        let keys = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains("noteit/v1/notes/\(Self.noteID(4)).meta"), "the copy went on after the manifest appeared")
    }

    func testTombstoneLeftByAnInterruptedCopyDoesNotHideANoteRestoredSince() async throws {
        let inner = InMemoryBackend()
        let id = UUID().uuidString
        try await inner.put("inkwell/v1/manifest.json", data: try legacyManifest(passphrase: "pw"), ifMatch: nil, ifNoneMatch: true)
        try await inner.put("inkwell/v1/tombstones/\(id).json", data: Data("deleted".utf8), ifMatch: nil, ifNoneMatch: true)
        let record = InMemoryMigrationTombstoneRecord()
        let flaky = FaultyBackend(inner)
        await flaky.failPuts(after: 1)
        do {
            try await RemoteMigration.migrateLegacyStoreIfNeeded(flaky, record: record, log: { _ in })
            XCTFail("expected the copy to be interrupted")
        } catch StorageError.network {}
        let partial = try await inner.list(prefix: RemoteLayout.root)
        XCTAssertEqual(partial.map(\.key), ["noteit/v1/tombstones/\(id).json"])
        XCTAssertEqual(record.load(), ["noteit/v1/tombstones/\(id).json": Self.sha256(Data("deleted".utf8))])

        // An Inkwell device restores the note before the next attempt.
        try await inner.delete("inkwell/v1/tombstones/\(id).json")
        try await inner.put("inkwell/v1/notes/\(id).meta", data: Data("meta".utf8), ifMatch: nil, ifNoneMatch: true)
        try await inner.put("inkwell/v1/notes/\(id).body", data: Data("body".utf8), ifMatch: nil, ifNoneMatch: true)

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(inner, record: record, log: { _ in })
        XCTAssertTrue(migrated)
        let keys = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains("noteit/v1/tombstones/\(id).json"))
        let meta = try await inner.get("noteit/v1/notes/\(id).meta").data
        let body = try await inner.get("noteit/v1/notes/\(id).body").data
        XCTAssertEqual(meta, Data("meta".utf8))
        XCTAssertEqual(body, Data("body".utf8))
        XCTAssertEqual(record.load(), [:], "the record outlived the migration")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Restores note `id` under the legacy root, as an Inkwell device would.
    private func reviveLegacyNote(_ id: String, in backend: InMemoryBackend) async throws {
        try await backend.delete("inkwell/v1/tombstones/\(id).json")
        try await backend.put("inkwell/v1/notes/\(id).meta", data: Data("meta".utf8), ifMatch: nil, ifNoneMatch: true)
    }

    func testTombstonePutRightBeforeACrashIsStillCleanedUp() async throws {
        let inner = InMemoryBackend()
        let id = Self.noteID(5)
        let tombstone = "noteit/v1/tombstones/\(id).json"
        try await inner.put("inkwell/v1/manifest.json", data: try legacyManifest(passphrase: "pw"), ifMatch: nil, ifNoneMatch: true)
        try await inner.put("inkwell/v1/tombstones/\(id).json", data: Data("deleted".utf8), ifMatch: nil, ifNoneMatch: true)
        let record = InMemoryMigrationTombstoneRecord()
        let crashing = FaultyBackend(inner)
        // The tombstone is stored, but the device dies before learning so.
        await crashing.onNextPut(keyContaining: "tombstones/", .failAfter)
        do {
            try await RemoteMigration.migrateLegacyStoreIfNeeded(crashing, record: record, log: { _ in })
            XCTFail("expected the copy to be interrupted")
        } catch StorageError.network {}
        let leftover = try await inner.get(tombstone).data
        XCTAssertEqual(leftover, Data("deleted".utf8))

        try await reviveLegacyNote(id, in: inner)
        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(inner, record: record, log: { _ in })
        XCTAssertTrue(migrated)
        let keys = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains(tombstone), "the leftover tombstone was kept")
        let meta = try await inner.get("noteit/v1/notes/\(id).meta").data
        XCTAssertEqual(meta, Data("meta".utf8))
    }

    func testFileRecordOutlivesAnInterruptedCopyAcrossReconnects() async throws {
        let inner = InMemoryBackend()
        let id = Self.noteID(6)
        let tombstone = "noteit/v1/tombstones/\(id).json"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-migration-store.json")
        try await inner.put("inkwell/v1/manifest.json", data: try legacyManifest(passphrase: "pw"), ifMatch: nil, ifNoneMatch: true)
        try await inner.put("inkwell/v1/tombstones/\(id).json", data: Data("deleted".utf8), ifMatch: nil, ifNoneMatch: true)
        let flaky = FaultyBackend(inner)
        await flaky.failPuts(after: 1)
        do {
            try await RemoteMigration.migrateLegacyStoreIfNeeded(flaky, record: FileMigrationTombstoneRecord(url: url), log: { _ in })
            XCTFail("expected the copy to be interrupted")
        } catch StorageError.network {}

        try await reviveLegacyNote(id, in: inner)
        let reconnected = FileMigrationTombstoneRecord(url: url)
        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(inner, record: reconnected, log: { _ in })
        XCTAssertTrue(migrated)
        let keys = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains(tombstone), "the leftover tombstone was kept")
        XCTAssertTrue(keys.contains("noteit/v1/notes/\(id).meta"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the record outlived the migration")
    }

    func testTombstoneSyncedBeforeTheManifestHidesTheNote() async throws {
        let inner = InMemoryBackend()
        _ = try await seedLegacyStore(inner, notes: 3)
        let id = Self.noteID(1)
        try await inner.put("inkwell/v1/notes/\(id).body", data: Data("body".utf8), ifMatch: nil, ifNoneMatch: true)
        // A finished migrating and deleted the note; the sync tool delivered the tombstone here but not the manifest.
        let tombstone = "noteit/v1/tombstones/\(id).json"
        try await inner.put(tombstone, data: Data("deleted on A".utf8), ifMatch: nil, ifNoneMatch: true)

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(inner, log: { _ in })
        XCTAssertTrue(migrated)
        let kept = try await inner.get(tombstone).data
        XCTAssertEqual(kept, Data("deleted on A".utf8))
        let keys = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains("noteit/v1/notes/\(id).meta"), "a deleted note came back")
        XCTAssertFalse(keys.contains("noteit/v1/notes/\(id).body"), "a deleted note came back")
        XCTAssertTrue(keys.contains("noteit/v1/notes/\(Self.noteID(2)).meta"))
    }

    func testRecordedTombstoneRewrittenByAnotherDeviceIsKept() async throws {
        let inner = InMemoryBackend()
        let id = Self.noteID(4)
        let tombstone = "noteit/v1/tombstones/\(id).json"
        try await inner.put("inkwell/v1/manifest.json", data: try legacyManifest(passphrase: "pw"), ifMatch: nil, ifNoneMatch: true)
        try await inner.put("inkwell/v1/tombstones/\(id).json", data: Data("deleted".utf8), ifMatch: nil, ifNoneMatch: true)
        let record = InMemoryMigrationTombstoneRecord()
        let flaky = FaultyBackend(inner)
        await flaky.failPuts(after: 1)
        do {
            try await RemoteMigration.migrateLegacyStoreIfNeeded(flaky, record: record, log: { _ in })
            XCTFail("expected the copy to be interrupted")
        } catch StorageError.network {}
        XCTAssertEqual(Array(record.load().keys), [tombstone])

        // The note is restored under the legacy root, and another device deletes it again under the new one.
        try await inner.delete("inkwell/v1/tombstones/\(id).json")
        try await inner.put("inkwell/v1/notes/\(id).meta", data: Data("meta".utf8), ifMatch: nil, ifNoneMatch: true)
        try await inner.put(tombstone, data: Data("deleted on A".utf8), ifMatch: nil, ifNoneMatch: false)

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(inner, record: record, log: { _ in })
        XCTAssertTrue(migrated)
        let kept = try await inner.get(tombstone).data
        XCTAssertEqual(kept, Data("deleted on A".utf8))
        let keys = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains("noteit/v1/notes/\(id).meta"), "a deleted note came back")
    }

    func testRollbackCoversSyncToolDuplicatesOfADeletedNote() async throws {
        let inner = InMemoryBackend()
        _ = try await seedLegacyStore(inner, notes: 3)
        let id = Self.noteID(9)
        let duplicate = "noteit/v1/notes/\(id) 2.meta"
        try await inner.put("inkwell/v1/notes/\(id).meta", data: Data([9]), ifMatch: nil, ifNoneMatch: true)
        try await inner.put("inkwell/v1/notes/\(id) 2.meta", data: Data([9]), ifMatch: nil, ifNoneMatch: true)
        let deviceB = FaultyBackend(inner)
        // B is about to create the duplicate; meanwhile A finishes, syncs and deletes the note.
        await deviceB.onNextPut(keyContaining: duplicate, .before({
            _ = try? await RemoteMigration.migrateLegacyStoreIfNeeded(inner, log: { _ in })
            _ = try? await inner.put(RemoteLayout.tombstone(UUID(uuidString: id)!), data: Data("deleted on A".utf8), ifMatch: nil, ifNoneMatch: false)
            try? await inner.delete("noteit/v1/notes/\(id).meta")
            try? await inner.delete(duplicate)
        }))

        let migrated = try await RemoteMigration.migrateLegacyStoreIfNeeded(deviceB, log: { _ in })
        XCTAssertTrue(migrated)
        let keys = try await inner.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains(duplicate), "a duplicate of a deleted note came back")
        XCTAssertFalse(keys.contains("noteit/v1/notes/\(id).meta"))
    }
}
