import XCTest
@testable import NoteItSync

/// foundations Task 3.1: manifest fields, the version and feature gate, device and state fields.
final class ManifestFeatureTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dir = root.appendingPathComponent(".build/manifest-feature-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func manifest(_ json: String) throws -> Manifest {
        try SyncEngine.decode(Manifest.self, from: Data(json.utf8))
    }

    private func assertThrows(_ expected: SyncError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? SyncError, expected, file: file, line: line)
        }
    }

    func testV1ManifestRoundTripsUnchanged() throws {
        struct Case: Codable { var name: String; var manifestJSON: String }
        let cases = try VectorIO.load("manifest.json", as: Case.self)
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let decoded = try manifest(vector.manifestJSON)
            XCTAssertEqual(String(decoding: try SyncEngine.encode(decoded), as: UTF8.self), vector.manifestJSON, vector.name)
        }
    }

    func testRefusesVersion3() throws {
        assertThrows(.unsupportedFormat(3)) { try SyncEngine.checkOpenable(Manifest(formatVersion: 3)) }
        XCTAssertNoThrow(try SyncEngine.checkOpenable(Manifest(formatVersion: 2)))
    }

    func testRefusesUnknownFeature() throws {
        let m = Manifest(formatVersion: 2, features: ["future-thing"])
        assertThrows(.unsupportedFeature("future-thing")) { try SyncEngine.checkOpenable(m, supported: Set(StoreFeature.allCases)) }
    }

    func testRefusesKnownButUnsupportedFeature() throws {
        let defaultRefused: [StoreFeature] = StoreFeature.allCases.filter { !StoreFeature.supported.contains($0) }
        for feature in defaultRefused {
            let features = (feature.requires + [feature]).map(\.rawValue)
            let m = Manifest(formatVersion: 2, features: features)
            XCTAssertThrowsError(try SyncEngine.checkOpenable(m)) { error in
                guard case SyncError.unsupportedFeature = error else { return XCTFail("\(feature): \(error)") }
            }
        }
        XCTAssertNoThrow(try SyncEngine.checkOpenable(Manifest(formatVersion: 2, features: ["keyring"]), supported: [.keyring]))
        for feature in [StoreFeature.noteItDoc, .noteItSpace] {
            assertThrows(.unsupportedFeature(feature.rawValue)) {
                try SyncEngine.checkOpenable(Manifest(formatVersion: 2, features: [feature.rawValue]), supported: [.keyring])
            }
        }
        assertThrows(.unsupportedFeature("locked-notes")) {
            try SyncEngine.checkOpenable(Manifest(formatVersion: 2, features: ["locked-notes", "noteit-doc"]), supported: [.keyring, .noteItDoc])
        }
    }

    func testFeaturesWithoutVersion2AreInvalid() throws {
        assertThrows(.invalidManifest("features without formatVersion 2")) {
            try SyncEngine.checkOpenable(Manifest(formatVersion: 1, features: ["keyring"]), supported: [.keyring])
        }
        XCTAssertNoThrow(try SyncEngine.checkOpenable(Manifest(formatVersion: 1, features: [])))
    }

    func testLockedNotesWithoutNoteItDocIsInvalid() throws {
        assertThrows(.invalidManifest("locked-notes without noteit-doc")) {
            try SyncEngine.checkOpenable(Manifest(formatVersion: 2, features: ["locked-notes"]), supported: Set(StoreFeature.allCases))
        }
    }

    func testRekeyIsNotAFeature() throws {
        assertThrows(.unsupportedFeature("rekey")) {
            try SyncEngine.checkOpenable(Manifest(formatVersion: 2, features: ["rekey"]), supported: Set(StoreFeature.allCases))
        }
        let decoded = try manifest(#"{"createdAt":0,"formatVersion":1,"rekey":{}}"#)
        XCTAssertNotNil(decoded.rekey)
    }

    func testFeaturesEncodeSorted() throws {
        let m = Manifest(formatVersion: 2, createdAt: Date(timeIntervalSinceReferenceDate: 0), features: ["noteit-doc", "keyring"])
        XCTAssertEqual(String(decoding: try SyncEngine.encode(m), as: UTF8.self),
                       #"{"createdAt":0,"features":["keyring","noteit-doc"],"formatVersion":2}"#)
    }

    func testDeviceInfoWithoutNewFieldsDecodes() throws {
        let info = try SyncEngine.decode(DeviceInfo.self, from: Data(#"{"deviceID":"A","lastSync":0,"name":"Mac"}"#.utf8))
        XCTAssertEqual(info, DeviceInfo(deviceID: "A", name: "Mac", lastSync: Date(timeIntervalSinceReferenceDate: 0)))
        XCTAssertNil(info.platform)
        XCTAssertNil(info.supportedFeatures)
        let future = try SyncEngine.decode(DeviceInfo.self, from: Data(#"{"deviceID":"A","lastSync":0,"name":"Mac","platform":"watch"}"#.utf8))
        XCTAssertEqual(future.platform, "watch")
    }

    func testSyncStateWithoutKeyIDDecodes() throws {
        let state = try JSONDecoder().decode(SyncState.self, from: Data(#"{"knownTombstones":[]}"#.utf8))
        XCTAssertNil(state.keyID)
        var withKey = state
        withKey.keyID = "0123456789abcdef"
        let url = dir.appendingPathComponent("state.json")
        try withKey.save(to: url)
        XCTAssertEqual(SyncState.load(from: url).keyID, "0123456789abcdef")
    }

    func testSyncStateWithoutPendingBodyVersionsDecodes() throws {
        let id = UUID()
        let revision = UUID()
        let legacy = SyncState(bases: [id: .init(revision: revision, remoteMetaETag: "e1")], knownTombstones: [UUID()],
                               pendingPushes: [id: revision])
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(legacy)) as! [String: Any]
        json["pendingBodyVersions"] = nil
        json["keyID"] = nil
        let url = dir.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = SyncState.load(from: url)
        XCTAssertEqual(loaded.pendingBodyVersions, [:])
        XCTAssertEqual(loaded.bases, legacy.bases)
        XCTAssertEqual(loaded.knownTombstones, legacy.knownTombstones)
        XCTAssertEqual(loaded.pendingPushes, legacy.pendingPushes)
    }

    func testPendingBodyVersionsRoundTrip() throws {
        var state = SyncState()
        for phase in [PendingBody.Phase.uploading, .committing, .inDoubt] {
            let id = UUID()
            let envelope = RemoteEnvelope(id: id, kind: .note, revision: UUID(), modifiedAt: Date(timeIntervalSinceReferenceDate: 100),
                                          deviceID: "D", deviceName: "Mac", meta: Data("{}".utf8), bodySHA256: "abc")
            state.pendingBodyVersions[id] = PendingBody(version: UUID(), tag: "t-\(phase.rawValue)", phase: phase, envelope: envelope)
        }
        let url = dir.appendingPathComponent("pending.json")
        try state.save(to: url)
        XCTAssertEqual(SyncState.load(from: url), state)
    }

    func testKeysFolderIgnoredByIndex() throws {
        let id = UUID()
        let index = RemoteIndex([
            RemoteObject(key: RemoteLayout.root + "keys/locked-notes.json", etag: "a", size: 1),
            RemoteObject(key: RemoteLayout.root + "keys/\(id.uuidString).json", etag: "b", size: 1),
            RemoteObject(key: RemoteLayout.root + "keys/\(id.uuidString).meta", etag: "c", size: 1),
            RemoteObject(key: RemoteLayout.manifest(), etag: "m", size: 1),
        ])
        XCTAssertTrue(index.hasManifest)
        XCTAssertTrue(index.metas.isEmpty)
        XCTAssertTrue(index.bodies.isEmpty)
        XCTAssertTrue(index.tombstones.isEmpty)
        XCTAssertTrue(index.sidecars.isEmpty)
    }

    func testDeviceRecordOmitsSupportedFeaturesBeforeSessions() async throws {
        let backend = InMemoryBackend()
        let (_, cipher) = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false)
        let engine = SyncEngine(backend: backend, cipher: cipher, local: FakeLocalStore(), stateURL: dir.appendingPathComponent("s.json"),
                                deviceID: "DEV", deviceName: "Mac")
        _ = try await engine.sync()
        let data = try await backend.get(RemoteLayout.device("DEV")).data
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["platform"] as? String, "mac")
        if StoreFeature.supported.isEmpty {
            XCTAssertNil(json["supportedFeatures"])
        }
        XCTAssertNil(json["rekeyAck"])
    }
}
