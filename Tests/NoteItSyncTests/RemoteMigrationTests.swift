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
}
