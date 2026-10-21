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
