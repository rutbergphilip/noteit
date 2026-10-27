import Foundation
import XCTest
@testable import NoteItSync

/// web-app Task 0.4: the `noteit-doc` store feature, versioned crash-safe bodies, the automatic upgrade, the conversion
/// and orphan sweeps, body repair, and the delete rules for stores without atomic conditional writes or deletes.
final class FormatV2Tests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FormatV2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    final class Device: @unchecked Sendable {
        let name: String
        let store: FakeLocalStore
        let ref: StoreSessionRef
        var engine: SyncEngine
        let stateURL: URL

        init(name: String, store: FakeLocalStore, ref: StoreSessionRef, engine: SyncEngine, stateURL: URL) {
            self.name = name
            self.store = store
            self.ref = ref
            self.engine = engine
            self.stateURL = stateURL
        }

        var state: SyncState { SyncState.load(from: stateURL) }
    }

    /// Connects like the app (creating a plaintext store with `initial` when missing) and builds an engine.
    private func device(_ name: String, _ backend: StorageBackend, initial: Set<StoreFeature> = [],
                        supported: Set<StoreFeature> = StoreFeature.supported,
                        now: @escaping @Sendable () -> Date = { Date() }) async throws -> Device {
        let session = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: nil, deviceName: name,
                                                          createIfMissing: true, encrypted: false, initialFeatures: initial,
                                                          supported: supported).session
        let ref = StoreSessionRef(session)
        let store = FakeLocalStore(session: ref)
        let url = dir.appendingPathComponent(name).appendingPathComponent("state.json")
        let engine = SyncEngine(backend: backend, session: ref, local: store, stateURL: url, deviceID: "device-\(name)",
                                deviceName: name, now: now)
        return Device(name: name, store: store, ref: ref, engine: engine, stateURL: url)
    }

    /// A fresh engine over the same state file, store and backend: a restart after a crash.
    private func relaunch(_ device: Device, _ backend: StorageBackend, now: @escaping @Sendable () -> Date = { Date() }) {
        device.engine = SyncEngine(backend: backend, session: device.ref, local: device.store, stateURL: device.stateURL,
                                   deviceID: "device-\(device.name)", deviceName: device.name, now: now)
    }

    @discardableResult
    private func sync(_ devices: Device...) async throws -> SyncReport {
        var last = SyncReport()
        for device in devices { last = try await device.engine.sync() }
        return last
    }

    private func manifest(_ backend: StorageBackend) async throws -> Manifest {
        try SyncEngine.decode(Manifest.self, from: try await backend.get(RemoteLayout.manifest()).data)
    }

    private func putManifest(_ manifest: Manifest, _ backend: StorageBackend) async throws {
        try await backend.put(RemoteLayout.manifest(), data: try SyncEngine.encode(manifest), ifMatch: nil, ifNoneMatch: false)
    }

    /// The plaintext envelope of a note (stores here are unencrypted).
    private func envelope(_ backend: StorageBackend, _ id: UUID) async throws -> RemoteEnvelope {
        try SyncEngine.decode(RemoteEnvelope.self, from: try await backend.get(RemoteLayout.meta(.note, id)).data)
    }

    private func keys(_ backend: StorageBackend, _ folder: String) async throws -> [String] {
        try await backend.list(prefix: RemoteLayout.root + folder).map(\.key)
    }

    private func bodyKeys(_ backend: StorageBackend, _ id: UUID) async throws -> [String] {
        try await keys(backend, "bodies/").filter { $0.contains(id.uuidString) }
    }

    /// A real folder store in the test's scratch directory (neither atomic capability).
    private func folderBackend() throws -> FolderBackend {
        let root = dir.appendingPathComponent("folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FolderBackend(root: root)
    }

    /// A plaintext store without noteit-doc, as every build before Task 0.4 created it.
    private func v1Store(_ backend: StorageBackend) async throws {
        _ = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: nil, deviceName: "",
                                                createIfMissing: true, encrypted: false)
    }

    private func putDevice(_ backend: StorageBackend, id: String, supported: [String]?) async throws {
        let info = try SyncEngine.encode(DeviceInfo(deviceID: id, name: "Mac \(id)", lastSync: Date(), supportedFeatures: supported))
        try await backend.put(RemoteLayout.device(id), data: info, ifMatch: nil, ifNoneMatch: false)
    }

    // MARK: - Types

    func testEnvelopeFieldsRoundTripAndNilOmitsKeys() throws {
        let version = UUID()
        let doc = RemoteEnvelope(id: UUID(), kind: .note, revision: UUID(), modifiedAt: Date(timeIntervalSince1970: 0), deviceID: "d",
                                 deviceName: "D", meta: Data("{}".utf8), bodySHA256: "ab", bodyFormat: BodyFormat.noteItDocV1, bodyVersion: version)
        let decoded = try SyncEngine.decode(RemoteEnvelope.self, from: try SyncEngine.encode(doc))
        XCTAssertEqual(decoded, doc)
        XCTAssertTrue(String(decoding: try SyncEngine.encode(doc), as: UTF8.self).contains(version.uuidString), "uppercase UUID")

        var legacy = doc
        legacy.bodyFormat = nil
        legacy.bodyVersion = nil
        let json = String(decoding: try SyncEngine.encode(legacy), as: UTF8.self)
        XCTAssertFalse(json.contains("bodyFormat"))
        XCTAssertFalse(json.contains("bodyVersion"))
        let old = #"{"id":"6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","kind":"note","revision":"6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","modifiedAt":0,"deviceID":"d","deviceName":"D","meta":"e30="}"#
        let oldShape = try SyncEngine.decode(RemoteEnvelope.self, from: Data(old.utf8))
        XCTAssertNil(oldShape.bodyFormat)
        XCTAssertNil(oldShape.bodyVersion)
    }

    func testWireRuleAndPairingRule() throws {
        XCTAssertNoThrow(try BodyFormat.validateForPublish(nil))
        XCTAssertNoThrow(try BodyFormat.validateForPublish("noteit-doc/1"))
        XCTAssertNoThrow(try BodyFormat.validateForPublish("noteit-locked/1", features: [.noteItDoc, .lockedNotes]))
        for bad in ["rtfd", "", "noteit-doc/2", "noteit-locked/1"] {
            XCTAssertThrowsError(try BodyFormat.validateForPublish(bad, features: [.noteItDoc])) { error in
                guard case SyncError.invalidPayload(let message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.hasPrefix("bodyFormat: "), message)
            }
        }
        let base = RemoteEnvelope(id: UUID(), kind: .note, revision: UUID(), modifiedAt: Date(), deviceID: "d", deviceName: "D", meta: Data())
        var env = base
        XCTAssertNoThrow(try BodyFormat.validateEnvelope(env))
        env.bodyFormat = BodyFormat.noteItDocV1
        XCTAssertThrowsError(try BodyFormat.validateEnvelope(env), "format without version")
        env.bodyVersion = UUID()
        XCTAssertNoThrow(try BodyFormat.validateEnvelope(env))
        env.bodyFormat = nil
        XCTAssertThrowsError(try BodyFormat.validateEnvelope(env), "version without format")
        env.bodyFormat = BodyFormat.noteItLockedV1
        XCTAssertThrowsError(try BodyFormat.validateEnvelope(env, features: [.noteItDoc]), "locked without the feature")
        XCTAssertNoThrow(try BodyFormat.validateEnvelope(env, features: [.noteItDoc, .lockedNotes]))
    }

    func testRemoteIndexParsesVersionedBodies() {
        let id = UUID(), version = UUID(), other = UUID()
        let tag = RemoteLayout.baseTag("\"abc\"")
        let objects = [
            RemoteObject(key: RemoteLayout.docBody(id, version: version, tag: tag), etag: "1", size: 1),
            RemoteObject(key: RemoteLayout.docBody(id, version: other, tag: RemoteLayout.newTag, locked: true), etag: "2", size: 1),
            RemoteObject(key: RemoteLayout.bodiesPrefix + "\(id.uuidString).junk", etag: "3", size: 1),
            RemoteObject(key: RemoteLayout.bodiesPrefix + "\(id.uuidString).\(version.uuidString.lowercased()).\(tag).body", etag: "4", size: 1),
        ]
        let index = RemoteIndex(objects)
        XCTAssertEqual(index.docBodies[id]?[version]?.tag, tag)
        XCTAssertEqual(index.docBodies[id]?[other]?.locked, true)
        XCTAssertEqual(index.strayBodies.map(\.etag), ["3", "4"])
        XCTAssertTrue(index.sidecars.isEmpty)
        XCTAssertTrue(index.bodies.isEmpty)
    }

    func testBaseTagShape() {
        XCTAssertEqual(RemoteLayout.baseTag("\"abc\""), RemoteLayout.baseTag("abc"), "quotes are ignored")
        let tag = RemoteLayout.baseTag("5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(tag.count, 16)
        XCTAssertTrue(RemoteLayout.isTag(tag))
        XCTAssertNotEqual(tag, RemoteLayout.baseTag("5d41402abc4b2a76b9719d911017c593"))
    }

    func testOldStateFilesDecode() throws {
        // As 0.6.x wrote it: UUID-keyed maps are arrays of alternating keys and values.
        let old = #"{"bases":["6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F",{"revision":"6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F","remoteMetaETag":"e"}],"pendingPushes":[]}"#
        let url = dir.appendingPathComponent("old.json")
        try Data(old.utf8).write(to: url)
        let state = SyncState.load(from: url)
        XCTAssertEqual(state.bases.count, 1)
        XCTAssertNil(state.bases.first?.value.bodyVersion)
        XCTAssertTrue(state.legacyBodies.isEmpty)
        XCTAssertEqual(state.passCount, 0)
        XCTAssertTrue(state.tombstoneBindings.isEmpty)
    }

    func testDeviceRecordListsNoteItDocAndWaveZeroBuildRefusesTheStore() async throws {
        let backend = InMemoryBackend()
        let a = try await device("A", backend, initial: [.noteItDoc])
        try await sync(a)
        let info = try SyncEngine.decode(DeviceInfo.self, from: try await backend.get(RemoteLayout.device("device-A")).data)
        XCTAssertEqual(info.supportedFeatures, ["keyring", "noteit-doc"])
        do {
            _ = try await device("W", backend, supported: [.keyring])
            XCTFail("a wave 0 build must refuse the store")
        } catch SyncError.unsupportedFeature(let name) {
            XCTAssertEqual(name, "noteit-doc")
        }
    }

    // MARK: - Publish validation

    func testBadBodyFormatAmongGoodOnesIsPerRecord() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        try await sync(a)
        let first = await a.store.create(title: "A")
        let bad = await a.store.create(title: "B")
        let third = await a.store.create(title: "C")
        for format in ["rtfd", "", "noteit-doc/2"] {
            await a.store.overrideFormat(bad, format)
            await backend.clearOps()
            let before = a.state
            let report = try await a.engine.sync()
            let ops = await backend.ops.filter { $0.key.contains(bad.uuidString) && ($0.kind == .put || $0.kind == .delete) }
            XCTAssertTrue(ops.isEmpty, "\(format): \(ops)")
            XCTAssertEqual(report.errors.count, 1, "\(format): \(report.errors)")
            XCTAssertTrue(report.errors.first?.hasPrefix("\(bad.uuidString): invalidPayload(") == true, "\(report.errors)")
            XCTAssertNil(a.state.pendingPushes[bad])
            XCTAssertEqual(a.state.bases[bad], before.bases[bad])
            if format == "rtfd" { XCTAssertEqual(report.pushed, 2) }
        }
        let keys = try await keys(memory, "notes/")
        XCTAssertTrue(keys.contains(RemoteLayout.meta(.note, first)))
        XCTAssertTrue(keys.contains(RemoteLayout.meta(.note, third)))

        await a.store.clearFormatOverride(bad)
        let fixed = try await a.engine.sync()
        XCTAssertEqual(fixed.pushed, 1)
        XCTAssertTrue(fixed.errors.isEmpty, "\(fixed.errors)")
        let env = try await envelope(memory, bad)
        XCTAssertEqual(env.bodyFormat, BodyFormat.noteItDocV1)
    }

    func testPulledEnvelopeBreakingThePairingRuleIsPerRecord() async throws {
        let backend = InMemoryBackend()
        let a = try await device("A", backend, initial: [.noteItDoc])
        let id = await a.store.create(title: "paired")
        try await sync(a)
        var env = try await envelope(backend, id)
        env.bodyVersion = nil
        try await backend.put(RemoteLayout.meta(.note, id), data: try SyncEngine.encode(env), ifMatch: nil, ifNoneMatch: false)
        let b = try await device("B", backend)
        let report = try await b.engine.sync()
        XCTAssertEqual(report.errors.count, 1)
        XCTAssertTrue(report.errors.first?.contains("invalidPayload(\"bodyVersion") == true, "\(report.errors)")
        let applied = await b.store.entries[id]
        XCTAssertNil(applied)
    }

    // MARK: - Versioned publish and reads

    func testNoteItDocPublishWritesVersionedBodyThenMeta() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let id = await a.store.create(title: "fresh")
        await backend.clearOps()
        try await sync(a)
        let writes = await backend.ops.filter { $0.kind == .put && $0.key.contains(id.uuidString) }
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes[0].key.hasPrefix(RemoteLayout.bodiesPrefix) && writes[0].key.hasSuffix(".new.body") && writes[0].ifNoneMatch)
        XCTAssertEqual(writes[1].key, RemoteLayout.meta(.note, id))
        XCTAssertTrue(writes[1].ifNoneMatch)
        let env = try await envelope(memory, id)
        XCTAssertEqual(env.bodyFormat, "noteit-doc/1")
        try await assertEqualAsync(try await bodyKeys(memory, id), [RemoteLayout.docBody(id, version: env.bodyVersion!, tag: "new")])
        XCTAssertTrue(a.state.pendingBodyVersions.isEmpty)
        XCTAssertEqual(a.state.bases[id]?.bodyVersion, env.bodyVersion)
        let pending = try? FileManager.default.contentsOfDirectory(atPath: a.stateURL.deletingLastPathComponent().appendingPathComponent("PendingBodies").path)
        XCTAssertEqual(pending ?? [], [], "the sealed bytes are cleared with the entry")

        // An edit: tag = baseTag(previous meta ETag), If-Match; the previous version is deleted (atomic store).
        let previous = env.bodyVersion!
        let previousETag = try await memory.get(RemoteLayout.meta(.note, id)).etag
        await a.store.edit(id, title: "edited")
        await backend.clearOps()
        try await sync(a)
        let edit = await backend.ops.filter { $0.key.contains(id.uuidString) && $0.kind != .get }
        XCTAssertEqual(edit.map(\.kind), [.put, .put, .delete])
        XCTAssertTrue(edit[0].key.contains(".\(RemoteLayout.baseTag(previousETag)).body"))
        XCTAssertEqual(edit[1].ifMatch, previousETag)
        XCTAssertTrue(edit[2].key.contains(previous.uuidString) && edit[2].ifMatch != nil)

        let b = try await device("B", backend)
        let report = try await b.engine.sync()
        XCTAssertEqual(report.pulled, 1)
        let title = await b.store.title(id)
        XCTAssertEqual(title, "edited")
        let format = await b.store.appliedFormats[id]
        XCTAssertEqual(format, .some("noteit-doc/1"))
        let snapA = await a.store.snapshot(), snapB = await b.store.snapshot()
        XCTAssertEqual(snapA, snapB)
    }

    // MARK: - Upgrade

    func testCleanPassUpgradesAutomatically() async throws {
        let memory = InMemoryBackend()
        try await v1Store(memory)
        let before = try await manifest(memory)
        let a = try await device("A", memory)
        let asked = CallCounter()
        await a.engine.setFeatureConfirm { _ in asked.increment(); return false }
        let id = await a.store.create(title: "before")
        try await sync(a)
        XCTAssertEqual(asked.value, 0, "no device blocks, so nobody is asked")
        let after = try await manifest(memory)
        XCTAssertEqual(after.formatVersion, 2)
        XCTAssertEqual(Set(after.features ?? []), ["noteit-doc"])
        XCTAssertEqual(after.createdAt, before.createdAt)
        XCTAssertNil(after.encryption, "a plaintext store stays plaintext")
        XCTAssertTrue(a.ref.current.features.contains(.noteItDoc))
        let env = try await envelope(memory, id)
        XCTAssertEqual(env.bodyFormat, "noteit-doc/1", "converted in the same sync() call")
        XCTAssertTrue(a.state.legacyBodies.isEmpty)
    }

    func testUpgradeKeepsUnknownManifestKeys() async throws {
        let memory = InMemoryBackend()
        try await v1Store(memory)
        let raw = try JSONSerialization.jsonObject(with: try await memory.get(RemoteLayout.manifest()).data) as! [String: Any]
        var extended = raw
        extended["futureKey"] = ["nested": true]
        try await memory.put(RemoteLayout.manifest(), data: try JSONSerialization.data(withJSONObject: extended, options: [.sortedKeys]),
                             ifMatch: nil, ifNoneMatch: false)
        let a = try await device("A", memory)
        try await sync(a)
        let upgraded = try JSONSerialization.jsonObject(with: try await memory.get(RemoteLayout.manifest()).data) as! [String: Any]
        XCTAssertEqual(upgraded["futureKey"] as? [String: Bool], ["nested": true])
        XCTAssertEqual(upgraded["features"] as? [String], ["noteit-doc"])
        XCTAssertEqual(upgraded["createdAt"] as? Double, raw["createdAt"] as? Double)
    }

    func testRekeyInProgressPostponesTheUpgrade() async throws {
        let memory = InMemoryBackend()
        try await v1Store(memory)
        var m = try await manifest(memory)
        m.formatVersion = 2
        m.rekey = Rekey(fromKeyID: nil, toKeyID: "0123456789abcdef", startedAt: Date(), updatedAt: Date(),
                        deviceID: "device-A", deviceName: "A")
        try await putManifest(m, memory)
        let a = try await device("A", memory)
        let id = await a.store.create(title: "during rekey")
        let report = try await a.engine.sync()
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        let unchanged = try await manifest(memory)
        XCTAssertNil(unchanged.features)
        try await assertNilAsync(try await envelope(memory, id).bodyFormat, "still RTFD")

        m.rekey = nil
        try await putManifest(m, memory)
        try await sync(a)
        try await assertEqualAsync(try await manifest(memory).features, ["noteit-doc"])
    }

    func testBlockingDeviceIsAskedAndADeclineWritesNothing() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        try await v1Store(memory)
        try await putDevice(memory, id: "OLD", supported: nil)
        let a = try await device("A", backend)
        let asked = CallCounter()
        let allow = Flag()
        await a.engine.setFeatureConfirm { blockers in
            asked.increment()
            XCTAssertEqual(blockers.map(\.deviceID), ["OLD"])
            return allow.value
        }
        _ = await a.store.create(title: "x")
        let declined = try await a.engine.sync()
        XCTAssertTrue(declined.errors.isEmpty)
        XCTAssertEqual(asked.value, 1)
        try await assertTrueAsync(await backend.ops(.put, containing: "manifest.json").isEmpty)
        XCTAssertFalse(a.ref.current.features.contains(.noteItDoc))

        allow.value = true
        try await sync(a)
        XCTAssertEqual(asked.value, 2)
        XCTAssertTrue(a.ref.current.features.contains(.noteItDoc))
    }

    func testErroredPassDoesNotUpgradeAndCleanPassLaterDoes() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        try await v1Store(memory)
        let a = try await device("A", backend)
        let bad = await a.store.create(title: "bad")
        await a.store.overrideFormat(bad, "rtfd")
        let report = try await a.engine.sync()
        XCTAssertEqual(report.errors.count, 1)
        try await assertTrueAsync(await backend.ops(.put, containing: "manifest.json").isEmpty)
        await a.store.clearFormatOverride(bad)
        try await sync(a)
        XCTAssertTrue(a.ref.current.features.contains(.noteItDoc))
    }

    func testPendingEditsArePublishedAsRTFDBeforeTheManifestWrite() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        try await v1Store(memory)
        let a = try await device("A", backend)
        let id = await a.store.create(title: "pending")
        try await sync(a)
        let puts = await backend.ops(.put).map(\.key)
        let legacyMeta = try XCTUnwrap(puts.firstIndex(of: RemoteLayout.meta(.note, id)), "\(puts)")
        let manifestPut = try XCTUnwrap(puts.firstIndex(of: RemoteLayout.manifest()))
        let legacyBody = try XCTUnwrap(puts.firstIndex(of: RemoteLayout.body(id)))
        XCTAssertLessThan(legacyMeta, manifestPut)
        XCTAssertLessThan(legacyBody, manifestPut)
        let ops = await backend.ops
        let manifestWrite = try XCTUnwrap(ops.firstIndex { $0.kind == .put && $0.key == RemoteLayout.manifest() })
        let manifestGet = try XCTUnwrap(ops[..<manifestWrite].lastIndex { $0.kind == .get && $0.key == RemoteLayout.manifest() })
        XCTAssertLessThan(manifestGet, manifestWrite, "read-modify-write")
        XCTAssertNotNil(ops[manifestWrite].ifMatch)
        let conversion = try XCTUnwrap(puts.firstIndex { $0.hasPrefix(RemoteLayout.bodiesPrefix) })
        XCTAssertLessThan(manifestPut, conversion, "the session is swapped before the first conversion PUT")
    }

    func testNewStoreStartsWithNoteItDocAndNeedsNoUpgrade() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let created = try await manifest(memory)
        XCTAssertEqual(created.formatVersion, 2)
        XCTAssertEqual(created.features, ["noteit-doc"])
        await backend.clearOps()
        try await sync(a)
        try await assertTrueAsync(await backend.ops(.put, containing: "manifest.json").isEmpty)

        let v1 = InMemoryBackend()
        try await v1Store(v1)
        let before = try await v1.get(RemoteLayout.manifest())
        _ = try await device("B", v1, initial: [.noteItDoc])
        let after = try await v1.get(RemoteLayout.manifest())
        XCTAssertEqual(after.data, before.data, "initialFeatures only shape a store this call creates")
    }

    func testTwoClientsUpgradingAtOnceEndWithOneWrite() async throws {
        let memory = InMemoryBackend()
        try await v1Store(memory)
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend)
        let b = try await device("B", backend)
        let engineB = b.engine
        // B upgrades between A's clean pass and A's manifest write; A's re-read adopts B's manifest.
        await a.engine.setBeforeUpgradeHook { _ = try? await engineB.sync() }
        let reportA = try await a.engine.sync()
        XCTAssertTrue(reportA.errors.isEmpty, "\(reportA.errors)")
        XCTAssertTrue(a.ref.current.features.contains(.noteItDoc))
        XCTAssertTrue(b.ref.current.features.contains(.noteItDoc))
        try await assertEqualAsync(try await manifest(memory).features, ["noteit-doc"])
        try await assertEqualAsync(await backend.ops(.put, containing: "manifest.json").count, 1, "one write, one adoption")
    }

    func testPeerRefreshesSessionBeforeProcessingRecords() async throws {
        let memory = InMemoryBackend()
        try await v1Store(memory)
        try await putDevice(memory, id: "OLD", supported: nil)
        let a = try await device("A", memory)   // declines (default), stays v1
        let b = try await device("B", memory)
        await b.engine.setFeatureConfirm { _ in true }
        let id = await a.store.create(title: "from A")
        try await sync(a)
        XCTAssertFalse(a.ref.current.features.contains(.noteItDoc))
        try await sync(b)
        XCTAssertTrue(b.ref.current.features.contains(.noteItDoc))
        await a.store.edit(id, title: "A again")
        try await sync(a)
        XCTAssertTrue(a.ref.current.features.contains(.noteItDoc), "the listed manifest ETag changed")
        try await assertEqualAsync(try await envelope(memory, id).bodyFormat, "noteit-doc/1", "exports switch to DOC")
    }

    // MARK: - Conversion

    func testConversionIsARevisionPreservingRepublish() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        try await v1Store(memory)
        try await putDevice(memory, id: "OLD", supported: nil)
        let a = try await device("A", backend)
        let b = try await device("B", backend)
        var ids: [UUID] = []
        for n in 0..<3 { ids.append(await a.store.create(title: "note \(n)")) }
        try await sync(a, b)
        var previous: [UUID: String] = [:]
        for id in ids { previous[id] = try await memory.get(RemoteLayout.meta(.note, id)).etag }
        let revisions = await a.store.records().reduce(into: [UUID: UUID]()) { $0[$1.id] = $1.revision }

        await a.engine.setFeatureConfirm { _ in true }
        await backend.clearOps()
        try await sync(a)
        for id in ids {
            let ops = await backend.ops.filter { $0.key.contains(id.uuidString) && $0.kind != .get }
            XCTAssertEqual(ops.count, 3, "\(ops)")
            XCTAssertTrue(ops[0].kind == .put && ops[0].ifNoneMatch && ops[0].key.contains(".\(RemoteLayout.baseTag(previous[id]!)).body"))
            XCTAssertTrue(ops[1].kind == .put && ops[1].key == RemoteLayout.meta(.note, id) && ops[1].ifMatch == previous[id])
            XCTAssertTrue(ops[2].kind == .delete && ops[2].key == RemoteLayout.body(id) && ops[2].ifMatch != nil)
            let env = try await envelope(memory, id)
            XCTAssertEqual(env.revision, revisions[id])
            XCTAssertNotNil(env.bodyVersion)
        }
        XCTAssertTrue(a.state.legacyBodies.isEmpty)
        try await assertTrueAsync(try await keys(memory, "notes/").allSatisfy { $0.hasSuffix(".meta") })

        let report = try await b.engine.sync()
        XCTAssertEqual(report.pulled, 3)
        XCTAssertEqual(report.conflicts, 0)
        for id in ids {
            let format = await b.store.appliedFormats[id]
            XCTAssertEqual(format, .some("noteit-doc/1"))
        }
        let snapA = await a.store.snapshot(), snapB = await b.store.snapshot()
        XCTAssertEqual(snapA, snapB)
    }

    func testConversionPreconditionFailureLeavesTheNoteForThePlanner() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        try await v1Store(memory)
        try await putDevice(memory, id: "OLD", supported: nil)
        let a = try await device("A", backend)
        let o = try await device("O", backend)   // stays v1 (declines), like an old client edit
        let id = await a.store.create(title: "shared")
        try await sync(a, o)
        await a.engine.setFeatureConfirm { _ in true }
        let storeO = o.store, engineO = o.engine
        // After A listed the store for its conversion pass, O edits and pushes X as RTFD.
        await backend.on(.put, RemoteLayout.bodiesPrefix + id.uuidString, .before({
            await storeO.edit(id, title: "O's edit")
            _ = try? await engineO.sync()
        }))
        let report = try await a.engine.sync()
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertTrue(a.state.legacyBodies.contains(id))
        XCTAssertNil(a.state.pendingPushes[id])
        // A's upload is the first body PUT for X (the hook ran O's sync while it was out).
        let ownVersion = try await XCTUnwrapAsync(await backend.ops(.put, containing: RemoteLayout.bodiesPrefix + id.uuidString).first?.key)
        try await assertFalseAsync(try await bodyKeys(memory, id).contains(ownVersion), "the uncommitted version was deleted after the definite 412")
        try await sync(a, a)
        let title = await a.store.title(id)
        XCTAssertEqual(title, "O's edit")
        try await assertEqualAsync(try await envelope(memory, id).bodyFormat, "noteit-doc/1")
        try await assertTrueAsync(await a.store.conflictCopies().isEmpty)
    }

    func testConversionOnAFolderStoreKeepsLegacyBodiesAndPreviousVersions() async throws {
        let folder = try folderBackend()
        try await v1Store(folder)
        try await putDevice(folder, id: "OLD", supported: nil)
        let a = try await device("A", folder)
        let id = await a.store.create(title: "folder note")
        try await sync(a)
        await a.engine.setFeatureConfirm { _ in true }
        try await sync(a)
        let env = try await envelope(folder, id)
        XCTAssertEqual(env.bodyFormat, "noteit-doc/1")
        let keys = try await keys(folder, "")
        XCTAssertTrue(keys.contains(RemoteLayout.body(id)), "no atomic deletes: the legacy body stays")
        try await assertEqualAsync(try await bodyKeys(folder, id).count, 1)
        await a.store.edit(id, title: "edited")
        try await sync(a)
        try await assertEqualAsync(try await bodyKeys(folder, id).count, 2, "step 6 is skipped without atomic writes")

        let b = try await device("B", folder)
        try await sync(b)
        let title = await b.store.title(id)
        XCTAssertEqual(title, "edited")
    }

    // MARK: - Crash safety

    private enum CrashPoint: CaseIterable { case beforeBodyPut, afterBodyPut, duringMetaPut, afterMetaPut, beforePreviousDelete }

    func testCrashAtEveryStepOfAnEditLeavesAConsistentStore() async throws {
        for point in CrashPoint.allCases {
            try await runCrash(point, conversion: false)
        }
    }

    func testCrashAtEveryStepOfAConversionLeavesAConsistentStore() async throws {
        for point in CrashPoint.allCases {
            try await runCrash(point, conversion: true)
        }
    }

    private func runCrash(_ point: CrashPoint, conversion: Bool) async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        if conversion { try await v1Store(memory); try await putDevice(memory, id: "OLD", supported: nil) }
        let a = try await device("A", backend, initial: conversion ? [] : [.noteItDoc])
        let b = try await device("B", backend)
        let id = await a.store.create(title: "original")
        try await sync(a, b)
        if conversion {
            await a.engine.setFeatureConfirm { _ in true }
        } else {
            await a.store.edit(id, title: "edited")
        }
        let label = "\(point) conversion=\(conversion)"
        switch point {
        case .beforeBodyPut: await backend.on(.put, RemoteLayout.bodiesPrefix, .crashDuring)
        case .afterBodyPut: await backend.on(.put, RemoteLayout.bodiesPrefix, .crashAfter)
        case .duringMetaPut: await backend.on(.put, RemoteLayout.meta(.note, id), .crashDuring)
        case .afterMetaPut: await backend.on(.put, RemoteLayout.meta(.note, id), .crashAfter)
        case .beforePreviousDelete:
            await backend.on(.delete, conversion ? RemoteLayout.body(id) : RemoteLayout.bodiesPrefix, .crashDuring)
        }
        do {
            _ = try await a.engine.sync()
            XCTFail("\(label): expected the crash")
        } catch let error as StorageError {
            XCTAssertEqual(error, testCrash, label)
        }
        let midway = try await b.engine.sync()
        XCTAssertEqual(midway.conflicts, 0, label)
        let seen = await b.store.title(id)
        let expected = conversion ? "original" : (point == .afterMetaPut || point == .beforePreviousDelete ? "edited" : "original")
        XCTAssertEqual(seen, expected, label)

        relaunch(a, backend)
        await a.engine.setFeatureConfirm { _ in true }
        await backend.clearOps()
        let resumed = try await a.engine.sync()
        XCTAssertEqual(resumed.conflicts, 0, label)
        XCTAssertTrue(resumed.errors.isEmpty, "\(label): \(resumed.errors)")
        let newVersions = await backend.ops(.put, containing: RemoteLayout.bodiesPrefix).map(\.key)
        XCTAssertLessThanOrEqual(Set(newVersions).count, 1, "\(label): never a second version for the same publish")
        try await sync(b, a, b)

        let env = try await envelope(memory, id)
        XCTAssertEqual(env.bodyFormat, "noteit-doc/1", label)
        let bodies = try await bodyKeys(memory, id)
        XCTAssertEqual(bodies.count, 1, "\(label): \(bodies)")
        XCTAssertTrue(bodies.first?.contains(env.bodyVersion!.uuidString) == true, label)
        try await assertTrueAsync(try await keys(memory, "notes/").allSatisfy { $0.hasSuffix(".meta") }, label)
        let copies = await a.store.conflictCopies().count + (await b.store.conflictCopies().count)
        XCTAssertEqual(copies, 0, label)
        let snapA = await a.store.snapshot(), snapB = await b.store.snapshot()
        XCTAssertEqual(snapA, snapB, label)
        XCTAssertTrue(a.state.pendingBodyVersions.isEmpty, label)
    }

    // MARK: - Late landing and in-doubt outcomes

    func testLateLandingCommitAfterTheSweepFailsAndIsRepublished() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let b = try await device("B", backend)
        let c = try await device("C", backend)
        let id = await a.store.create(title: "v0")
        try await sync(a, b, c)

        await a.store.edit(id, title: "A's edit")
        let held = HeldRequest()
        await backend.on(.put, RemoteLayout.meta(.note, id), .hold(held))
        _ = try await a.engine.sync()
        let entry = try XCTUnwrap(a.state.pendingBodyVersions[id])
        XCTAssertEqual(entry.phase, .inDoubt)

        await c.store.edit(id, title: "C's edit")
        try await sync(c, b)
        try await assertTrueAsync(try await bodyKeys(memory, id).allSatisfy { !$0.contains(entry.version.uuidString) },
                      "B's sweep deleted A's stale-tag version")
        let late = await held.release()
        XCTAssertEqual(late as? StorageError, .preconditionFailed(RemoteLayout.meta(.note, id)))

        let report = try await a.engine.sync()
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertNil(a.state.pendingBodyVersions[id])
        try await sync(a, b, c, a)
        let titles = await a.store.titles()
        XCTAssertTrue(titles.contains("C's edit") || titles.contains { $0.hasPrefix("C's edit (conflict") })
        XCTAssertTrue(titles.contains("A's edit") || titles.contains { $0.hasPrefix("A's edit (conflict") })
        let d = try await device("D", backend)
        let readable = try await d.engine.sync()
        XCTAssertEqual(readable.skipped, 0, "every listed meta references an existing body")
    }

    func testLiveTagIsKeptAndTheHeldCommitStillLands() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let b = try await device("B", backend, now: { Date().addingTimeInterval(30 * 86_400) })
        let id = await a.store.create(title: "v0")
        try await sync(a, b)
        await a.store.edit(id, title: "v1")
        let held = HeldRequest()
        await backend.on(.put, RemoteLayout.meta(.note, id), .hold(held))
        _ = try await a.engine.sync()
        let version = try XCTUnwrap(a.state.pendingBodyVersions[id]?.version)
        for _ in 0..<5 { try await sync(b) }
        try await assertTrueAsync(try await bodyKeys(memory, id).contains { $0.contains(version.uuidString) })
        let late = await held.release()
        XCTAssertNil(late)
        try await sync(b)
        let title = await b.store.title(id)
        XCTAssertEqual(title, "v1")
        try await sync(a)
        XCTAssertNil(a.state.pendingBodyVersions[id], "A adopts its own landed commit")
    }

    func testLostResponseThenPreconditionFailureIsAdoptedWithoutDeleting() async throws {
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let b = try await device("B", backend)
        let id = await a.store.create(title: "v0")
        try await sync(a, b)
        await a.store.edit(id, title: "v1")
        await backend.on(.put, RemoteLayout.meta(.note, id), .landThenFail)
        _ = try await a.engine.sync()
        let landed = try XCTUnwrap(a.state.pendingBodyVersions[id])
        XCTAssertEqual(landed.phase, .inDoubt)
        await backend.staleListOnce()
        await backend.clearOps()
        let report = try await a.engine.sync()
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        XCTAssertNil(a.state.pendingBodyVersions[id])
        try await assertTrueAsync(await backend.ops(.delete, containing: landed.version.uuidString).isEmpty, "our version is kept")
        try await assertEqualAsync(try await envelope(memory, id).bodyVersion, landed.version)
        try await sync(b)
        let title = await b.store.title(id)
        XCTAssertEqual(title, "v1")

        // An HTTP stack that silently replays the first attempt: the 412 is confirmed by the GET within one pass.
        await a.store.edit(id, title: "v2")
        await backend.on(.put, RemoteLayout.meta(.note, id), .replay412)
        let replayed = try await a.engine.sync()
        XCTAssertEqual(replayed.pushed, 1)
        XCTAssertNil(a.state.pendingBodyVersions[id])
        try await sync(b)
        let again = await b.store.title(id)
        XCTAssertEqual(again, "v2")
    }

    func testAmbiguousBodyUploadNeverMakesASecondVersion() async throws {
        for order in ["before next pass", "after next pass"] {
            let memory = InMemoryBackend()
            let backend = ScriptedBackend(memory)
            let a = try await device("A", backend, initial: [.noteItDoc])
            let b = try await device("B", backend)
            let id = await a.store.create(title: "v0")
            try await sync(a, b)
            await a.store.edit(id, title: "v1")
            let held = HeldRequest()
            await backend.on(.put, RemoteLayout.bodiesPrefix, .hold(held))
            _ = try await a.engine.sync()
            XCTAssertEqual(a.state.pendingBodyVersions[id]?.phase, .uploading, order)
            if order == "before next pass" { await held.release() }
            try await sync(a)
            if order == "after next pass" {
                // The re-upload already wrote the same bytes to the same key, so the late one gets 412.
                let late = await held.release()
                guard case StorageError.preconditionFailed? = late as? StorageError else { return XCTFail("\(order): \(String(describing: late))") }
            }
            try await sync(b)
            let title = await b.store.title(id)
            XCTAssertEqual(title, "v1", order)
            try await assertEqualAsync(try await bodyKeys(memory, id).count, 1, order)
        }
    }

    // MARK: - Orphan sweep

    func testOrphanSweepRules() async throws {
        let memory = InMemoryBackend()
        let a = try await device("A", memory, initial: [.noteItDoc])
        let kept = await a.store.create(title: "kept")
        let gone = await a.store.create(title: "gone")
        try await sync(a)
        let env = try await envelope(memory, kept)
        let metaETag = try await memory.get(RemoteLayout.meta(.note, kept)).etag
        // A body whose tag matches the listed meta (a live upload elsewhere), a superseded one, a stray name, a `new`
        // body of a note that has no meta yet, and a hashed-tag body of a note with no meta.
        let live = RemoteLayout.docBody(kept, version: UUID(), tag: RemoteLayout.baseTag(metaETag))
        let superseded = RemoteLayout.docBody(kept, version: UUID(), tag: RemoteLayout.baseTag("older"))
        let stray = RemoteLayout.bodiesPrefix + "garbage.txt"
        let pendingCreate = UUID()
        let creating = RemoteLayout.docBody(pendingCreate, version: UUID(), tag: RemoteLayout.newTag)
        let abandoned = RemoteLayout.docBody(UUID(), version: UUID(), tag: RemoteLayout.baseTag("x"))
        for key in [live, superseded, stray, creating, abandoned] { await memory.overwrite(key, data: Data("x".utf8)) }
        await a.store.delete(gone)
        try await sync(a)
        let left = try await keys(memory, "bodies/")
        XCTAssertTrue(left.contains(RemoteLayout.docBody(kept, version: env.bodyVersion!, tag: "new")), "referenced")
        XCTAssertTrue(left.contains(live), "live tag")
        XCTAssertTrue(left.contains(creating), "a create may still commit")
        XCTAssertFalse(left.contains(superseded))
        XCTAssertFalse(left.contains(stray))
        XCTAssertFalse(left.contains(abandoned))
        try await assertTrueAsync(try await bodyKeys(memory, gone).isEmpty, "the deleted note's body")
    }

    func testOrphanSweepWithoutAtomicWritesDeletesOnlyStrayNames() async throws {
        let memory = InMemoryBackend(atomic: false)
        let a = try await device("A", memory, initial: [.noteItDoc])
        let id = await a.store.create(title: "note")
        try await sync(a)
        let superseded = RemoteLayout.docBody(id, version: UUID(), tag: RemoteLayout.baseTag("older"))
        let stray = RemoteLayout.bodiesPrefix + "garbage.txt"
        let tombstoned = RemoteLayout.docBody(UUID(), version: UUID(), tag: RemoteLayout.baseTag("x"))
        for key in [superseded, stray, tombstoned] { await memory.overwrite(key, data: Data("x".utf8)) }
        await a.store.delete(id)
        try await sync(a)
        let left = try await keys(memory, "bodies/")
        XCTAssertFalse(left.contains(stray))
        XCTAssertTrue(left.contains(tombstoned), "the sweep deletes no body without atomic writes")
        try await assertEqualAsync(try await bodyKeys(memory, id), [], "the deleter removes the deleted note's versions itself")
    }

    // MARK: - Stores without atomic conditional deletes

    /// Security review: deleting a note removes its meta and the body versions this device knows, also on stores
    /// without atomic conditional deletes (every folder, GCS-style S3), as the v1 engine did.
    func testWithoutAtomicDeletesADeleteRemovesTheNotesContent() async throws {
        for backend: StorageBackend in [InMemoryBackend(atomic: false, atomicDelete: false),
                                        try folderBackend()] {
            let a = try await device("A", backend, initial: [.noteItDoc])
            let b = try await device("B", backend)
            let id = await a.store.create(title: "doomed")
            try await sync(a, b)
            await a.store.edit(id, title: "doomed, edited")
            try await sync(a, b)
            await a.store.delete(id)
            try await sync(a, b)
            let gone = await b.store.title(id)
            XCTAssertNil(gone, "deleted on B")
            let keys = try await keys(backend, "")
            XCTAssertFalse(keys.contains(RemoteLayout.meta(.note, id)), "the encrypted meta is gone")
            XCTAssertTrue(keys.contains(RemoteLayout.tombstone(id)))
            let left = try await bodyKeys(backend, id)
            XCTAssertEqual(left, [], "every listed version of the note, the earlier one included")
            try await sync(a, b)
            let stillGone = await b.store.title(id)
            XCTAssertNil(stillGone)
            let againA = await a.store.title(id)
            XCTAssertNil(againA)
        }
    }

    /// A leftover meta + tombstone pair (a deleter that crashed before its meta delete) still reads as deleted.
    func testWithoutAtomicDeletesALeftoverPairReadsAsDeleted() async throws {
        let memory = InMemoryBackend(atomic: false, atomicDelete: false)
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let b = try await device("B", backend)
        let id = await a.store.create(title: "doomed")
        try await sync(a, b)
        await a.store.delete(id)
        await backend.on(.delete, RemoteLayout.meta(.note, id), .crashDuring)
        do { try await sync(a) } catch {}
        try await sync(b, b)
        let gone = await b.store.title(id)
        XCTAssertNil(gone)
        XCTAssertNotNil(b.state.tombstoneBindings[id], "the next pass needs no tombstone GET")
    }

    func testWithoutAtomicDeletesAnEditRacingADeleteWins() async throws {
        let memory = InMemoryBackend(atomic: false, atomicDelete: false)
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let b = try await device("B", backend)
        let id = await a.store.create(title: "v0")
        try await sync(a, b)
        await a.store.delete(id)
        let storeB = b.store, engineB = b.engine
        await backend.on(.put, RemoteLayout.tombstone(id), .before({
            await storeB.edit(id, title: "B's edit")
            _ = try? await engineB.sync()
        }))
        try await sync(a)
        try await sync(b, a, b)
        let onA = await a.store.title(id)
        let onB = await b.store.title(id)
        XCTAssertEqual(onA, "B's edit")
        XCTAssertEqual(onB, "B's edit")
        // The meta delete is checked against the listed ETag first; B's edit moved it on, so nothing was deleted.
        let plainMetaDeletes = await backend.ops(.delete, containing: RemoteLayout.meta(.note, id)).filter { $0.ifMatch == nil }
        XCTAssertTrue(plainMetaDeletes.isEmpty, "\(plainMetaDeletes)")
    }

    func testAtomicDeletesWithoutAtomicWritesDeleteTheMetaAndTheBody() async throws {
        let memory = InMemoryBackend(atomic: false, atomicDelete: true)
        let a = try await device("A", memory, initial: [.noteItDoc])
        let id = await a.store.create(title: "doomed")
        try await sync(a)
        await a.store.delete(id)
        try await sync(a)
        let keys = try await keys(memory, "")
        XCTAssertFalse(keys.contains(RemoteLayout.meta(.note, id)))
        try await assertEqualAsync(try await bodyKeys(memory, id), [])
    }

    // MARK: - Repair

    func testOwnerRepublishesAMissingVersionWithTheSameRevision() async throws {
        let memory = InMemoryBackend()
        let a = try await device("A", memory, initial: [.noteItDoc])
        let id = await a.store.create(title: "repair me")
        try await sync(a)
        let before = try await envelope(memory, id)
        for key in try await bodyKeys(memory, id) { try await memory.delete(key) }
        try await sync(a)
        let after = try await envelope(memory, id)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertNotEqual(after.bodyVersion, before.bodyVersion)
        try await assertEqualAsync(try await bodyKeys(memory, id).count, 1)
        try await assertTrueAsync(try await keys(memory, "notes/").allSatisfy { $0.hasSuffix(".meta") }, "never a legacy body")
    }

    func testAnotherDeviceRepairsOnlyAfterTheGracePeriod() async throws {
        let memory = InMemoryBackend()
        let clock = FixedClock(Date())
        let a = try await device("A", memory, initial: [.noteItDoc])
        let id = await a.store.create(title: "orphaned")
        try await sync(a)
        let b = try await device("B", memory, now: { clock.now() })
        try await sync(b)
        for key in try await bodyKeys(memory, id) { try await memory.delete(key) }
        try await sync(b)
        try await assertTrueAsync(try await bodyKeys(memory, id).isEmpty, "B waits")
        clock.advance(SyncEngine.bodyRepairGrace + 1)
        try await sync(b)
        try await assertEqualAsync(try await bodyKeys(memory, id).count, 1)
        let c = try await device("C", memory)
        try await sync(c)
        let title = await c.store.title(id)
        XCTAssertEqual(title, "orphaned")
    }

    // MARK: - Clean up unused storage

    func testCleanupIsUnavailableWithoutAtomicWrites() async throws {
        for memory in [InMemoryBackend(atomic: false), InMemoryBackend(atomic: false, atomicDelete: false)] {
            let backend = ScriptedBackend(memory)
            let a = try await device("A", backend, initial: [.noteItDoc])
            await backend.clearOps()
            let available = await a.engine.cleanupAvailable()
            XCTAssertFalse(available)
            do {
                _ = try await a.engine.cleanUpUnusedStorage()
                XCTFail("expected cleanupUnavailable")
            } catch SyncError.cleanupUnavailable {}
            try await assertTrueAsync(await backend.ops.isEmpty, "nothing listed or sent")
        }
    }

    func testCleanupDeletesOnlyOldUnusedNewBodies() async throws {
        let clock = FixedClock(Date())
        let memory = InMemoryBackend(now: { clock.now() })
        let a = try await device("A", memory, initial: [.noteItDoc], now: { clock.now() })
        let id = await a.store.create(title: "has meta")
        try await sync(a)
        let orphan = RemoteLayout.docBody(UUID(), version: UUID(), tag: RemoteLayout.newTag)
        await memory.overwrite(orphan, data: Data("orphan".utf8))
        clock.advance(29 * 86_400)
        let young = RemoteLayout.docBody(UUID(), version: UUID(), tag: RemoteLayout.newTag)
        await memory.overwrite(young, data: Data("young".utf8))
        let early = try await a.engine.cleanUpUnusedStorage()
        XCTAssertEqual(early, CleanupReport())
        clock.advance(2 * 86_400)
        let report = try await a.engine.cleanUpUnusedStorage()
        XCTAssertEqual(report, CleanupReport(deletedObjects: 1, deletedBytes: 6))
        let left = try await keys(memory, "bodies/")
        XCTAssertFalse(left.contains(orphan))
        XCTAssertTrue(left.contains(young))
        try await assertEqualAsync(try await bodyKeys(memory, id).count, 1)

        await memory.setHidesLastModified(true)
        clock.advance(40 * 86_400)
        let unknownAge = try await a.engine.cleanUpUnusedStorage()
        XCTAssertEqual(unknownAge.deletedObjects, 0, "a body listed without lastModified is kept")
    }

    func testNoPassDeletesANewBodyOfANoteWithoutMetaOrTombstone() async throws {
        let clock = FixedClock(Date())
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let b = try await device("B", backend, now: { clock.now() })
        let id = await a.store.create(title: "held create")
        let held = HeldRequest()
        await backend.on(.put, RemoteLayout.meta(.note, id), .hold(held))
        _ = try await a.engine.sync()
        for _ in 0..<50 {
            clock.advance(86_400)
            try await sync(b)
        }
        try await assertTrueAsync(await backend.ops.filter { $0.key.contains(id.uuidString) && $0.kind == .delete }.isEmpty)
        try await assertNilAsync(await held.release())
        try await sync(b)
        let title = await b.store.title(id)
        XCTAssertEqual(title, "held create")
    }

    // MARK: Stranded bodies

    /// Devices that upload a version against the current meta and are wiped before committing it.
    private func strandBodies(of id: UUID, _ backend: ScriptedBackend, count: Int) async throws {
        for index in 1...count {
            let wiped = try await device("W\(index)", backend)
            try await sync(wiped)
            await wiped.store.edit(id, title: "lost \(index)")
            await backend.on(.put, RemoteLayout.meta(.note, id), .crashDuring)
            do {
                _ = try await wiped.engine.sync()
                XCTFail("the commit crashes")
            } catch {}
        }
    }

    func testStrandedBodiesGoStaleAfterAMetaRefreshAndTheSweepDeletesThem() async throws {
        let clock = TestClock()
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let b = try await device("B", backend, now: { clock.now() })
        let d = try await device("D", backend)
        let id = await a.store.create(title: "v0")
        try await sync(a, b, d)
        try await strandBodies(of: id, backend, count: 3)
        try await assertEqualAsync(try await bodyKeys(memory, id).count, 4)
        let listed = try await memory.list(prefix: RemoteLayout.meta(.note, id)).first?.etag

        // 20 passes, but not yet 24 hours: kept, and nothing is written.
        try await sync(b)
        XCTAssertEqual(b.state.strandedBodies.count, 3)
        clock.advance(2 * 86_400)
        for _ in 0..<19 { try await sync(b) }
        try await assertEqualAsync(try await memory.list(prefix: RemoteLayout.meta(.note, id)).first?.etag, listed)
        try await assertEqualAsync(try await bodyKeys(memory, id).count, 4)

        // The 20th pass after the bodies were first seen, and over 24 hours: the meta is refreshed, unchanged inside.
        let before = try await envelope(memory, id)
        try await sync(b)
        let refreshed = try await memory.list(prefix: RemoteLayout.meta(.note, id)).first?.etag
        XCTAssertNotEqual(refreshed, listed)
        let after = try await envelope(memory, id)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.bodyVersion, before.bodyVersion)
        XCTAssertEqual(after.bodySHA256, before.bodySHA256)
        XCTAssertEqual(b.state.bases[id]?.remoteMetaETag, refreshed)

        // The next sweep deletes the stale bodies; the committed one stays.
        try await sync(b)
        try await assertEqualAsync(try await bodyKeys(memory, id).count, 1)
        XCTAssertTrue(b.state.strandedBodies.isEmpty)

        // A refresh is not an edit: A takes the new ETag without reading the body, and D's unpushed edit is pushed
        // against it with no conflict copy.
        await backend.clearOps()
        let report = try await a.engine.sync()
        XCTAssertEqual(report.pulled, 0)
        try await assertTrueAsync(await backend.ops(.get, containing: "bodies/").isEmpty)
        XCTAssertEqual(a.state.bases[id]?.remoteMetaETag, refreshed)
        await d.store.edit(id, title: "d edit")
        let pushed = try await d.engine.sync()
        XCTAssertEqual(pushed.conflicts, 0)
        try await sync(a, b)
        for device in [a, b, d] {
            let titles = await device.store.titles()
            XCTAssertEqual(titles, ["d edit"], device.name)
        }
    }

    func testAMetaRefreshWaitsForAnUnpushedEditAndHappensAtMostFiveTimesAPass() async throws {
        let clock = TestClock()
        let memory = InMemoryBackend()
        let backend = ScriptedBackend(memory)
        let a = try await device("A", backend, initial: [.noteItDoc])
        let b = try await device("B", backend, now: { clock.now() })
        var ids: [UUID] = []
        for index in 0..<7 { ids.append(await a.store.create(title: "note \(index)")) }
        try await sync(a, b)
        for (index, id) in ids.enumerated() {
            // A fresh wiped device each time.
            let wiped = try await device("W-\(index)", backend)
            try await sync(wiped)
            await wiped.store.edit(id, title: "lost")
            await backend.on(.put, RemoteLayout.meta(.note, id), .crashDuring)
            do { _ = try await wiped.engine.sync(); XCTFail("the commit crashes") } catch {}
        }
        try await sync(b)
        clock.advance(2 * 86_400)
        for _ in 0..<19 { try await sync(b) }
        let metas = { try await memory.list(prefix: RemoteLayout.root + "notes/").filter { $0.key.hasSuffix(".meta") } }
        let listed = Dictionary(uniqueKeysWithValues: try await metas().map { ($0.key, $0.etag) })

        // Due now. B's own edit of the first note fails to push this pass: it stays unpushed, so no refresh for it.
        await b.store.edit(ids[0], title: "unpushed")
        await backend.on(.put, RemoteLayout.meta(.note, ids[0]), .failBefore)
        await backend.clearOps()
        try await sync(b)
        let firstKey = RemoteLayout.meta(.note, ids[0])
        let refreshes = await backend.ops(.put, containing: ".meta").filter { $0.key != firstKey }.count
        XCTAssertEqual(refreshes, 5, "at most five refreshes a pass")
        try await assertEqualAsync(await backend.ops(.put, containing: firstKey).count, 1, "only the failed push, no refresh")

        // The next pass pushes the edit and refreshes the last note.
        try await sync(b)
        let changed = try await metas().filter { listed[$0.key] != $0.etag }.map(\.key)
        XCTAssertEqual(changed.count, 7)
        let title = await b.store.title(ids[0])
        XCTAssertEqual(title, "unpushed")
    }
}

// XCTest's assertions take synchronous autoclosures; these await first.
func XCTUnwrapAsync<T>(_ a: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let x = try await a()
    return try XCTUnwrap(x, file: file, line: line)
}

func assertEqualAsync<T: Equatable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () async throws -> T,
                                    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a(), y = try await b()
    XCTAssertEqual(x, y, message(), file: file, line: line)
}

func assertTrueAsync(_ a: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a()
    XCTAssertTrue(x, message(), file: file, line: line)
}

func assertFalseAsync(_ a: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
                      file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a()
    XCTAssertFalse(x, message(), file: file, line: line)
}

func assertNilAsync(_ a: @autoclosure () async throws -> Any?, _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a()
    XCTAssertNil(x, message(), file: file, line: line)
}

func assertNotNilAsync(_ a: @autoclosure () async throws -> Any?, _ message: @autoclosure () -> String = "",
                       file: StaticString = #filePath, line: UInt = #line) async throws {
    let x = try await a()
    XCTAssertNotNil(x, message(), file: file, line: line)
}

func assertLessThanOrEqualAsync<T: Comparable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () async throws -> T,
                                               _ message: @autoclosure () -> String = "", file: StaticString = #filePath,
                                               line: UInt = #line) async throws {
    let x = try await a(), y = try await b()
    XCTAssertLessThanOrEqual(x, y, message(), file: file, line: line)
}

/// A thread-safe counter for closures the engine calls.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
