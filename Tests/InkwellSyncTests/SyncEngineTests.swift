import XCTest
@testable import InkwellSync

final class SyncEngineTests: XCTestCase {
    struct Device {
        let name: String
        let store: FakeLocalStore
        let stateURL: URL
        let engine: SyncEngine
    }

    private var dir: URL!
    private var memory: InMemoryBackend!
    private var faulty: FaultyBackend!
    private var cipher: SyncCipher!
    private let clock = TestClock()

    override func setUp() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dir = root.appendingPathComponent(".build/sync-engine-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory = InMemoryBackend()
        faulty = FaultyBackend(memory)
        cipher = try await SyncEngine.connect(backend: memory, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory).1
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func device(_ name: String, store: FakeLocalStore? = nil, backend: StorageBackend? = nil) -> Device {
        let stateURL = dir.appendingPathComponent("\(name).json")
        let store = store ?? FakeLocalStore()
        let clock = clock
        let engine = SyncEngine(backend: backend ?? faulty, cipher: cipher, local: store, stateURL: stateURL,
                                deviceID: "id-\(name)", deviceName: name, now: { clock.now() })
        return Device(name: name, store: store, stateURL: stateURL, engine: engine)
    }

    /// A fresh engine over the same store and state file, as after an app relaunch.
    private func relaunch(_ d: Device) -> Device { device(d.name, store: d.store) }

    @discardableResult
    private func sync(_ devices: Device..., file: StaticString = #filePath, line: UInt = #line) async throws -> [SyncReport] {
        var reports: [SyncReport] = []
        for d in devices {
            let report = try await d.engine.sync()
            reports.append(report)
        }
        return reports
    }

    private func assertConverged(_ a: Device, _ b: Device, file: StaticString = #filePath, line: UInt = #line) async {
        let sa = await a.store.snapshot()
        let sb = await b.store.snapshot()
        XCTAssertEqual(sa, sb, "record sets differ", file: file, line: line)
    }

    private func remoteKeys() async throws -> Set<String> {
        Set(try await memory.list(prefix: RemoteLayout.root).map(\.key))
    }

    private func counters() async -> (list: Int, get: Int, put: Int, delete: Int) {
        (await memory.listCount, await memory.getCount, await memory.putCount, await memory.deleteCount)
    }

    private func sealedEnvelope(_ id: UUID) async throws -> RemoteEnvelope {
        let data = try await memory.get(RemoteLayout.meta(.note, id)).data
        return try SyncEngine.decode(RemoteEnvelope.self, from: try open(data, key: RemoteLayout.meta(.note, id)))
    }

    private func seal(_ data: Data, key: String) throws -> Data {
        try cipher.seal(data, context: SyncEngine.context(key))
    }

    private func open(_ data: Data, key: String) throws -> Data {
        try cipher.open(data, context: SyncEngine.context(key))
    }

    // MARK: Basic propagation

    func testCreateOnAPullsToB() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "Hello")
        let reports = try await sync(a, b)
        XCTAssertEqual(reports[0].pushed, 1)
        XCTAssertEqual(reports[1].pulled, 1)
        let title = await b.store.title(id)
        XCTAssertEqual(title, "Hello")
        await assertConverged(a, b)
    }

    func testEditOnBReachesA() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await b.store.edit(id, title: "v2")
        try await sync(b, a)
        let title = await a.store.title(id)
        XCTAssertEqual(title, "v2")
        await assertConverged(a, b)
    }

    func testNotebooksSyncBeforeNotes() async throws {
        let a = device("A"), b = device("B")
        let nb = await a.store.create(kind: .notebook, title: "Work")
        try await sync(a, b)
        let title = await b.store.title(nb)
        XCTAssertEqual(title, "Work")
        let keys = try await remoteKeys()
        XCTAssertTrue(keys.contains(RemoteLayout.meta(.notebook, nb)))
        XCTAssertFalse(keys.contains(RemoteLayout.body(nb)))
    }

    // MARK: Conflicts

    func testConcurrentEditKeepsBothAndConverges() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.edit(id, title: "A's edit")
        await b.store.edit(id, title: "B's edit")

        try await sync(b)
        let reportA = try await a.engine.sync()
        XCTAssertEqual(reportA.conflicts, 1)
        let mine = await a.store.title(id)
        XCTAssertEqual(mine, "A's edit")
        let copies = await a.store.conflictCopies()
        XCTAssertEqual(copies.map(\.title), ["B's edit (conflict — B)"])

        try await sync(b)
        await assertConverged(a, b)

        // Further rounds are stable and never produce another copy.
        try await sync(a, b, a, b)
        await assertConverged(a, b)
        let copiesA = await a.store.conflictCopies().count
        let copiesB = await b.store.conflictCopies().count
        XCTAssertEqual(copiesA, 1)
        XCTAssertEqual(copiesB, 1)
        let titles = await b.store.titles()
        XCTAssertEqual(titles, ["A's edit", "B's edit (conflict — B)"])
    }

    func testIndependentCreationWithSameIDIsAConflictNotAnOverwrite() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "A original")
        try await sync(a)
        let payload = try await a.store.export(id, kind: .note)
        var other = payload
        other.revision = UUID()
        other.meta = try JSONEncoder().encode(FakeLocalStore.Meta(title: "B original"))
        other.body = FakeLocalStore.body(for: "B original")
        try await b.store.apply(other)

        try await sync(b, a, b)
        await assertConverged(a, b)
        let titles = await a.store.titles()
        XCTAssertEqual(titles, ["B original", "A original (conflict — A)"])
    }

    func testConcurrentNotebookRenameLastWriterWins() async throws {
        let a = device("A"), b = device("B")
        let nb = await a.store.create(kind: .notebook, title: "Inbox")
        try await sync(a, b)
        await a.store.edit(nb, title: "From A")
        try await Task.sleep(nanoseconds: 5_000_000)
        await b.store.edit(nb, title: "From B (later)")

        try await sync(b, a, b)
        await assertConverged(a, b)
        let title = await a.store.title(nb)
        XCTAssertEqual(title, "From B (later)")
        let copies = await a.store.conflictCopies().count
        XCTAssertEqual(copies, 0)

        // The other order: the earlier writer syncs last and still loses.
        await b.store.edit(nb, title: "B first")
        try await Task.sleep(nanoseconds: 5_000_000)
        await a.store.edit(nb, title: "A later")
        try await sync(b, a, b)
        await assertConverged(a, b)
        let title2 = await b.store.title(nb)
        XCTAssertEqual(title2, "A later")
    }

    func testRepushAfterPreconditionFailed() async throws {
        let a = device("A", backend: memory), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.edit(id, title: "A wins the race")
        await b.store.edit(id, title: "B loses the race")

        // A pushes between B's list and B's first write for this note.
        let engineA = a.engine
        await faulty.onNextPut(keyContaining: id.uuidString, .before({ _ = try? await engineA.sync() }))
        let first = try await b.engine.sync()
        XCTAssertEqual(first.skipped, 1)
        XCTAssertEqual(first.pushed, 0)
        let envelope = try await sealedEnvelope(id)
        XCTAssertEqual(envelope.deviceName, "A", "B must not overwrite A's meta")
        let body = try await memory.get(RemoteLayout.body(id)).data
        XCTAssertEqual(try open(body, key: RemoteLayout.body(id)), FakeLocalStore.body(for: "A wins the race"), "B must not overwrite A's body")

        let second = try await b.engine.sync()
        XCTAssertEqual(second.conflicts, 1)
        try await sync(a, b, a)
        await assertConverged(a, b)
        let titles = await a.store.titles()
        XCTAssertEqual(titles, ["B loses the race", "A wins the race (conflict — A)"])
    }

    func testConflictCopyNotDuplicatedWhenPushFailsAfterImport() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.edit(id, title: "A edit")
        await b.store.edit(id, title: "B edit")
        try await sync(a)

        await faulty.onNextPut(keyContaining: "\(id.uuidString).meta", .failBefore)
        let failed = try await b.engine.sync()
        XCTAssertEqual(failed.conflicts, 1)
        XCTAssertFalse(failed.errors.isEmpty)

        let retry = try await relaunch(b).engine.sync()
        XCTAssertEqual(retry.conflicts, 0)
        let copies = await b.store.conflictCopies().count
        XCTAssertEqual(copies, 1)

        try await sync(a, b, a)
        await assertConverged(a, b)
        let copiesA = await a.store.conflictCopies().count
        XCTAssertEqual(copiesA, 1)
    }

    // MARK: Interrupted passes

    func testCrashAfterMetaPutBeforeBodyPutIsIdempotent() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.edit(id, title: "v2")

        await faulty.onNextPut(keyContaining: "\(id.uuidString).body", .failBefore)
        _ = try await a.engine.sync()
        // Remote meta is new, body is old: B must not pull a mismatched pair.
        let midway = try await b.engine.sync()
        XCTAssertEqual(midway.skipped, 1)
        let stale = await b.store.title(id)
        XCTAssertEqual(stale, "v1")

        let resumed = try await relaunch(a).engine.sync()
        XCTAssertEqual(resumed.conflicts, 0)
        XCTAssertTrue(resumed.errors.isEmpty, "\(resumed.errors)")
        try await sync(b)
        await assertConverged(a, b)
        let copies = await a.store.conflictCopies().count + (await b.store.conflictCopies().count)
        XCTAssertEqual(copies, 0)
        let title = await b.store.title(id)
        XCTAssertEqual(title, "v2")
    }

    /// The first push of a new note fails after its meta landed, then the user keeps editing (E1).
    func testInterruptedFirstPushThenEditIsNotStuck() async throws {
        let a = device("A"), b = device("B")
        let unsent = await a.store.create(title: "v1")
        let unsaved = await a.store.create(title: "w1")
        await faulty.onNextPut(keyContaining: "\(unsent.uuidString).body", .failBefore)
        await faulty.onNextPut(keyContaining: "\(unsaved.uuidString).body", .failAfter)
        _ = try await a.engine.sync()
        await a.store.edit(unsent, title: "v2")
        await a.store.edit(unsaved, title: "w2")

        let resumed = try await relaunch(a).engine.sync()
        XCTAssertEqual(resumed.pushed, 2)
        XCTAssertEqual(resumed.skipped, 0)
        XCTAssertEqual(resumed.conflicts, 0)
        try await sync(b, a)
        let first = await b.store.title(unsent)
        let second = await b.store.title(unsaved)
        XCTAssertEqual(first, "v2")
        XCTAssertEqual(second, "w2")
        let copies = await a.store.conflictCopies().count + (await b.store.conflictCopies().count)
        XCTAssertEqual(copies, 0)
        await assertConverged(a, b)
    }

    func testCrashAfterBodyPutBeforeStateSaveIsIdempotent() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.edit(id, title: "v2")

        await faulty.onNextPut(keyContaining: "\(id.uuidString).body", .failAfter)
        _ = try await a.engine.sync()
        let before = await counters()
        let resumed = try await relaunch(a).engine.sync()
        let after = await counters()
        XCTAssertEqual(resumed.conflicts, 0)
        XCTAssertEqual(resumed.pushed, 0)
        XCTAssertEqual(after.put - before.put, 0, "nothing needs re-uploading")

        try await sync(b, a)
        await assertConverged(a, b)
        let copies = await a.store.conflictCopies().count + (await b.store.conflictCopies().count)
        XCTAssertEqual(copies, 0)
    }

    func testCrashAfterMetaPutThenFurtherLocalEditPushesWithoutCopy() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.edit(id, title: "v2")
        await faulty.onNextPut(keyContaining: "\(id.uuidString).meta", .failAfter)
        _ = try await a.engine.sync()
        await a.store.edit(id, title: "v3")

        let resumed = try await relaunch(a).engine.sync()
        XCTAssertEqual(resumed.conflicts, 0)
        XCTAssertEqual(resumed.pushed, 1)
        try await sync(b)
        await assertConverged(a, b)
        let title = await b.store.title(id)
        XCTAssertEqual(title, "v3")
    }

    func testCrashOnFirstUploadOfNewNote() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "fresh")
        await faulty.onNextPut(keyContaining: "\(id.uuidString).meta", .failAfter)
        _ = try await a.engine.sync()
        let resumed = try await relaunch(a).engine.sync()
        XCTAssertEqual(resumed.conflicts, 0)
        try await sync(b)
        await assertConverged(a, b)
    }

    func testFailNextPutsMidPassConvergesWithoutDuplicates() async throws {
        let a = device("A"), b = device("B")
        for i in 0..<5 { await a.store.create(title: "note \(i)") }
        try await sync(a)
        await memory.failNextPuts(1)
        let partial = try await a.engine.sync()
        XCTAssertEqual(partial.errors.count, 0, "nothing to push, the failure is unused")

        for i in 5..<10 { await a.store.create(title: "note \(i)") }
        await memory.failNextPuts(3)
        let failing = try await a.engine.sync()
        XCTAssertFalse(failing.errors.isEmpty)
        try await sync(b, a, b)
        await assertConverged(a, b)
        let count = await b.store.entries.count
        XCTAssertEqual(count, 10)
        let copies = await a.store.conflictCopies().count + (await b.store.conflictCopies().count)
        XCTAssertEqual(copies, 0)
    }

    func testBodySHAMismatchIsSkippedThenPulledOnceFixed() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "real")
        try await sync(a)
        let goodBody = try await memory.get(RemoteLayout.body(id)).data
        try await memory.put(RemoteLayout.body(id), data: try seal(Data("half uploaded".utf8), key: RemoteLayout.body(id)), ifMatch: nil, ifNoneMatch: false)

        let skipped = try await b.engine.sync()
        XCTAssertEqual(skipped.skipped, 1)
        XCTAssertEqual(skipped.pulled, 0)
        let missing = await b.store.title(id)
        XCTAssertNil(missing)

        try await memory.put(RemoteLayout.body(id), data: goodBody, ifMatch: nil, ifNoneMatch: false)
        let fixed = try await b.engine.sync()
        XCTAssertEqual(fixed.pulled, 1)
        await assertConverged(a, b)
    }

    // MARK: Deletions

    func testDeleteOnAPropagatesToB() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "doomed")
        try await sync(a, b)
        await a.store.delete(id)
        try await sync(a, b)
        let gone = await b.store.title(id)
        XCTAssertNil(gone)
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(RemoteLayout.meta(.note, id)))
        XCTAssertFalse(keys.contains(RemoteLayout.body(id)))
        XCTAssertTrue(keys.contains(RemoteLayout.tombstone(id)))
        let journal = await a.store.journaledDeletions()
        XCTAssertTrue(journal.isEmpty)
        await assertConverged(a, b)
    }

    func testDeleteOnAWhileBEditsAfterBaseSurvivesOnBoth() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        // B's edit is older than A's deletion, but A never saw it: it must not be lost.
        await b.store.edit(id, title: "B kept writing")
        try await Task.sleep(nanoseconds: 5_000_000)
        await a.store.delete(id)
        try await sync(a, b, a)
        let onA = await a.store.title(id)
        let onB = await b.store.title(id)
        XCTAssertEqual(onA, "B kept writing")
        XCTAssertEqual(onB, "B kept writing")
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(RemoteLayout.tombstone(id)))
        try await sync(b, a)
        await assertConverged(a, b)
    }

    func testDeleteOnAAfterRemoteEditPullsInsteadOfDeleting() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await b.store.edit(id, title: "B edit")
        try await sync(b)
        await a.store.delete(id)
        try await sync(a)
        let restored = await a.store.title(id)
        XCTAssertEqual(restored, "B edit")
        let journal = await a.store.journaledDeletions()
        XCTAssertTrue(journal.isEmpty)
        try await sync(b, a)
        await assertConverged(a, b)
    }

    /// B edits and runs a whole pass after A decided to delete but before A deletes anything.
    func testDeletionRacingAnEditKeepsTheEditOnBothDevices() async throws {
        let a = device("A"), b = device("B", backend: memory)
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.delete(id)
        let storeB = b.store, engineB = b.engine
        await faulty.onNextDelete(keyContaining: "\(id.uuidString).meta", .before({
            await storeB.edit(id, title: "B's edit")
            _ = try? await engineB.sync()
        }))
        _ = try await a.engine.sync()
        try await sync(b, a, b, a)
        let onA = await a.store.title(id)
        let onB = await b.store.title(id)
        XCTAssertEqual(onA, "B's edit")
        XCTAssertEqual(onB, "B's edit")
        let journal = await a.store.journaledDeletions()
        XCTAssertTrue(journal.isEmpty)
        let keys = try await remoteKeys()
        XCTAssertTrue(keys.contains(RemoteLayout.meta(.note, id)))
        XCTAssertFalse(keys.contains(RemoteLayout.tombstone(id)))
        await assertConverged(a, b)
    }

    /// B's conditional push lands after A decided but before A writes anything.
    func testDeletionRacingAnEarlierEditKeepsTheEdit() async throws {
        let a = device("A"), b = device("B", backend: memory)
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.delete(id)
        let storeB = b.store, engineB = b.engine
        await faulty.onNextPut(keyContaining: "tombstones/\(id.uuidString)", .before({
            await storeB.edit(id, title: "B's edit")
            _ = try? await engineB.sync()
        }))
        _ = try await a.engine.sync()
        try await sync(b, a, b, a)
        let onA = await a.store.title(id)
        let onB = await b.store.title(id)
        XCTAssertEqual(onA, "B's edit")
        XCTAssertEqual(onB, "B's edit")
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(RemoteLayout.tombstone(id)))
        await assertConverged(a, b)
    }

    /// A provider that ignores If-Match on DELETE removes B's edit; the tombstone tells B the deleter never saw it.
    func testIgnoredConditionalDeleteStillKeepsTheEdit() async throws {
        let a = device("A"), b = device("B", backend: memory)
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await a.store.delete(id)
        await faulty.ignoreDeleteIfMatch()
        let storeB = b.store, engineB = b.engine
        await faulty.onNextPut(keyContaining: "tombstones/\(id.uuidString)", .before({
            await storeB.edit(id, title: "B's edit")
            _ = try? await engineB.sync()
        }))
        _ = try await a.engine.sync()
        let midway = try await remoteKeys()
        XCTAssertFalse(midway.contains(RemoteLayout.meta(.note, id)), "the unconditional delete removed B's edit")

        try await sync(b, a, b, a)
        let onA = await a.store.title(id)
        let onB = await b.store.title(id)
        XCTAssertEqual(onB, "B's edit")
        XCTAssertEqual(onA, "B's edit")
        await assertConverged(a, b)
    }

    func testCrashAfterTombstoneWriteStillDeletesEverywhere() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "doomed")
        try await sync(a, b)
        await a.store.delete(id)
        await faulty.onNextDelete(keyContaining: "\(id.uuidString).meta", .failBefore)
        let failed = try await a.engine.sync()
        XCTAssertFalse(failed.errors.isEmpty)
        let midway = try await remoteKeys()
        XCTAssertTrue(midway.contains(RemoteLayout.tombstone(id)), "the tombstone is written first")

        try await sync(b, relaunch(a))
        let gone = await b.store.title(id)
        XCTAssertNil(gone)
        let journal = await a.store.journaledDeletions()
        XCTAssertTrue(journal.isEmpty)
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(RemoteLayout.meta(.note, id)))
        XCTAssertFalse(keys.contains(RemoteLayout.body(id)))
        XCTAssertTrue(keys.contains(RemoteLayout.tombstone(id)))
    }

    func testDeletedOnBothSidesForgets() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "x")
        try await sync(a, b)
        await a.store.delete(id)
        await b.store.delete(id)
        try await sync(a, b, a)
        let journalB = await b.store.journaledDeletions()
        XCTAssertTrue(journalB.isEmpty)
        let state = SyncState.load(from: b.stateURL)
        XCTAssertNil(state.bases[id])
    }

    func testLongOfflineDeviceDoesNotResurrectUneditedNote() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "old")
        let keep = await a.store.create(title: "keep")
        try await sync(a, b)
        await a.store.delete(id)
        try await sync(a)
        clock.advance(31 * 24 * 3600)
        try await sync(a)
        let swept = try await remoteKeys()
        XCTAssertFalse(swept.contains(RemoteLayout.tombstone(id)), "tombstone swept after 30 days")
        XCTAssertTrue(SyncState.load(from: a.stateURL).knownTombstones.isEmpty, "nothing reads it, so it must not grow")

        try await sync(b, a)
        let gone = await b.store.title(id)
        XCTAssertNil(gone)
        let kept = await b.store.title(keep)
        XCTAssertEqual(kept, "keep")
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(RemoteLayout.meta(.note, id)))
        await assertConverged(a, b)
    }

    func testLongOfflineDeviceResurrectsNoteItEditedAfterBase() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "old")
        try await sync(a, b)
        await b.store.edit(id, title: "edited offline")
        await a.store.delete(id)
        try await sync(a)
        clock.advance(31 * 24 * 3600)
        try await sync(a)
        try await sync(b, a)
        let onA = await a.store.title(id)
        XCTAssertEqual(onA, "edited offline")
        await assertConverged(a, b)
    }

    func testOfflineDeviceWithTombstoneStillPresentAppliesDeletion() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "x")
        try await sync(a, b)
        await a.store.delete(id)
        try await sync(a)
        clock.advance(10 * 24 * 3600)
        try await sync(b, a)
        let gone = await b.store.title(id)
        XCTAssertNil(gone)
        let before = await counters()
        try await sync(b)
        let after = await counters()
        XCTAssertEqual(after.get - before.get, 0, "an already-applied tombstone is never fetched again")
    }

    func testRemoteMetaNewerThanTombstoneWins() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "alive")
        try await sync(a, b)
        let envelope = try await sealedEnvelope(id)
        let stale = Tombstone(id: id, kind: .note, deletedAt: envelope.modifiedAt - 60, deviceID: "ghost")
        try await memory.put(RemoteLayout.tombstone(id), data: try seal(try SyncEngine.encode(stale), key: RemoteLayout.tombstone(id)), ifMatch: nil, ifNoneMatch: false)

        try await sync(b, a)
        let onB = await b.store.title(id)
        let onA = await a.store.title(id)
        XCTAssertEqual(onB, "alive")
        XCTAssertEqual(onA, "alive")
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(RemoteLayout.tombstone(id)))
        XCTAssertTrue(keys.contains(RemoteLayout.meta(.note, id)))
    }

    func testTombstoneNewerThanRemoteMetaWins() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "dead")
        try await sync(a, b)
        let envelope = try await sealedEnvelope(id)
        let fresh = Tombstone(id: id, kind: .note, deletedAt: envelope.modifiedAt + 60, deviceID: "ghost")
        try await memory.put(RemoteLayout.tombstone(id), data: try seal(try SyncEngine.encode(fresh), key: RemoteLayout.tombstone(id)), ifMatch: nil, ifNoneMatch: false)

        try await sync(b, a)
        let onB = await b.store.title(id)
        let onA = await a.store.title(id)
        XCTAssertNil(onB)
        XCTAssertNil(onA)
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(RemoteLayout.meta(.note, id)))
        XCTAssertFalse(keys.contains(RemoteLayout.body(id)))
    }

    func testTombstoneNewerThanMetaStillKeepsUnsyncedLocalEdit() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        await b.store.edit(id, title: "unsynced edit")
        let envelope = try await sealedEnvelope(id)
        let fresh = Tombstone(id: id, kind: .note, deletedAt: envelope.modifiedAt + 3600, deviceID: "ghost")
        try await memory.put(RemoteLayout.tombstone(id), data: try seal(try SyncEngine.encode(fresh), key: RemoteLayout.tombstone(id)), ifMatch: nil, ifNoneMatch: false)
        try await sync(b, a)
        let onA = await a.store.title(id)
        XCTAssertEqual(onA, "unsynced edit")
    }

    // MARK: Encryption and connect

    func testRemoteBytesNeverContainPlaintext() async throws {
        let a = device("A"), b = device("B")
        let marker = "SECRET-MARKER-7f3a"
        let nb = await a.store.create(kind: .notebook, title: "\(marker) notebook")
        let id = await a.store.create(title: "\(marker) note")
        try await sync(a, b)
        await a.store.delete(nb)
        try await sync(a)
        _ = id
        for object in try await memory.list(prefix: "") {
            let data = try await memory.get(object.key).data
            XCTAssertNil(data.range(of: Data(marker.utf8)), "plaintext in \(object.key)")
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(marker))
        }
        let devices = try await b.engine.devices()
        XCTAssertEqual(devices.map(\.name), ["A", "B"])
    }

    func testConnectCreatesEncryptedManifestAndReconnects() async throws {
        let backend = InMemoryBackend()
        let (manifest, _) = try await SyncEngine.connect(backend: backend, passphrase: "secret", encryptNew: true, makeCipher: XORTestCipher.factory)
        let encryption = try XCTUnwrap(manifest.encryption)
        XCTAssertEqual(encryption.iterations, 210_000)
        XCTAssertEqual(encryption.salt.count, 16)
        let (again, cipher) = try await SyncEngine.connect(backend: backend, passphrase: "secret", encryptNew: false, makeCipher: XORTestCipher.factory)
        XCTAssertEqual(again, manifest)
        XCTAssertEqual(try cipher.open(try cipher.seal(Data("x".utf8), context: "c"), context: "c"), Data("x".utf8))
    }

    func testConnectWithWrongPassphraseThrows() async throws {
        do {
            _ = try await SyncEngine.connect(backend: memory, passphrase: "not pw", encryptNew: true, makeCipher: XORTestCipher.factory)
            XCTFail("expected wrongPassphrase")
        } catch let error as SyncError {
            XCTAssertEqual(error, .wrongPassphrase)
        }
    }

    func testConnectToEncryptedStoreWithoutPassphraseThrows() async throws {
        do {
            _ = try await SyncEngine.connect(backend: memory, passphrase: nil, encryptNew: false, makeCipher: XORTestCipher.factory)
            XCTFail("expected passphraseRequired")
        } catch let error as SyncError {
            XCTAssertEqual(error, .passphraseRequired)
        }
    }

    func testConnectRejectsNewerFormat() async throws {
        let backend = InMemoryBackend()
        try await backend.put(RemoteLayout.manifest(), data: try SyncEngine.encode(Manifest(formatVersion: 2)), ifMatch: nil, ifNoneMatch: true)
        do {
            _ = try await SyncEngine.connect(backend: backend, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
            XCTFail("expected unsupportedFormat")
        } catch let error as SyncError {
            XCTAssertEqual(error, .unsupportedFormat(2))
        }
    }

    func testConnectRejectsInvalidManifest() async throws {
        let salt = Data(repeating: 7, count: 16)
        let cases: [(Manifest.Encryption, String)] = [
            (.init(salt: salt, iterations: 0, keyCheck: Data([1])), "zero iterations"),
            (.init(salt: salt, iterations: -5, keyCheck: Data([1])), "negative iterations"),
            (.init(salt: salt, iterations: Int(UInt32.max) + 1, keyCheck: Data([1])), "iterations above UInt32.max"),
            (.init(salt: salt, iterations: 50_000_000, keyCheck: Data([1])), "huge iterations"),
            (.init(salt: salt, iterations: 99_999, keyCheck: Data([1])), "too few iterations"),
            (.init(salt: Data(count: 15), iterations: 210_000, keyCheck: Data([1])), "short salt"),
            (.init(salt: salt, iterations: 210_000, keyCheck: Data()), "empty key check"),
        ]
        for (encryption, label) in cases {
            let backend = InMemoryBackend()
            try await backend.put(RemoteLayout.manifest(), data: try SyncEngine.encode(Manifest(encryption: encryption)), ifMatch: nil, ifNoneMatch: true)
            do {
                _ = try await SyncEngine.connect(backend: backend, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
                XCTFail("expected invalidManifest for \(label)")
            } catch SyncError.invalidManifest {
            } catch {
                XCTFail("unexpected \(error) for \(label)")
            }
        }
    }

    func testPublicConnectRejectsZeroIterationsWithoutTrapping() async throws {
        let backend = InMemoryBackend()
        let encryption = Manifest.Encryption(salt: Data(repeating: 1, count: 16), iterations: 0, keyCheck: Data([1, 2, 3]))
        try await backend.put(RemoteLayout.manifest(), data: try SyncEngine.encode(Manifest(encryption: encryption)), ifMatch: nil, ifNoneMatch: true)
        do {
            _ = try await SyncEngine.connect(backend: backend, passphrase: "pw", encryptNew: true)
            XCTFail("expected invalidManifest")
        } catch SyncError.invalidManifest {}
    }

    func testTombstoneForAnotherRecordIsIgnored() async throws {
        let a = device("A"), b = device("B")
        let x = await a.store.create(title: "x")
        let y = await a.store.create(title: "y")
        try await sync(a, b)
        let forged = Tombstone(id: x, kind: .note, deletedAt: Date().addingTimeInterval(3600), deviceID: "ghost")
        try await memory.delete(RemoteLayout.meta(.note, y))
        try await memory.put(RemoteLayout.tombstone(y), data: try seal(try SyncEngine.encode(forged), key: RemoteLayout.tombstone(y)), ifMatch: nil, ifNoneMatch: false)
        let report = try await b.engine.sync()
        XCTAssertFalse(report.errors.isEmpty)
        let survivor = await b.store.title(y)
        XCTAssertEqual(survivor, "y")
    }

    func testConnectPlaintextStore() async throws {
        let backend = InMemoryBackend()
        let (manifest, cipher) = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false, makeCipher: XORTestCipher.factory)
        XCTAssertNil(manifest.encryption)
        XCTAssertEqual(try cipher.seal(Data("plain".utf8), context: "c"), Data("plain".utf8))
        do {
            _ = try await SyncEngine.connect(backend: backend, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
            XCTFail("expected encryptionMismatch")
        } catch let error as SyncError {
            XCTAssertEqual(error, .encryptionMismatch)
        }
    }

    func testConnectRaceJoinsTheStoreCreatedFirst() async throws {
        let inner = InMemoryBackend()
        let racing = FaultyBackend(inner)
        await racing.onNextPut(keyContaining: "manifest.json", .before({
            _ = try? await SyncEngine.connect(backend: inner, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
        }))
        let (manifest, _) = try await SyncEngine.connect(backend: racing, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
        let stored = try SyncEngine.decode(Manifest.self, from: try await inner.get(RemoteLayout.manifest()).data)
        XCTAssertEqual(manifest, stored)
    }

    func testConnectReportsWhetherItCreatedTheStore() async throws {
        let backend = InMemoryBackend()
        let first = try await SyncEngine.connectReportingCreation(backend: backend, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
        XCTAssertTrue(first.created)
        let second = try await SyncEngine.connectReportingCreation(backend: backend, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
        XCTAssertFalse(second.created)
        XCTAssertEqual(first.manifest, second.manifest)

        let inner = InMemoryBackend()
        let racing = FaultyBackend(inner)
        await racing.onNextPut(keyContaining: "manifest.json", .before({
            _ = try? await SyncEngine.connect(backend: inner, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
        }))
        let joined = try await SyncEngine.connectReportingCreation(backend: racing, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory)
        XCTAssertFalse(joined.created)
    }

    func testPlaintextStoreSyncsWithPassthroughCipher() async throws {
        let backend = InMemoryBackend()
        _ = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false, makeCipher: XORTestCipher.factory)
        let storeA = FakeLocalStore(), storeB = FakeLocalStore()
        let a = SyncEngine(backend: backend, cipher: TestPassthroughCipher(), local: storeA, stateURL: dir.appendingPathComponent("pa.json"), deviceID: "pa", deviceName: "PA")
        let b = SyncEngine(backend: backend, cipher: TestPassthroughCipher(), local: storeB, stateURL: dir.appendingPathComponent("pb.json"), deviceID: "pb", deviceName: "PB")
        let id = await storeA.create(title: "plain")
        _ = try await a.sync()
        _ = try await b.sync()
        let title = await storeB.title(id)
        XCTAssertEqual(title, "plain")
    }

    // MARK: Fatal errors and devices

    func testMissingManifestAbortsWithoutDeletingAnything() async throws {
        let a = device("A")
        let id = await a.store.create(title: "precious")
        try await sync(a)
        for object in try await memory.list(prefix: RemoteLayout.root) { try await memory.delete(object.key) }
        do {
            _ = try await a.engine.sync()
            XCTFail("expected a fatal error")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound(RemoteLayout.manifest()))
        }
        let title = await a.store.title(id)
        XCTAssertEqual(title, "precious")
    }

    func testUnauthorizedAbortsPass() async throws {
        let a = device("A"), b = device("B")
        await a.store.create(title: "x")
        try await sync(a)
        await faulty.rejectGets()
        do {
            _ = try await b.engine.sync()
            XCTFail("expected unauthorized")
        } catch let error as StorageError {
            XCTAssertEqual(error, .unauthorized("denied"))
        }
    }

    func testClockSkewAndBlockedHTTPAbortPass() async throws {
        let a = device("A")
        await a.store.create(title: "x")
        try await sync(a)
        for error in [StorageError.clockSkew("RequestTimeTooSkewed"), .insecureConnectionBlocked("ATS")] {
            let inner = FaultyBackend(memory)
            await inner.rejectGets(with: error)
            let b = device("B-\(error)", backend: inner)
            do {
                _ = try await b.engine.sync()
                XCTFail("expected \(error)")
            } catch let thrown as StorageError {
                XCTAssertEqual(thrown, error)
            }
        }
    }

    func testDeviceRecordIsThrottledToTenMinutes() async throws {
        let a = device("A")
        try await sync(a)
        let key = RemoteLayout.device("id-A")
        let first = try await memory.get(key).etag
        try await sync(a)
        let second = try await memory.get(key).etag
        XCTAssertEqual(first, second)
        clock.advance(11 * 60)
        try await sync(a)
        let third = try await memory.get(key).etag
        XCTAssertNotEqual(second, third)
    }

    func testConcurrentSyncCallsAreSerialized() async throws {
        let a = device("A"), b = device("B")
        for i in 0..<20 { await a.store.create(title: "n\(i)") }
        async let r1 = a.engine.sync()
        async let r2 = a.engine.sync()
        let (x, y) = try await (r1, r2)
        XCTAssertEqual(x.pushed + y.pushed, 20)
        XCTAssertTrue(x.errors.isEmpty && y.errors.isEmpty)
        try await sync(b)
        await assertConverged(a, b)
    }

    // MARK: Performance

    func testUnchangedSecondPassWith500NotesDoesOneListAndNothingElse() async throws {
        let a = device("A"), b = device("B")
        for i in 0..<500 { await a.store.create(title: "note \(i)") }
        try await sync(a, b)
        let count = await b.store.entries.count
        XCTAssertEqual(count, 500)

        for d in [a, b] {
            let before = await counters()
            let report = try await d.engine.sync()
            let after = await counters()
            XCTAssertEqual(after.list - before.list, 1)
            XCTAssertEqual(after.get - before.get, 0)
            XCTAssertEqual(after.put - before.put, 0)
            XCTAssertEqual(after.delete - before.delete, 0)
            XCTAssertEqual(report, SyncReport())
        }
    }

    // MARK: Sync-tool sidecars and orphaned bodies

    private func sidecarKey(_ id: UUID, _ suffix: String, folder: String = "notes") -> String {
        "\(RemoteLayout.root)\(folder)/\(id.uuidString)\(suffix)"
    }

    /// Writes a sidecar envelope as a sync tool would: the bytes of another device's canonical object under a renamed key.
    private func writeSidecar(_ id: UUID, kind: RecordKind = .note, title: String, modifiedAt: Date = Date(), suffix: String) async throws {
        let meta = try JSONEncoder().encode(FakeLocalStore.Meta(title: title))
        let body = kind == .note ? FakeLocalStore.body(for: title) : nil
        let envelope = RemoteEnvelope(id: id, kind: kind, revision: UUID(), modifiedAt: modifiedAt, deviceID: "id-C",
                                      deviceName: "C", meta: meta, bodySHA256: body.map(SyncEngine.sha256Hex))
        let folder = kind == .note ? "notes" : "notebooks"
        let ext = kind == .note ? ".meta" : ".json"
        try await memory.put(sidecarKey(id, suffix + ext, folder: folder),
                             data: try seal(try SyncEngine.encode(envelope), key: RemoteLayout.meta(kind, id)), ifMatch: nil, ifNoneMatch: false)
        if let body {
            try await memory.put(sidecarKey(id, suffix + ".body"), data: try seal(body, key: RemoteLayout.body(id)), ifMatch: nil, ifNoneMatch: false)
        }
    }

    func testRemoteIndexRecognisesSyncToolConflictNames() {
        let id = UUID()
        let u = id.uuidString
        let names = [
            "notes/\(u) 2.meta", "notes/\(u) (conflicted copy 2026-10-12 10.01.02).meta",
            "notes/\(u).sync-conflict-20261012-100102-ABCDEFG.meta", "notes/\(u) 2.body",
            "notebooks/\(u) 2.json", "notes/\(u) 2.txt",
        ]
        let canonical = ["notes/\(u).meta", "notes/\(u).body", "notebooks/\(u).json", "tombstones/\(u) 2.json", "notes/readme.meta"]
        let index = RemoteIndex((names + canonical).map { RemoteObject(key: RemoteLayout.root + $0, etag: "e", size: 1) })
        XCTAssertEqual(index.sidecars.map(\.key).sorted(), names.map { RemoteLayout.root + $0 }.sorted())
        XCTAssertTrue(index.sidecars.allSatisfy { $0.id == id })
        let roles = Dictionary(uniqueKeysWithValues: index.sidecars.map { (String($0.key.dropFirst(RemoteLayout.root.count)), $0.role) })
        XCTAssertEqual(roles["notes/\(u) 2.meta"], .meta(.note))
        XCTAssertEqual(roles["notes/\(u).sync-conflict-20261012-100102-ABCDEFG.meta"], .meta(.note))
        XCTAssertEqual(roles["notes/\(u) 2.body"], .body)
        XCTAssertEqual(roles["notebooks/\(u) 2.json"], .meta(.notebook))
        XCTAssertEqual(roles["notes/\(u) 2.txt"], .other)
        XCTAssertEqual(index.metas[id]?.kind, .notebook)
        XCTAssertNotNil(index.bodies[id])
    }

    func testSyncToolConflictCopyIsImportedAndRemoved() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(title: "v1")
        try await sync(a, b)
        try await writeSidecar(id, title: "edited in a sync-tool conflict", suffix: " (conflicted copy 2026-10-12)")

        let report = try await a.engine.sync()
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
        try await sync(b, a)
        let copies = await b.store.conflictCopies().map(\.title)
        XCTAssertEqual(copies, ["edited in a sync-tool conflict (conflict — C)"])
        let original = await b.store.title(id)
        XCTAssertEqual(original, "v1")
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains { $0.contains("conflicted copy") })
        await assertConverged(a, b)
    }

    func testDuplicateSidecarIsDeletedAndOrphanBodyAgesOut() async throws {
        let a = device("A")
        let id = await a.store.create(title: "v1")
        try await sync(a)
        let meta = try await memory.get(RemoteLayout.meta(.note, id)).data
        let body = try await memory.get(RemoteLayout.body(id)).data
        try await memory.put(sidecarKey(id, " 2.meta"), data: meta, ifMatch: nil, ifNoneMatch: false)
        try await memory.put(sidecarKey(id, " 2.body"), data: body, ifMatch: nil, ifNoneMatch: false)

        let report = try await a.engine.sync()
        XCTAssertEqual(report.conflicts, 0)
        let copies = await a.store.conflictCopies()
        XCTAssertTrue(copies.isEmpty)
        var keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(sidecarKey(id, " 2.meta")))
        XCTAssertTrue(keys.contains(sidecarKey(id, " 2.body")), "unmatched bodies are kept for a while")

        clock.advance(29 * 86_400)
        try await sync(a)
        keys = try await remoteKeys()
        XCTAssertTrue(keys.contains(sidecarKey(id, " 2.body")))
        clock.advance(2 * 86_400)
        try await sync(a)
        keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(sidecarKey(id, " 2.body")))
        XCTAssertTrue(SyncState.load(from: a.stateURL).sidecarFirstSeen.isEmpty)
    }

    func testNewerNotebookSidecarWins() async throws {
        let a = device("A"), b = device("B")
        let id = await a.store.create(kind: .notebook, title: "Work")
        try await sync(a, b)
        try await writeSidecar(id, kind: .notebook, title: "Work (renamed)", modifiedAt: Date().addingTimeInterval(60), suffix: " 2")
        try await sync(a, a, b)
        let onA = await a.store.title(id)
        let onB = await b.store.title(id)
        XCTAssertEqual(onA, "Work (renamed)")
        XCTAssertEqual(onB, "Work (renamed)")
        let keys = try await remoteKeys()
        XCTAssertFalse(keys.contains(sidecarKey(id, " 2.json", folder: "notebooks")))
        await assertConverged(a, b)
    }

    func testOwnerRepushesMissingOrReplacedBody() async throws {
        let a = device("A")
        let missing = await a.store.create(title: "missing body")
        let replaced = await a.store.create(title: "replaced body")
        try await sync(a)
        try await memory.delete(RemoteLayout.body(missing))
        try await memory.put(RemoteLayout.body(replaced), data: try seal(Data("stale".utf8), key: RemoteLayout.body(replaced)), ifMatch: nil, ifNoneMatch: false)

        let healed = try await a.engine.sync()
        XCTAssertTrue(healed.errors.isEmpty, "\(healed.errors)")
        let b = device("B")
        let report = try await b.engine.sync()
        XCTAssertEqual(report.pulled, 2)
        XCTAssertEqual(report.skipped, 0)
        await assertConverged(a, b)

        let before = await counters()
        try await sync(a, b)
        let after = await counters()
        XCTAssertEqual(after.put, before.put, "healed bodies must not ping-pong")
    }
}
