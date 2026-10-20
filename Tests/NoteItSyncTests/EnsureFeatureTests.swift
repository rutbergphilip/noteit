import CryptoKit
import XCTest
@testable import NoteItSync

/// foundations Task 3.4: updateManifest, updateRekey, devicesBlocking and ensureFeature.
final class EnsureFeatureTests: XCTestCase {
    private let all = Set(StoreFeature.allCases)
    private let me = "ME"

    // MARK: Helpers

    private func plainStore(_ manifest: Manifest = Manifest(createdAt: Date(timeIntervalSinceReferenceDate: 0)),
                            supported: Set<StoreFeature>? = nil, kind: StoreSessionKind = .library) async throws
        -> (InMemoryBackend, FaultyBackend, StoreSession) {
        let memory = InMemoryBackend()
        try await memory.put(RemoteLayout.manifest(), data: try SyncEngine.encode(manifest), ifMatch: nil, ifNoneMatch: true)
        let session = try await SyncEngine.connectSession(backend: memory, kind: kind, credential: nil, deviceName: "Mac",
                                                          createIfMissing: false, encrypted: false,
                                                          supported: supported ?? all).session
        return (memory, FaultyBackend(memory), session)
    }

    private func stored(_ backend: StorageBackend) async throws -> Manifest {
        try SyncEngine.decode(Manifest.self, from: try await backend.get(RemoteLayout.manifest()).data)
    }

    private func raw(_ backend: StorageBackend) async throws -> Data {
        try await backend.get(RemoteLayout.manifest()).data
    }

    /// Writes `manifest` straight to storage, as another device would.
    private func overwrite(_ backend: InMemoryBackend, _ edit: @escaping @Sendable (inout Manifest) -> Void) async {
        var m = try! SyncEngine.decode(Manifest.self, from: try! await backend.get(RemoteLayout.manifest()).data)
        edit(&m)
        try! await backend.put(RemoteLayout.manifest(), data: try! SyncEngine.encode(m), ifMatch: nil, ifNoneMatch: false)
    }

    private func putDevice(_ backend: StorageBackend, _ session: StoreSession, id: String, name: String,
                           supported: [String]?) async throws {
        let info = DeviceInfo(deviceID: id, name: name, lastSync: Date(timeIntervalSinceReferenceDate: 0), platform: "mac",
                              appVersion: "1.0", supportedFeatures: supported)
        let key = RemoteLayout.device(id)
        try await backend.put(key, data: try session.cipher.seal(try SyncEngine.encode(info), context: SyncEngine.context(key)),
                              ifMatch: nil, ifNoneMatch: false)
    }

    private func ensure(_ feature: StoreFeature, _ backend: StorageBackend, _ session: StoreSession,
                        supported: Set<StoreFeature>? = nil, answer: Bool = true,
                        asked: Asked? = nil) async throws -> FeatureAddition {
        try await SyncEngine.ensureFeature(feature, backend: backend, session: session, currentDeviceID: me,
                                           supported: supported ?? all) { blockers in
            await asked?.record(blockers)
            return answer
        }
    }

    actor Asked {
        var calls: [[FeatureBlocker]] = []
        func record(_ blockers: [FeatureBlocker]) { calls.append(blockers) }
    }

    private func assertThrows<T>(_ expected: SyncError, _ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SyncError, expected, file: file, line: line)
        }
    }

    private func rekey(_ to: String, device: String = "OTHER", updatedAt: Date = Date()) -> Rekey {
        Rekey(fromKeyID: nil, toKeyID: to, startedAt: updatedAt, updatedAt: updatedAt, deviceID: device, deviceName: "Other Mac")
    }

    // MARK: updateManifest

    func testUpdateManifestKeepsUnknownKeys() async throws {
        let memory = InMemoryBackend()
        let json = #"{"createdAt":0,"formatVersion":1,"futureKey":{"a":[1,2]},"zz":"keep"}"#
        try await memory.put(RemoteLayout.manifest(), data: Data(json.utf8), ifMatch: nil, ifNoneMatch: true)
        let session = try await SyncEngine.connectSession(backend: memory, kind: .library, credential: nil, deviceName: "Mac",
                                                          createIfMissing: false, encrypted: false, supported: all).session
        let updated = try await SyncEngine.updateManifest(backend: memory, session: session) { $0.features = ["noteit-doc"] }
        let object = try JSONSerialization.jsonObject(with: try await raw(memory)) as! [String: Any]
        XCTAssertEqual(object["zz"] as? String, "keep")
        XCTAssertEqual((object["futureKey"] as? [String: Any])?["a"] as? [Int], [1, 2])
        XCTAssertEqual(object["formatVersion"] as? Int, 2)
        XCTAssertEqual(object["features"] as? [String], ["noteit-doc"])
        XCTAssertEqual(updated.features, [.noteItDoc])
        let etag = try await memory.get(RemoteLayout.manifest()).etag
        XCTAssertEqual(updated.manifestETag, etag)
    }

    func testUpdateUsesSessionSupported() async throws {
        let spaceSupported = StoreFeature.supported.union([.noteItSpace])
        let base = Manifest(formatVersion: 2, createdAt: Date(timeIntervalSinceReferenceDate: 0), features: ["noteit-space"])
        let (memory, faulty, session) = try await plainStore(base, supported: spaceSupported, kind: .space)
        await faulty.onNextPut(keyContaining: "manifest.json", .before { await self.overwrite(memory) { $0.createdAt = Date(timeIntervalSinceReferenceDate: 5) } })
        let updated = try await SyncEngine.updateManifest(backend: faulty, session: session) { $0.rekey = self.rekey("abc", device: "ME") }
        XCTAssertEqual(updated.supported, spaceSupported)
        XCTAssertEqual(updated.features, [.noteItSpace])
        let finished = try await SyncEngine.updateRekey(backend: faulty, session: updated, expectedRekeyToKeyID: "abc") { $0.rekey = nil }
        XCTAssertEqual(finished.supported, spaceSupported)
        XCTAssertNil(finished.dataKey)
        let m = try await stored(memory)
        XCTAssertNil(m.rekey)
        XCTAssertEqual(m.createdAt, Date(timeIntervalSinceReferenceDate: 5))

        let keyring = InMemoryBackend()
        let ks = try await SyncEngine.connectSession(backend: keyring, kind: .library, credential: .passphrase("pw"), deviceName: "Mac",
                                                     createIfMissing: true, encrypted: true, initialFeatures: [.keyring]).session
        let kept = try await SyncEngine.updateManifest(backend: keyring, session: ks) { $0.createdAt = Date(timeIntervalSinceReferenceDate: 1) }
        XCTAssertEqual(kept.dataKey.map { $0.withUnsafeBytes { Data($0) } }, ks.dataKey.map { $0.withUnsafeBytes { Data($0) } })
        XCTAssertEqual(kept.keyID, ks.keyID)
    }

    func testUpdateManifestRetriesOn412() async throws {
        let (memory, faulty, session) = try await plainStore()
        await faulty.onNextPut(keyContaining: "manifest.json", .before { await self.overwrite(memory) { $0.createdAt = Date(timeIntervalSinceReferenceDate: 9) } })
        let before = await memory.putCount
        let updated = try await SyncEngine.updateManifest(backend: faulty, session: session) { $0.features = ["noteit-doc"] }
        let m = try await stored(memory)
        XCTAssertEqual(m.features, ["noteit-doc"])
        XCTAssertEqual(m.createdAt, Date(timeIntervalSinceReferenceDate: 9), "the change is replayed on the re-read manifest")
        XCTAssertEqual(updated.manifest, m)
        let puts = await memory.putCount - before
        XCTAssertEqual(puts, 3, "the other device's write, the refused write and the retry")
    }

    func testUpdateManifestGivesUpAfterThreeConflicts() async throws {
        let (memory, faulty, session) = try await plainStore()
        for i in 1...4 {
            await faulty.onNextPut(keyContaining: "manifest.json", .before {
                await self.overwrite(memory) { $0.createdAt = Date(timeIntervalSinceReferenceDate: Double(i)) }
            })
        }
        await assertThrows(.manifestChangedConcurrently) {
            try await SyncEngine.updateManifest(backend: faulty, session: session) { $0.features = ["noteit-doc"] }
        }
        let m = try await stored(memory)
        XCTAssertNil(m.features)
        XCTAssertEqual(m.createdAt, Date(timeIntervalSinceReferenceDate: 4), "one first try and three retries")
    }

    func testRetryStopsWhenRekeyStarts() async throws {
        let (memory, faulty, session) = try await plainStore()
        await faulty.onNextPut(keyContaining: "manifest.json", .before { await self.overwrite(memory) { $0.rekey = self.rekey("abc") } })
        await assertThrows(.rekeyInProgress(deviceName: "Other Mac")) { try await self.ensure(.noteItDoc, faulty, session) }
        let m = try await stored(memory)
        XCTAssertNil(m.features)
        XCTAssertNotNil(m.rekey)
    }

    func testRetryStopsWhenKeyChanges() async throws {
        let memory = InMemoryBackend()
        let session = try await SyncEngine.connectSession(backend: memory, kind: .library, credential: .passphrase("pw"), deviceName: "Mac",
                                                          createIfMissing: true, encrypted: true, initialFeatures: [.keyring],
                                                          supported: all).session
        let faulty = FaultyBackend(memory)
        let other = try Keyring.make(dataKey: SymmetricKey(size: .bits256), passphrase: "pw", deviceName: "Other Mac", now: Date(),
                                     iterations: 100_000)
        await faulty.onNextPut(keyContaining: "manifest.json", .before { await self.overwrite(memory) { $0.keyring = other } })
        await assertThrows(.keyChanged(byDevice: "Other Mac")) { try await self.ensure(.noteItDoc, faulty, session) }
        let m = try await stored(memory)
        XCTAssertEqual(m.features, ["keyring"])
        XCTAssertEqual(m.keyring, other)
    }

    func testRetryStopsOnUnsupportedFeature() async throws {
        let (memory, faulty, session) = try await plainStore(supported: [.keyring, .noteItDoc])
        await faulty.onNextPut(keyContaining: "manifest.json", .before {
            await self.overwrite(memory) { $0.formatVersion = 2; $0.features = ["noteit-space"] }
        })
        await assertThrows(.manifestChangedConcurrently) {
            try await self.ensure(.noteItDoc, faulty, session, supported: [.keyring, .noteItDoc])
        }
        let m = try await stored(memory)
        XCTAssertEqual(m.features, ["noteit-space"])
    }

    func testAnyFeatureImpliesVersion2() async throws {
        let (memory, _, session) = try await plainStore()
        let updated = try await SyncEngine.updateManifest(backend: memory, session: session) { $0.features = ["noteit-doc"] }
        XCTAssertEqual(updated.formatVersion, 2)
        let m = try await stored(memory)
        XCTAssertEqual(m.formatVersion, 2)
        XCTAssertEqual(m.features, ["noteit-doc"])
        await assertThrows(.invalidManifest("the change leaves a manifest this build can't open: invalidManifest(\"locked-notes without noteit-doc\")")) {
            try await SyncEngine.updateManifest(backend: memory, session: session) { $0.features = ["locked-notes"] }
        }
    }

    func testUpdateManifestRefusesWhileRekeySet() async throws {
        let (memory, _, session) = try await plainStore()
        await overwrite(memory) { $0.rekey = self.rekey("abc") }
        let before = try await raw(memory)
        await assertThrows(.rekeyInProgress(deviceName: "Other Mac")) {
            try await SyncEngine.updateManifest(backend: memory, session: session) { $0.createdAt = Date() }
        }
        let after = try await raw(memory)
        XCTAssertEqual(after, before)
    }

    // MARK: updateRekey

    func testUpdateRekeyHeartbeatAndFinish() async throws {
        let memory = InMemoryBackend()
        let session = try await SyncEngine.connectSession(backend: memory, kind: .library, credential: .passphrase("pw"), deviceName: "Mac",
                                                          createIfMissing: true, encrypted: true, initialFeatures: [.keyring]).session
        let newKey = SymmetricKey(size: .bits256)
        let newKeyring = try Keyring.make(dataKey: newKey, passphrase: "pw", deviceName: "Mac", now: Date(), iterations: 100_000)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let started = try await SyncEngine.updateManifest(backend: memory, session: session) {
            $0.rekey = Rekey(fromKeyID: session.keyID, toKeyID: newKeyring.keyID, startedAt: start, updatedAt: start, deviceID: "ME",
                             deviceName: "Mac", previousKeyring: $0.keyring)
        }
        let beat = Date(timeIntervalSinceReferenceDate: 2000)
        let heartbeat = try await SyncEngine.updateRekey(backend: memory, session: started, expectedRekeyToKeyID: newKeyring.keyID) {
            $0.rekey?.updatedAt = beat
        }
        XCTAssertEqual(heartbeat.manifest.rekey?.updatedAt, beat)
        XCTAssertNotNil(heartbeat.dataKey)
        let finished = try await SyncEngine.updateRekey(backend: memory, session: heartbeat, expectedRekeyToKeyID: newKeyring.keyID) {
            $0.rekey = nil
            $0.keyring = newKeyring
        }
        let m = try await stored(memory)
        XCTAssertNil(m.rekey)
        XCTAssertEqual(m.keyring, newKeyring)
        XCTAssertEqual(m.features, ["keyring"])
        XCTAssertEqual(finished.keyID, newKeyring.keyID)
        XCTAssertNil(finished.dataKey)
    }

    func testUpdateRekeyStopsWhenRekeyChanges() async throws {
        for replacement in [rekey("other-to"), nil] {
            let (memory, faulty, session) = try await plainStore()
            let started = try await SyncEngine.updateManifest(backend: memory, session: session) { $0.rekey = self.rekey("mine", device: "ME") }
            await faulty.onNextPut(keyContaining: "manifest.json", .before { await self.overwrite(memory) { $0.rekey = replacement } })
            let before = await memory.putCount
            await assertThrows(.manifestChangedConcurrently) {
                try await SyncEngine.updateRekey(backend: faulty, session: started, expectedRekeyToKeyID: "mine") { $0.rekey?.updatedAt = Date() }
            }
            let puts = await memory.putCount - before
            XCTAssertEqual(puts, 2, "the other device's write and the refused one, no retry")
            let m = try await stored(memory)
            XCTAssertEqual(m.rekey, replacement)
        }
    }

    func testUpdateRekeyRefusesOtherKeys() async throws {
        let (memory, _, session) = try await plainStore()
        let started = try await SyncEngine.updateManifest(backend: memory, session: session) { $0.rekey = self.rekey("mine", device: "ME") }
        let before = try await raw(memory)
        do {
            _ = try await SyncEngine.updateRekey(backend: memory, session: started, expectedRekeyToKeyID: "mine") {
                $0.rekey = nil
                $0.features = ["noteit-doc"]
            }
            XCTFail("expected invalidManifest")
        } catch SyncError.invalidManifest {
        }
        let after = try await raw(memory)
        XCTAssertEqual(after, before)
    }

    // MARK: ensureFeature

    func testEnsureFeatureAsksOnlyWhenBlocked() async throws {
        let (memory, _, session) = try await plainStore()
        try await putDevice(memory, session, id: "B", name: "Book", supported: ["keyring", "noteit-doc"])
        let asked = Asked()
        let added = try await ensure(.noteItDoc, memory, session, asked: asked)
        let calls = await asked.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(added.session.features, [.noteItDoc])
        XCTAssertTrue(added.lateBlockers.isEmpty)

        let (memory2, _, session2) = try await plainStore()
        try await putDevice(memory2, session2, id: "C", name: "Old Mac", supported: ["keyring"])
        let asked2 = Asked()
        _ = try await ensure(.noteItDoc, memory2, session2, asked: asked2)
        let calls2 = await asked2.calls
        XCTAssertEqual(calls2.map { $0.map(\.deviceName) }, [["Old Mac"]])
        XCTAssertEqual(calls2.first?.first?.appVersion, "1.0")
    }

    func testEnsureFeatureDeclinedWritesNothing() async throws {
        let (memory, _, session) = try await plainStore()
        try await putDevice(memory, session, id: "C", name: "Old Mac", supported: nil)
        let before = try await raw(memory)
        await assertThrows(.featureDeclined("noteit-doc")) { try await self.ensure(.noteItDoc, memory, session, answer: false) }
        let after = try await raw(memory)
        XCTAssertEqual(after, before)
    }

    func testEnsureFeatureRefusedDuringRekey() async throws {
        let (memory, _, plain) = try await plainStore()
        let session = try await SyncEngine.updateManifest(backend: memory, session: plain) { $0.rekey = self.rekey("abc", device: "ME") }
        let before = try await raw(memory)
        await assertThrows(.rekeyInProgress(deviceName: "Other Mac")) { try await self.ensure(.noteItDoc, memory, session) }
        let after = try await raw(memory)
        XCTAssertEqual(after, before)
    }

    func testEnsureFeatureRefusesUnsupported() async throws {
        let (memory, _, session) = try await plainStore()
        let before = try await raw(memory)
        await assertThrows(.unsupportedFeature("noteit-doc")) {
            try await SyncEngine.ensureFeature(.noteItDoc, backend: memory, session: session, currentDeviceID: self.me) { _ in true }
        }
        await assertThrows(.unsupportedFeature("noteit-doc")) {
            try await self.ensure(.lockedNotes, memory, session, supported: [.keyring, .lockedNotes])
        }
        let after = try await raw(memory)
        XCTAssertEqual(after, before)
    }

    func testLockedNotesAddsNoteItDocFirst() async throws {
        let (memory, _, session) = try await plainStore()
        try await putDevice(memory, session, id: "B", name: "Doc Mac", supported: ["noteit-doc"])
        try await putDevice(memory, session, id: "C", name: "Lock Mac", supported: ["locked-notes"])
        try await putDevice(memory, session, id: "D", name: "New Mac", supported: ["keyring", "locked-notes", "noteit-doc"])
        let asked = Asked()
        let added = try await ensure(.lockedNotes, memory, session, asked: asked)
        let calls = await asked.calls
        XCTAssertEqual(calls.map { $0.map(\.deviceName) }, [["Doc Mac", "Lock Mac"]])
        XCTAssertEqual(added.session.features, [.noteItDoc, .lockedNotes])
        let m = try await stored(memory)
        XCTAssertEqual(m.features, ["locked-notes", "noteit-doc"])
        XCTAssertEqual(m.formatVersion, 2)
    }

    func testDeviceWithoutSupportedFeaturesBlocks() async throws {
        let (memory, _, session) = try await plainStore()
        try await putDevice(memory, session, id: "IOS", name: "Phone", supported: nil)
        let blockers = try await SyncEngine.devicesBlocking(.keyring, backend: memory, session: session, currentDeviceID: me)
        XCTAssertEqual(blockers.map(\.deviceID), ["IOS"])
        XCTAssertEqual(blockers.first?.deviceName, "Phone")
    }

    func testOwnStaleDeviceRecordDoesNotBlock() async throws {
        let (memory, _, session) = try await plainStore()
        try await putDevice(memory, session, id: me, name: "This Mac", supported: nil)
        let blockers = try await SyncEngine.devicesBlocking(.noteItDoc, backend: memory, session: session, currentDeviceID: me)
        XCTAssertTrue(blockers.isEmpty)
        let asked = Asked()
        _ = try await ensure(.noteItDoc, memory, session, asked: asked)
        let calls = await asked.calls
        XCTAssertTrue(calls.isEmpty)
        let others = try await SyncEngine.devicesBlocking(.noteItDoc, backend: memory, session: session, currentDeviceID: "SOMEONE")
        XCTAssertEqual(others.map(\.deviceID), [me])
    }

    func testEnsureFeatureIdempotent() async throws {
        let (memory, _, session) = try await plainStore()
        let first = try await ensure(.noteItDoc, memory, session)
        let puts = await memory.putCount
        let second = try await ensure(.noteItDoc, memory, first.session)
        let after = await memory.putCount
        XCTAssertEqual(after, puts)
        XCTAssertEqual(second.session.manifestETag, first.session.manifestETag)
        XCTAssertTrue(second.lateBlockers.isEmpty)

        // A 412 whose re-read already has the feature adopts it without writing.
        let (memory2, faulty2, session2) = try await plainStore()
        await faulty2.onNextPut(keyContaining: "manifest.json", .before {
            await self.overwrite(memory2) { $0.formatVersion = 2; $0.features = ["noteit-doc"] }
        })
        let adopted = try await ensure(.noteItDoc, faulty2, session2)
        let etag = try await memory2.get(RemoteLayout.manifest()).etag
        XCTAssertEqual(adopted.session.manifestETag, etag)
        XCTAssertEqual(adopted.session.features, [.noteItDoc])
    }

    func testDeviceAppearingDuringWriteIsReportedAfter() async throws {
        let (memory, faulty, session) = try await plainStore()
        await faulty.onNextPut(keyContaining: "manifest.json", .before {
            try! await self.putDevice(memory, session, id: "LATE", name: "Late Mac", supported: nil)
        })
        let asked = Asked()
        let added = try await ensure(.noteItDoc, faulty, session, asked: asked)
        let calls = await asked.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(added.lateBlockers.map(\.deviceName), ["Late Mac"])
        let m = try await stored(memory)
        XCTAssertEqual(m.features, ["noteit-doc"])
    }

    // MARK: Vectors

    struct FeatureCase: Codable, Equatable {
        struct Expect: Codable, Equatable {
            var error: String?
            var features: [String]?
            var bodyEncoding: String?
            var legacyStore: Bool?
            var upgrade: String?
            var upgradedManifestJSON: String?
        }

        var name: String
        var manifestJSON: String
        var expect: Expect
    }

    func testManifestFeatureVectors() async throws {
        let epoch = VectorIO.epoch
        let ring = try Keyring.make(dataKey: SymmetricKey(data: VectorIO.bytes("features-data-key", count: 32)), passphrase: "pw",
                                    deviceName: "Vector Mac", now: epoch, iterations: 100_000,
                                    salt: VectorIO.bytes("features-salt", count: 16),
                                    nonce: try AES.GCM.Nonce(data: VectorIO.bytes("features-nonce", count: 12)))
        let encryption = Manifest.Encryption(salt: VectorIO.bytes("features-v1-salt", count: 16), iterations: 210_000,
                                             keyCheck: VectorIO.bytes("features-v1-check", count: 45))
        func json(_ m: Manifest) throws -> String { String(decoding: try SyncEngine.encode(m), as: UTF8.self) }
        let inputs: [(String, String)] = [
            ("v1", try json(Manifest(encryption: encryption, createdAt: epoch))),
            ("v2-keyring", try json(Manifest(formatVersion: 2, createdAt: epoch, features: ["keyring"], keyring: ring))),
            ("v2-noteit-doc", try json(Manifest(formatVersion: 2, createdAt: epoch, features: ["noteit-doc"]))),
            ("keyring-noteit-doc-locked-notes", try json(Manifest(formatVersion: 2, createdAt: epoch,
                                                                   features: ["keyring", "locked-notes", "noteit-doc"], keyring: ring))),
            ("locked-notes-without-noteit-doc", try json(Manifest(formatVersion: 2, createdAt: epoch, features: ["locked-notes"]))),
            ("rekey-set", try json(Manifest(encryption: encryption, createdAt: epoch,
                                            rekey: Rekey(fromKeyID: KeyIdentity.legacyKeyID(encryption), toKeyID: ring.keyID,
                                                         startedAt: epoch, updatedAt: epoch, deviceID: "VECTOR",
                                                         deviceName: "Vector Mac")))),
            ("unknown-keys", #"{"createdAt":788918400,"formatVersion":1,"futureKey":{"nested":[1,2,3]},"zzz":"kept"}"#),
        ]
        var cases: [FeatureCase] = []
        for (name, manifestJSON) in inputs {
            cases.append(FeatureCase(name: name, manifestJSON: manifestJSON, expect: try await expectation(manifestJSON)))
        }
        XCTAssertEqual(cases.map(\.expect.upgrade), ["run", "run", "none", "none", nil, "skipRekey", "run"])
        XCTAssertEqual(cases[4].expect.error, "invalidManifest")
        XCTAssertTrue(cases[6].expect.upgradedManifestJSON?.contains(#""zzz":"kept""#) == true)
        try VectorIO.check("manifest-features.json", cases)

        for stored in try VectorIO.load("manifest-features.json", as: FeatureCase.self) {
            let expect = try await expectation(stored.manifestJSON)
            XCTAssertEqual(expect, stored.expect, stored.name)
        }
    }

    /// Validity with every known feature supported, and what the Mac's noteit-doc upgrade does to the manifest.
    private func expectation(_ manifestJSON: String) async throws -> FeatureCase.Expect {
        let manifest = try SyncEngine.decode(Manifest.self, from: Data(manifestJSON.utf8))
        do {
            try SyncEngine.checkOpenable(manifest, supported: all)
        } catch SyncError.invalidManifest {
            return .init(error: "invalidManifest")
        }
        let features = (manifest.features ?? []).sorted()
        let hasDoc = features.contains(StoreFeature.noteItDoc.rawValue)
        var expect = FeatureCase.Expect(features: features, bodyEncoding: hasDoc ? "noteitDocV1" : "rtfd", legacyStore: !hasDoc,
                                        upgrade: hasDoc ? "none" : manifest.rekey != nil ? "skipRekey" : "run")
        if expect.upgrade == "run" {
            let memory = InMemoryBackend()
            try await memory.put(RemoteLayout.manifest(), data: Data(manifestJSON.utf8), ifMatch: nil, ifNoneMatch: true)
            let etag = try await memory.get(RemoteLayout.manifest()).etag
            let session = StoreSession(kind: .library, manifest: manifest, manifestETag: etag, cipher: PassthroughCipher(),
                                       keyID: try SyncEngine.keyID(of: manifest), features: StoreSession.features(of: manifest),
                                       supported: all, dataKey: nil)
            _ = try await ensure(.noteItDoc, memory, session)
            expect.upgradedManifestJSON = String(decoding: try await raw(memory), as: UTF8.self)
        }
        return expect
    }
}
