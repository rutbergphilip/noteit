import XCTest
@testable import NoteItSync

/// A sync folder on a NAS or network volume that goes away: unmounted, unreadable, or hanging.
final class FolderUnreachableTests: XCTestCase {
    private var dir: URL!
    private var root: URL!
    private var cipher: SyncCipher!

    override func setUp() async throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dir = base.appendingPathComponent(".build/folder-unreachable-tests/\(UUID().uuidString)")
        root = dir.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cipher = try await SyncEngine.connect(backend: FolderBackend(root: root), passphrase: "pw", encryptNew: true,
                                              makeCipher: XORTestCipher.factory).1
    }

    override func tearDown() async throws {
        if let dir {
            for path in (FileManager.default.subpaths(atPath: dir.path) ?? []) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(path).path)
            }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func engine(_ name: String, store: FakeLocalStore) -> SyncEngine {
        SyncEngine(backend: FolderBackend(root: root), cipher: cipher, local: store, stateURL: dir.appendingPathComponent("\(name).json"),
                   deviceID: "id-\(name)", deviceName: name)
    }

    private func setPermissions(_ mode: Int, _ relativePath: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: root.appendingPathComponent(relativePath).path)
    }

    private func assertUnavailable(_ work: () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("Expected unavailable", file: file, line: line)
        } catch StorageError.unavailable {
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }

    func testUnreadableSubfolderFailsTheListingInsteadOfDroppingNotes() async throws {
        let store = FakeLocalStore()
        let a = engine("A", store: store)
        for i in 0..<3 { _ = await store.create(title: "Note \(i)") }
        _ = try await a.sync()

        try setPermissions(0o000, RemoteLayout.root + "notes")
        do {
            _ = try await a.sync()
            XCTFail("A listing that couldn't read every folder must fail the pass")
        } catch let error as StorageError {
            guard case .io = error else { return XCTFail("Unexpected \(error)") }
        }
        let titles = await store.titles()
        XCTAssertEqual(titles.count, 3, "Notes the listing couldn't see were deleted on this Mac")

        try setPermissions(0o755, RemoteLayout.root + "notes")
        let report = try await a.sync()
        XCTAssertEqual(report.deleted, 0)
        let after = await store.titles()
        XCTAssertEqual(after.count, 3)
    }

    func testUnreadableFolderOutsideTheLibraryDoesNotStopSyncing() async throws {
        let store = FakeLocalStore()
        let a = engine("A", store: store)
        _ = await store.create(title: "Note")
        _ = try await a.sync()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("#recycle/old"), withIntermediateDirectories: true)
        try setPermissions(0o000, "#recycle")

        let report = try await a.sync()
        XCTAssertEqual(report.deleted, 0)
        let objects = try await FolderBackend(root: root).list(prefix: RemoteLayout.root)
        XCTAssertTrue(objects.contains { $0.key == RemoteLayout.manifest() })
    }

    func testUnmountedFolderIsUnavailableNotEmptyAndSyncResumes() async throws {
        let storeA = FakeLocalStore(), storeB = FakeLocalStore()
        let a = engine("A", store: storeA), b = engine("B", store: storeB)
        let id = await storeA.create(title: "v1")
        _ = try await a.sync()
        _ = try await b.sync()

        let away = dir.appendingPathComponent("unmounted")
        try FileManager.default.moveItem(at: root, to: away)
        await storeB.edit(id, title: "edited while the NAS was away")
        await assertUnavailable { try await b.sync() }
        let backend = FolderBackend(root: root)
        await assertUnavailable { try await backend.get(RemoteLayout.manifest()) }
        await assertUnavailable { try await backend.list(prefix: RemoteLayout.root) }
        await assertUnavailable { try await backend.put("x", data: Data(), ifMatch: nil, ifNoneMatch: true) }
        await assertUnavailable { try await backend.delete(RemoteLayout.manifest(), ifMatch: nil) }
        let titleOnB = await storeB.title(id)
        XCTAssertEqual(titleOnB, "edited while the NAS was away")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Nothing may be written where the share was")

        try FileManager.default.moveItem(at: away, to: root)
        let report = try await b.sync()
        XCTAssertEqual(report.pushed, 1)
        XCTAssertEqual(report.deleted, 0)
        _ = try await a.sync()
        let titleOnA = await storeA.title(id)
        XCTAssertEqual(titleOnA, "edited while the NAS was away")
    }

    func testFolderRemovedMidPassStopsThePassWithoutDeleting() async throws {
        let storeA = FakeLocalStore(), storeB = FakeLocalStore()
        let a = engine("A", store: storeA)
        for i in 0..<5 { _ = await storeA.create(title: "Note \(i)") }
        _ = try await a.sync()

        let away = dir.appendingPathComponent("unmounted")
        let gate = UnmountingBackend(FolderBackend(root: root), afterGets: 2) { [root] in
            try? FileManager.default.moveItem(at: root!, to: away)
        }
        let b = SyncEngine(backend: gate, cipher: cipher, local: storeB, stateURL: dir.appendingPathComponent("B.json"),
                           deviceID: "id-B", deviceName: "B")
        await assertUnavailable { try await b.sync() }
        let gets = gate.gets
        XCTAssertLessThanOrEqual(gets, 4, "The pass kept going after the folder went away")

        try FileManager.default.moveItem(at: away, to: root)
        _ = try await b.sync()
        _ = try await a.sync()
        let titlesOnA = await storeA.titles()
        let titlesOnB = await storeB.titles()
        XCTAssertEqual(titlesOnA.count, 5)
        XCTAssertEqual(titlesOnB, titlesOnA)
    }

    func testRootSwappedForAnEmptyFolderBeforeTheListingDeletesNothing() async throws {
        try await assertRootSwapIsHarmless(before: .list, replacementHasStore: false)
    }

    func testRootSwappedForAnEmptyFolderBeforeTheWritesWritesNothing() async throws {
        try await assertRootSwapIsHarmless(before: .write, replacementHasStore: false)
    }

    func testRootSwappedForAFolderWithAStoreIsCaughtByItsIdentity() async throws {
        try await assertRootSwapIsHarmless(before: .list, replacementHasStore: true)
    }

    func testRootSwappedForAFolderWithAStoreBeforeTheWritesIsCaughtByItsIdentity() async throws {
        try await assertRootSwapIsHarmless(before: .write, replacementHasStore: true)
    }

    /// The share unmounts mid-pass and an empty folder is left at its mount point (or made there by someone).
    private func assertRootSwapIsHarmless(before point: SwappingBackend.Point, replacementHasStore: Bool,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let storeA = FakeLocalStore(), storeB = FakeLocalStore()
        let a = engine("A-\(point)", store: storeA)
        var ids: [UUID] = []
        for i in 0..<4 { ids.append(await storeA.create(title: "Note \(i)")) }
        _ = try await a.sync()

        let away = dir.appendingPathComponent("unmounted")
        let swapper = SwappingBackend(FolderBackend(root: root, store: .existing))
        let stateURL = dir.appendingPathComponent("B-\(point).json")
        let b = SyncEngine(backend: swapper, cipher: cipher, local: storeB, stateURL: stateURL, deviceID: "id-B", deviceName: "B")
        _ = try await b.sync()
        await storeB.edit(ids[0], title: "edited on B")
        await storeB.delete(ids[1])
        let titlesBefore = await storeB.titles()
        let journalBefore = await storeB.journaledDeletions()
        let stateBefore = SyncState.load(from: stateURL)

        swapper.swap(before: point) { [root] in
            try! FileManager.default.moveItem(at: root!, to: away)
            try! FileManager.default.createDirectory(at: root!, withIntermediateDirectories: false)
            if replacementHasStore {
                try! FileManager.default.createDirectory(at: root!.appendingPathComponent(RemoteLayout.root), withIntermediateDirectories: true)
            }
        }
        await assertUnavailable({ try await b.sync() }, file: file, line: line)
        XCTAssertTrue(swapper.swapped, file: file, line: line)

        let titlesAfter = await storeB.titles()
        let journalAfter = await storeB.journaledDeletions()
        XCTAssertEqual(titlesAfter, titlesBefore, "Notes changed on this Mac while the share was away", file: file, line: line)
        XCTAssertEqual(journalAfter, journalBefore, file: file, line: line)
        let stateAfter = SyncState.load(from: stateURL)
        XCTAssertEqual(stateAfter.bases, stateBefore.bases, file: file, line: line)
        XCTAssertEqual(stateAfter.knownTombstones, stateBefore.knownTombstones, file: file, line: line)
        XCTAssertEqual(stateAfter.tombstoneDates, stateBefore.tombstoneDates, file: file, line: line)
        let written = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(written, replacementHasStore ? ["noteit", "noteit/v1"] : [], "Written to the folder left at the mount point",
                       file: file, line: line)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: away, to: root)
        _ = try await b.sync()
        _ = try await a.sync()
        let titlesOnA = await storeA.titles()
        let titlesOnB = await storeB.titles()
        XCTAssertEqual(titlesOnA, ["edited on B", "Note 2", "Note 3"], file: file, line: line)
        XCTAssertEqual(titlesOnB, titlesOnA, file: file, line: line)
        let journalLeft = await storeB.journaledDeletions()
        XCTAssertTrue(journalLeft.isEmpty, file: file, line: line)
    }

    func testRootWithoutAStoreIsUnavailableAndNothingIsCreated() async throws {
        let empty = dir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let backend = FolderBackend(root: empty, store: .existing)
        await assertUnavailable { try await backend.get(RemoteLayout.manifest()) }
        await assertUnavailable { try await backend.list(prefix: RemoteLayout.root) }
        await assertUnavailable { try await backend.put(RemoteLayout.manifest(), data: Data("{}".utf8), ifMatch: nil, ifNoneMatch: true) }
        await assertUnavailable { try await backend.delete(RemoteLayout.manifest(), ifMatch: "x") }
        await assertUnavailable { try await backend.probe() }
        let written = try FileManager.default.contentsOfDirectory(atPath: empty.path)
        XCTAssertEqual(written, [], "The store must not be created outside connecting")

        // An Inkwell store still waiting to be copied counts as a store.
        try FileManager.default.createDirectory(at: empty.appendingPathComponent(RemoteLayout.legacyRoot), withIntermediateDirectories: true)
        await assertNotFound { try await backend.get(RemoteLayout.manifest()) }
    }

    func testConnectingCreatesTheStoreAndThenRequiresIt() async throws {
        let fresh = dir.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        let backend = FolderBackend(root: fresh, store: .creatable)
        let objects = try await backend.list(prefix: RemoteLayout.root)
        XCTAssertEqual(objects, [])
        let (_, created) = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: nil, deviceName: "A",
                                                               createIfMissing: true, encrypted: false)
        XCTAssertTrue(created)
        _ = try await backend.get(RemoteLayout.manifest())

        try FileManager.default.removeItem(at: fresh.appendingPathComponent(RemoteLayout.folder))
        await assertUnavailable { try await backend.get(RemoteLayout.manifest()) }
        await assertUnavailable { try await backend.put(RemoteLayout.manifest(), data: Data("{}".utf8), ifMatch: nil, ifNoneMatch: true) }
        let written = try FileManager.default.contentsOfDirectory(atPath: fresh.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(written, [])
    }

    private func assertNotFound(_ work: () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("Expected notFound", file: file, line: line)
        } catch StorageError.notFound {
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }

    func testUnavailableIsFatal() {
        XCTAssertTrue(SyncEngine.isFatal(.unavailable("x")))
        XCTAssertFalse(SyncEngine.isFatal(.network("x")))
    }

    func testUnreachableErrnosMapToUnavailable() {
        for code in [ENOTCONN, ETIMEDOUT, ESTALE, EIO, ENXIO, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ENODEV] {
            guard case .unavailable = FolderBackend.storageError(code, key: "k") else { return XCTFail("errno \(code)") }
        }
        XCTAssertEqual(FolderBackend.storageError(EACCES, key: "k"), .io(String(cString: strerror(EACCES))))
    }
}

/// Moves the folder away after a number of gets, like a share unmounting in the middle of a pass.
private final class UnmountingBackend: StorageBackend, @unchecked Sendable {
    private let inner: FolderBackend
    private let afterGets: Int
    private let unmount: () -> Void
    private let lock = NSLock()
    private var _gets = 0
    var gets: Int { lock.withLock { _gets } }

    init(_ inner: FolderBackend, afterGets: Int, unmount: @escaping () -> Void) {
        self.inner = inner
        self.afterGets = afterGets
        self.unmount = unmount
    }

    func list(prefix: String) async throws -> [RemoteObject] { try await inner.list(prefix: prefix) }

    func get(_ key: String) async throws -> (data: Data, etag: String) {
        let count = lock.withLock { _gets += 1; return _gets }
        if count == afterGets { unmount() }
        return try await inner.get(key)
    }

    func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        try await inner.put(key, data: data, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
    }

    func delete(_ key: String) async throws { try await inner.delete(key) }
    func delete(_ key: String, ifMatch: String?) async throws { try await inner.delete(key, ifMatch: ifMatch) }
    func probe() async throws { try await inner.probe() }
}

/// Runs `swap` once, right before the first listing or the first write, like a share unmounting mid-pass.
private final class SwappingBackend: StorageBackend, @unchecked Sendable {
    enum Point { case list, write }

    private let inner: FolderBackend
    private let lock = NSLock()
    private var pending: (point: Point, swap: () -> Void)?
    private var _swapped = false
    var swapped: Bool { lock.withLock { _swapped } }

    init(_ inner: FolderBackend) {
        self.inner = inner
    }

    func swap(before point: Point, _ swap: @escaping () -> Void) {
        lock.withLock { pending = (point, swap) }
    }

    private func reached(_ point: Point) {
        let swap: (() -> Void)? = lock.withLock {
            guard let pending, pending.point == point else { return nil }
            self.pending = nil
            _swapped = true
            return pending.swap
        }
        swap?()
    }

    func list(prefix: String) async throws -> [RemoteObject] {
        reached(.list)
        return try await inner.list(prefix: prefix)
    }

    func get(_ key: String) async throws -> (data: Data, etag: String) { try await inner.get(key) }

    func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        reached(.write)
        return try await inner.put(key, data: data, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
    }

    func delete(_ key: String) async throws {
        reached(.write)
        try await inner.delete(key)
    }

    func delete(_ key: String, ifMatch: String?) async throws {
        reached(.write)
        try await inner.delete(key, ifMatch: ifMatch)
    }

    func probe() async throws { try await inner.probe() }
}
