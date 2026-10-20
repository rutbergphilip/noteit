import CryptoKit
import XCTest
@testable import NoteItSync

/// foundations Task 3.3: store sessions, connectSession, refreshedSession and the session-based engine.
final class StoreSessionTests: XCTestCase {
    private var dir: URL!
    private let pass = "correct horse battery staple"

    override func setUp() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dir = root.appendingPathComponent(".build/store-session-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private let noCipherBuilt: SyncEngine.CipherFactory = { _, _, _ in
        XCTFail("no legacy cipher may be built")
        return TestPassthroughCipher()
    }

    private func connect(_ backend: StorageBackend, _ credential: StoreCredential?, deviceName: String = "Test Mac",
                         create: Bool = true, encrypted: Bool = true, initial: Set<StoreFeature> = [],
                         supported: Set<StoreFeature> = StoreFeature.supported, cipher: (any SyncCipher)? = nil,
                         makeCipher: SyncEngine.CipherFactory = XORTestCipher.factory) async throws -> (session: StoreSession, created: Bool) {
        try await SyncEngine.connectSession(backend: backend, kind: .library, credential: credential, deviceName: deviceName,
                                            createIfMissing: create, encrypted: encrypted, initialFeatures: initial,
                                            supported: supported, cipher: cipher, makeCipher: makeCipher, now: Date())
    }

    private func assertThrows<T>(_ expected: SyncError, _ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SyncError, expected, file: file, line: line)
        }
    }

    private func assertInvalidManifest<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected invalidManifest", file: file, line: line)
        } catch SyncError.invalidManifest {
        } catch {
            XCTFail("expected invalidManifest, got \(error)", file: file, line: line)
        }
    }

    private func snapshot(_ backend: InMemoryBackend) async throws -> [String: Data] {
        var result: [String: Data] = [:]
        for object in try await backend.list(prefix: "") { result[object.key] = try await backend.get(object.key).data }
        return result
    }

    private func manifest(_ backend: StorageBackend) async throws -> Manifest {
        try SyncEngine.decode(Manifest.self, from: try await backend.get(RemoteLayout.manifest()).data)
    }

    private func putManifest(_ manifest: Manifest, _ backend: StorageBackend) async throws {
        try await backend.put(RemoteLayout.manifest(), data: try SyncEngine.encode(manifest), ifMatch: nil, ifNoneMatch: false)
    }

    private func engine(_ backend: StorageBackend, _ ref: StoreSessionRef, _ store: FakeLocalStore, id: String,
                        appVersion: String? = nil, platform: DevicePlatform? = nil) -> SyncEngine {
        let url = dir.appendingPathComponent("\(id).json")
        if let platform {
            return SyncEngine(backend: backend, session: ref, local: store, stateURL: url, deviceID: id, deviceName: id,
                              appVersion: appVersion, platform: platform)
        }
        return SyncEngine(backend: backend, session: ref, local: store, stateURL: url, deviceID: id, deviceName: id, appVersion: appVersion)
    }

    private func deviceRecord(_ backend: StorageBackend, _ session: StoreSession, id: String) async throws -> [String: Any] {
        let key = RemoteLayout.device(id)
        let sealed = try await backend.get(key).data
        let plain = try session.cipher.open(sealed, context: SyncEngine.context(key))
        return try JSONSerialization.jsonObject(with: plain) as! [String: Any]
    }

    private func dataOf(_ key: SymmetricKey?) -> Data? { key.map { $0.withUnsafeBytes { Data($0) } } }

    /// A v1 encrypted store whose manifest also carries the keyring feature (a change that stopped before the keyring).
    private func keyringPendingStore() async throws -> InMemoryBackend {
        let backend = InMemoryBackend()
        _ = try await connect(backend, .passphrase(pass))
        var m = try await manifest(backend)
        m.formatVersion = 2
        m.features = ["keyring"]
        try await putManifest(m, backend)
        return backend
    }

    // MARK: connectSession

    func testConnectV1ReturnsLegacyKeyID() async throws {
        let backend = InMemoryBackend()
        let created = try await connect(backend, .passphrase(pass))
        XCTAssertTrue(created.created)
        let stored = try await manifest(backend)
        let encryption = try XCTUnwrap(stored.encryption)
        XCTAssertEqual(created.session.keyID, KeyIdentity.legacyKeyID(encryption))
        let opened = try await connect(backend, .passphrase(pass))
        XCTAssertFalse(opened.created)
        XCTAssertEqual(opened.session.keyID, KeyIdentity.legacyKeyID(encryption))
        XCTAssertEqual(opened.session.kind, .library)
        XCTAssertEqual(opened.session.features, [])
        XCTAssertFalse(opened.session.manifestETag.isEmpty)
        XCTAssertFalse(opened.session.manifestETag.hasPrefix("\""))
        let etag = try await backend.get(RemoteLayout.manifest()).etag
        XCTAssertEqual(opened.session.manifestETag, etag)
        await assertThrows(.wrongPassphrase) { try await self.connect(backend, .passphrase("nope")) }
    }

    func testConnectPlainHasNoKeyID() async throws {
        let backend = InMemoryBackend()
        let (session, created) = try await connect(backend, nil, encrypted: false)
        XCTAssertTrue(created)
        XCTAssertNil(session.keyID)
        XCTAssertNil(session.dataKey)
        XCTAssertTrue(session.cipher is PassthroughCipher)
        let reopened = try await connect(backend, nil, encrypted: false).session
        XCTAssertNil(reopened.keyID)
        await assertThrows(.encryptionMismatch) { try await self.connect(backend, .passphrase(self.pass)) }
    }

    func testDataKeyCredentialMustMatch() async throws {
        let backend = InMemoryBackend()
        let created = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: .passphrase(pass),
                                                          deviceName: "Test Mac", createIfMissing: true, encrypted: true,
                                                          initialFeatures: [.keyring]).session
        let key = try XCTUnwrap(created.dataKey)
        let opened = try await connect(backend, .dataKey(key), makeCipher: noCipherBuilt).session
        XCTAssertEqual(opened.keyID, created.keyID)
        await assertThrows(.wrongPassphrase) { try await self.connect(backend, .dataKey(SymmetricKey(size: .bits256))) }

        let v1 = InMemoryBackend()
        _ = try await connect(v1, .passphrase(pass))
        await assertThrows(.wrongPassphrase) { try await self.connect(v1, .dataKey(key)) }
    }

    func testNewStoreIsV1WithoutFeatures() async throws {
        for encrypted in [false, true] {
            let backend = InMemoryBackend()
            let session = try await connect(backend, encrypted ? .passphrase(pass) : nil, encrypted: encrypted).session
            let m = try await manifest(backend)
            XCTAssertEqual(m.formatVersion, 1)
            XCTAssertNil(m.features)
            XCTAssertNil(m.keyring)
            XCTAssertEqual(m.encryption != nil, encrypted)
            XCTAssertEqual(session.formatVersion, 1)
            let raw = try await backend.get(RemoteLayout.manifest()).data
            XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("features"))
        }
    }

    func testInitialFeaturesOnlyOnCreation() async throws {
        let wide = StoreFeature.supported.union([.noteItDoc])
        let backend = InMemoryBackend()
        let created = try await connect(backend, nil, encrypted: false, initial: [.noteItDoc], supported: wide)
        XCTAssertTrue(created.created)
        let m = try await manifest(backend)
        XCTAssertEqual(m.formatVersion, 2)
        XCTAssertEqual(m.features, ["noteit-doc"])
        XCTAssertEqual(created.session.features, [.noteItDoc])
        XCTAssertEqual(created.session.supported, wide)

        let v1 = InMemoryBackend()
        _ = try await connect(v1, .passphrase(pass))
        let before = try await snapshot(v1)
        let opened = try await connect(v1, .passphrase(pass), initial: [.noteItDoc], supported: wide)
        XCTAssertFalse(opened.created)
        XCTAssertEqual(opened.session.features, [])
        let after = try await snapshot(v1)
        XCTAssertEqual(after, before)

        let empty = InMemoryBackend()
        await assertInvalidManifest {
            try await self.connect(empty, nil, encrypted: false, initial: [.lockedNotes], supported: Set(StoreFeature.allCases))
        }
        await assertInvalidManifest { try await self.connect(empty, nil, encrypted: false, initial: [.noteItDoc]) }
        let left = try await snapshot(empty)
        XCTAssertTrue(left.isEmpty)
    }

    func testPassedCipherIsUsed() async throws {
        let backend = InMemoryBackend()
        let passed = XORTestCipher(passphrase: "space key", salt: Data([1]))
        let created = try await connect(backend, nil, cipher: passed, makeCipher: noCipherBuilt)
        XCTAssertTrue(created.created)
        XCTAssertTrue(created.session.cipher is XORTestCipher)
        XCTAssertNil(created.session.dataKey)
        let m = try await manifest(backend)
        XCTAssertNil(m.keyring)
        let check = try XCTUnwrap(m.encryption).keyCheck
        XCTAssertEqual(try passed.open(check, context: SyncEngine.keyCheckContext), SyncEngine.keyCheckPlaintext)

        let store = FakeLocalStore()
        let id = await store.create(title: "sealed")
        _ = try await engine(backend, StoreSessionRef(created.session), store, id: "A").sync()
        let key = RemoteLayout.root + "notes/\(id.uuidString).meta"
        let sealed = try await backend.get(key).data
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: try passed.open(sealed, context: SyncEngine.context(key))))
        XCTAssertNil(try? JSONSerialization.jsonObject(with: sealed))

        await assertInvalidManifest { try await self.connect(InMemoryBackend(), nil, encrypted: false, cipher: passed) }
    }

    func testPassedCipherKeyCheckRoundTrip() async throws {
        let backend = InMemoryBackend()
        let passed = XORTestCipher(passphrase: "space key", salt: Data([1]))
        _ = try await connect(backend, nil, cipher: passed, makeCipher: noCipherBuilt)
        let reopened = try await connect(backend, nil, cipher: passed, makeCipher: noCipherBuilt)
        XCTAssertFalse(reopened.created)
        let before = try await snapshot(backend)
        await assertThrows(.wrongPassphrase) {
            try await self.connect(backend, nil, cipher: XORTestCipher(passphrase: "other key", salt: Data([1])), makeCipher: self.noCipherBuilt)
        }
        let after = try await snapshot(backend)
        XCTAssertEqual(after, before)
        // Ordinary Sync pointed at that store fails safely.
        await assertThrows(.wrongPassphrase) { try await self.connect(backend, .passphrase(self.pass)) }
    }

    func testCreateKeyringStore() async throws {
        let backend = InMemoryBackend()
        let created = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: .passphrase(pass),
                                                          deviceName: "Test Mac", createIfMissing: true, encrypted: true,
                                                          initialFeatures: [.keyring])
        XCTAssertTrue(created.created)
        let m = try await manifest(backend)
        XCTAssertEqual(m.formatVersion, 2)
        XCTAssertEqual(m.features, ["keyring"])
        XCTAssertNil(m.encryption)
        let keyring = try XCTUnwrap(m.keyring)
        XCTAssertEqual(keyring.changedBy, "Test Mac")
        XCTAssertEqual(keyring.iterations, Keyring.defaultIterations)
        XCTAssertEqual(created.session.keyID, keyring.keyID)

        let a = FakeLocalStore()
        let id = await a.create(title: "keyring note")
        _ = try await engine(backend, StoreSessionRef(created.session), a, id: "A").sync()

        let reopened = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: .passphrase(pass),
                                                           deviceName: "Other Mac", createIfMissing: false, encrypted: true)
        XCTAssertFalse(reopened.created)
        XCTAssertEqual(reopened.session.keyID, keyring.keyID)
        let b = FakeLocalStore()
        _ = try await engine(backend, StoreSessionRef(reopened.session), b, id: "B").sync()
        let title = await b.title(id)
        XCTAssertEqual(title, "keyring note")

        await assertInvalidManifest {
            try await self.connect(InMemoryBackend(), nil, encrypted: false, initial: [.keyring])
        }
    }

    func testKeyringCreateRejectsEmptyPassphrase() async throws {
        let backend = InMemoryBackend()
        await assertThrows(.passphraseRequired) {
            try await self.connect(backend, .passphrase(""), initial: [.keyring], makeCipher: self.noCipherBuilt)
        }
        let left = try await snapshot(backend)
        XCTAssertTrue(left.isEmpty)
    }

    func testKeyringCreateRequiresDeviceName() async throws {
        let backend = InMemoryBackend()
        await assertInvalidManifest {
            try await self.connect(backend, .passphrase(self.pass), deviceName: "", initial: [.keyring], makeCipher: self.noCipherBuilt)
        }
        let left = try await snapshot(backend)
        XCTAssertTrue(left.isEmpty)
        _ = try await connect(backend, .passphrase(pass), deviceName: "Test Mac", initial: [.keyring])
        let m = try await manifest(backend)
        XCTAssertEqual(m.keyring?.changedBy, "Test Mac")
    }

    func testSessionDataKey() async throws {
        let backend = InMemoryBackend()
        let created = try await connect(backend, .passphrase(pass), initial: [.keyring]).session
        let key = try XCTUnwrap(created.dataKey)
        XCTAssertEqual(KeyIdentity.keyID(for: key), created.keyID)
        let byPassphrase = try await connect(backend, .passphrase(pass)).session
        let byKey = try await connect(backend, .dataKey(key)).session
        XCTAssertEqual(dataOf(byPassphrase.dataKey), dataOf(key))
        XCTAssertEqual(dataOf(byKey.dataKey), dataOf(key))

        let v1 = InMemoryBackend()
        let others = [
            try await connect(v1, .passphrase(pass)).session,
            try await connect(v1, .passphrase(pass)).session,
            try await connect(try await keyringPendingStore(), .passphrase(pass)).session,
            try await connect(InMemoryBackend(), nil, encrypted: false).session,
            try await connect(InMemoryBackend(), nil, cipher: XORTestCipher(passphrase: "s", salt: Data())).session,
        ]
        for session in others { XCTAssertNil(session.dataKey) }
    }

    func testConnectKeyringStoreWithDefaultSupported() async throws {
        XCTAssertEqual(StoreFeature.supported, [.keyring])
        let backend = InMemoryBackend()
        _ = try await connect(backend, .passphrase(pass), initial: [.keyring])
        let session = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: .passphrase(pass),
                                                          deviceName: "Test Mac", createIfMissing: false, encrypted: true).session
        XCTAssertEqual(session.features, [.keyring])
        XCTAssertEqual(session.supported, [.keyring])
        // The legacy wrapper opens it too.
        let (manifest, _) = try await SyncEngine.connect(backend: backend, passphrase: pass, encryptNew: true)
        XCTAssertNotNil(manifest.keyring)
        await assertThrows(.passphraseRequired) { try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false) }
    }

    func testKeyringPendingOpensAsV1() async throws {
        let backend = try await keyringPendingStore()
        let before = try await snapshot(backend)
        let session = try await connect(backend, .passphrase(pass)).session
        let stored = try await manifest(backend)
        let encryption = try XCTUnwrap(stored.encryption)
        XCTAssertEqual(session.keyID, KeyIdentity.legacyKeyID(encryption))
        XCTAssertEqual(session.features, [.keyring])
        let after = try await snapshot(backend)
        XCTAssertEqual(after, before)
        await assertThrows(.wrongPassphrase) { try await self.connect(backend, .passphrase("nope")) }
    }

    func testKeyringFeatureWithoutAnyKeyIsInvalid() async throws {
        let backend = InMemoryBackend()
        try await putManifest(Manifest(formatVersion: 2, features: ["keyring"]), backend)
        let before = try await snapshot(backend)
        await assertInvalidManifest { try await self.connect(backend, .passphrase(self.pass)) }
        await assertInvalidManifest { try await self.connect(backend, nil, encrypted: false) }
        let after = try await snapshot(backend)
        XCTAssertEqual(after, before)
    }

    func testLibrarySessionRefusesSpaceFeature() async throws {
        let backend = InMemoryBackend()
        try await putManifest(Manifest(formatVersion: 2, features: ["noteit-space"]), backend)
        await assertThrows(.unsupportedFeature("noteit-space")) { try await self.connect(backend, nil, encrypted: false) }
        let session = try await connect(backend, nil, encrypted: false, supported: StoreFeature.supported.union([.noteItSpace])).session
        XCTAssertEqual(session.features, [.noteItSpace])
    }

    // MARK: refreshedSession

    func testRefreshKeepsSessionWhenOnlyETagChanged() async throws {
        let backend = InMemoryBackend()
        let session = try await connect(backend, .passphrase(pass), initial: [.keyring]).session
        try await putManifest(try await manifest(backend), backend)
        let refreshed = try await SyncEngine.refreshedSession(backend: backend, current: session, credential: nil)
        XCTAssertNotEqual(refreshed.manifestETag, session.manifestETag)
        XCTAssertEqual(refreshed.keyID, session.keyID)
        XCTAssertEqual(refreshed.supported, session.supported)
        XCTAssertEqual(dataOf(refreshed.dataKey), dataOf(session.dataKey))

        let space = InMemoryBackend()
        let spaceSupported = StoreFeature.supported.union([.noteItSpace])
        let passed = XORTestCipher(passphrase: "space key", salt: Data([2]))
        let spaceSession = try await connect(space, nil, initial: [.noteItSpace], supported: spaceSupported, cipher: passed).session
        try await putManifest(try await manifest(space), space)
        let refreshedSpace = try await SyncEngine.refreshedSession(backend: space, current: spaceSession, credential: nil)
        XCTAssertEqual(refreshedSpace.supported, spaceSupported)
        XCTAssertEqual(refreshedSpace.features, [.noteItSpace])
        XCTAssertTrue(refreshedSpace.cipher is XORTestCipher)
    }

    func testRefreshThrowsKeyChanged() async throws {
        let backend = InMemoryBackend()
        let session = try await connect(backend, .passphrase(pass), initial: [.keyring]).session
        var m = try await manifest(backend)
        m.keyring = try Keyring.make(dataKey: SymmetricKey(size: .bits256), passphrase: "new", deviceName: "Other Mac",
                                     now: Date(), iterations: 100_000)
        try await putManifest(m, backend)
        await assertThrows(.keyChanged(byDevice: "Other Mac")) {
            try await SyncEngine.refreshedSession(backend: backend, current: session, credential: nil)
        }
    }

    func testRefreshThrowsRekeyInProgress() async throws {
        let backend = InMemoryBackend()
        let session = try await connect(backend, .passphrase(pass)).session
        var m = try await manifest(backend)
        m.rekey = Rekey(fromKeyID: session.keyID, toKeyID: "0123456789abcdef", startedAt: Date(), updatedAt: Date(),
                        deviceID: "OTHER", deviceName: "Other Mac")
        try await putManifest(m, backend)
        await assertThrows(.rekeyInProgress(deviceName: "Other Mac")) {
            try await SyncEngine.refreshedSession(backend: backend, current: session, credential: nil)
        }
    }

    func testStaleRekeyReportsIncomplete() async throws {
        let backend = InMemoryBackend()
        let session = try await connect(backend, .passphrase(pass)).session
        var m = try await manifest(backend)
        let old = Date().addingTimeInterval(-Rekey.staleAfter - 1)
        m.rekey = Rekey(fromKeyID: session.keyID, toKeyID: "0123456789abcdef", startedAt: old, updatedAt: old,
                        deviceID: "OTHER", deviceName: "Other Mac")
        try await putManifest(m, backend)
        await assertThrows(.rekeyIncomplete(done: 0, total: 0)) {
            try await SyncEngine.refreshedSession(backend: backend, current: session, credential: nil)
        }
    }

    // MARK: Engine

    func testRunningEngineSeesNewFeature() async throws {
        let backend = InMemoryBackend()
        let wide = StoreFeature.supported.union([.noteItDoc])
        let ref = StoreSessionRef(try await connect(backend, nil, encrypted: false, supported: wide).session)
        let engine = engine(backend, ref, FakeLocalStore(), id: "A")
        _ = try await engine.sync()
        XCTAssertEqual(ref.current.features, [])

        var m = try await manifest(backend)
        m.formatVersion = 2
        m.features = ["noteit-doc"]
        try await putManifest(m, backend)
        _ = try await engine.sync()
        XCTAssertEqual(ref.current.features, [.noteItDoc])
        let etag = try await backend.get(RemoteLayout.manifest()).etag
        XCTAssertEqual(ref.current.manifestETag, etag)
        XCTAssertEqual(SyncState.load(from: dir.appendingPathComponent("A.json")).keyID, nil)
    }

    func testEngineRecordsKeyIDAndStopsOnKeyChange() async throws {
        let backend = InMemoryBackend()
        let ref = StoreSessionRef(try await connect(backend, .passphrase(pass), initial: [.keyring]).session)
        let store = FakeLocalStore()
        let engine = engine(backend, ref, store, id: "A")
        _ = await store.create(title: "one")
        _ = try await engine.sync()
        XCTAssertEqual(SyncState.load(from: dir.appendingPathComponent("A.json")).keyID, ref.current.keyID)

        var m = try await manifest(backend)
        m.keyring = try Keyring.make(dataKey: SymmetricKey(size: .bits256), passphrase: "new", deviceName: "Other Mac",
                                     now: Date(), iterations: 100_000)
        try await putManifest(m, backend)
        _ = await store.create(title: "two")
        let before = try await snapshot(backend)
        await assertThrows(.keyChanged(byDevice: "Other Mac")) { try await engine.sync() }
        let after = try await snapshot(backend)
        XCTAssertEqual(after, before, "nothing is sealed with the old key after the key changed")
    }

    /// A store whose manifest carries a rekey by `deviceID`, and a session opened after it was set.
    private func rekeyingStore(deviceID: String, updatedAt: Date) async throws -> (InMemoryBackend, StoreSession) {
        let backend = InMemoryBackend()
        let first = try await connect(backend, .passphrase(pass)).session
        var m = try await manifest(backend)
        m.rekey = Rekey(fromKeyID: first.keyID, toKeyID: "0123456789abcdef", startedAt: updatedAt, updatedAt: updatedAt,
                        deviceID: deviceID, deviceName: "\(deviceID) Mac")
        try await putManifest(m, backend)
        return (backend, try await connect(backend, .passphrase(pass), create: false).session)
    }

    func testFreshSessionStopsOnForeignRekey() async throws {
        let (backend, session) = try await rekeyingStore(deviceID: "OTHER", updatedAt: Date())
        let store = FakeLocalStore()
        _ = await store.create(title: "one")
        let engine = engine(backend, StoreSessionRef(session), store, id: "A")
        let before = try await snapshot(backend)
        await assertThrows(.rekeyInProgress(deviceName: "OTHER Mac")) { try await engine.sync() }
        await assertThrows(.rekeyInProgress(deviceName: "OTHER Mac")) { try await engine.sync() }
        let after = try await snapshot(backend)
        XCTAssertEqual(after, before, "nothing is written while another device rekeys")
    }

    func testFreshSessionReportsStaleForeignRekey() async throws {
        let (backend, session) = try await rekeyingStore(deviceID: "OTHER", updatedAt: Date().addingTimeInterval(-Rekey.staleAfter - 1))
        let store = FakeLocalStore()
        _ = await store.create(title: "one")
        let before = try await snapshot(backend)
        await assertThrows(.rekeyIncomplete(done: 0, total: 0)) {
            try await self.engine(backend, StoreSessionRef(session), store, id: "A").sync()
        }
        let after = try await snapshot(backend)
        XCTAssertEqual(after, before)
    }

    func testOwnRekeyDoesNotStopPass() async throws {
        let (backend, session) = try await rekeyingStore(deviceID: "A", updatedAt: Date())
        let store = FakeLocalStore()
        let note = await store.create(title: "one")
        _ = try await engine(backend, StoreSessionRef(session), store, id: "A").sync()
        let keys = try await backend.list(prefix: "").map(\.key)
        XCTAssertTrue(keys.contains(RemoteLayout.meta(.note, note)))
    }

    func testAdoptedSessionStopsOnForeignRekey() async throws {
        let backend = InMemoryBackend()
        _ = try await connect(backend, nil, encrypted: false)
        var m = try await manifest(backend)
        m.rekey = Rekey(fromKeyID: nil, toKeyID: "0123456789abcdef", startedAt: Date(), updatedAt: Date(),
                        deviceID: "OTHER", deviceName: "Other Mac")
        try await putManifest(m, backend)
        let store = FakeLocalStore()
        _ = await store.create(title: "one")
        let engine = SyncEngine(backend: backend, cipher: PassthroughCipher(), local: store,
                                stateURL: dir.appendingPathComponent("A.json"), deviceID: "A", deviceName: "A")
        let before = try await snapshot(backend)
        await assertThrows(.rekeyInProgress(deviceName: "Other Mac")) { try await engine.sync() }
        let after = try await snapshot(backend)
        XCTAssertEqual(after, before)
    }

    func testBodyEncodingFollowsFeatureNotVersion() async throws {
        let backend = InMemoryBackend()
        let keyringSession = try await connect(backend, .passphrase(pass), initial: [.keyring]).session
        XCTAssertEqual(keyringSession.formatVersion, 2)
        XCTAssertEqual(keyringSession.bodyEncoding, .rtfd)
        let doc = StoreSession(kind: .library, manifest: Manifest(formatVersion: 2, features: ["noteit-doc"]), manifestETag: "e",
                               cipher: PassthroughCipher(), keyID: nil, features: [.noteItDoc], supported: [.noteItDoc], dataKey: nil)
        XCTAssertEqual(doc.bodyEncoding, .noteItDocV1)
    }

    func testDeviceWritesSupportedFeatures() async throws {
        let backend = InMemoryBackend()
        let session = try await connect(backend, nil, encrypted: false).session
        _ = try await engine(backend, StoreSessionRef(session), FakeLocalStore(), id: "A", appVersion: "1.2.3").sync()
        let json = try await deviceRecord(backend, session, id: "A")
        XCTAssertEqual(json["supportedFeatures"] as? [String], ["keyring"])
        XCTAssertEqual(json["appVersion"] as? String, "1.2.3")
    }

    func testDevicePlatformDefaultsToMac() async throws {
        let backend = InMemoryBackend()
        let session = try await connect(backend, nil, encrypted: false).session
        _ = try await engine(backend, StoreSessionRef(session), FakeLocalStore(), id: "A").sync()
        let json = try await deviceRecord(backend, session, id: "A")
        XCTAssertEqual(json["platform"] as? String, "mac")
    }

    func testDevicePlatformFromInit() async throws {
        let backend = InMemoryBackend()
        let session = try await connect(backend, nil, encrypted: false).session
        _ = try await engine(backend, StoreSessionRef(session), FakeLocalStore(), id: "P", platform: .ios).sync()
        let json = try await deviceRecord(backend, session, id: "P")
        XCTAssertEqual(json["platform"] as? String, "ios")
    }
}
