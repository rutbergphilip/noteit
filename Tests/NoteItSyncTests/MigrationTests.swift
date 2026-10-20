import XCTest
@testable import NoteItSync

final class LibraryMigrationTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private var legacy: URL { base.appendingPathComponent("Inkwell", isDirectory: true) }
    private var current: URL { base.appendingPathComponent("NoteIt", isDirectory: true) }

    private func makeLegacyLibrary() throws {
        try fm.createDirectory(at: legacy.appendingPathComponent(".trash/abc.rtfd"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("library.json"))
        try Data().write(to: legacy.appendingPathComponent(".initialized"))
        try Data("x".utf8).write(to: legacy.appendingPathComponent(".trash/abc.rtfd/TXT.rtf"))
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("sync-deletions.json"))
    }

    private func resolve(
        running: @escaping () -> Bool = { false },
        quit: () -> Bool = { XCTFail("must not ask Inkwell to quit"); return false },
        move: ((URL, URL) throws -> Void)? = nil,
        log: (String) -> Void = { _ in }
    ) -> (directory: URL, outcome: LibraryMigration.Outcome) {
        LibraryMigration.resolve(
            baseDirectory: base, isLegacyAppRunning: running, quitLegacyApp: quit, move: move,
            now: Date(timeIntervalSince1970: 0), log: log
        )
    }

    private func noMove(_: URL, _: URL) throws { XCTFail("must not move") }

    private func assertLegacyIntact(file: StaticString = #filePath, line: UInt = #line) {
        for path in ["library.json", ".initialized", ".trash/abc.rtfd/TXT.rtf", "sync-deletions.json"] {
            XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent(path).path), path, file: file, line: line)
        }
    }

    func testMovesLegacyLibraryIncludingHiddenFiles() throws {
        try makeLegacyLibrary()
        let result = resolve()
        XCTAssertEqual(result.outcome, .moved(setAside: nil))
        XCTAssertFalse(result.outcome.allowsSeeding)
        XCTAssertEqual(result.directory.standardizedFileURL, current.standardizedFileURL)
        assertLegacyIsLinkToCurrent()
        for path in ["library.json", ".initialized", ".trash/abc.rtfd/TXT.rtf", "sync-deletions.json"] {
            XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent(path).path), path)
        }
    }

    private func assertLegacyIsLinkToCurrent(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: legacy.path), "NoteIt", "relative link", file: file, line: line)
        XCTAssertTrue(LibraryMigration.isShared(legacy: legacy, with: current), file: file, line: line)
    }

    func testSecondRunAfterMoveIsAlreadyMigrated() throws {
        try makeLegacyLibrary()
        XCTAssertEqual(resolve().outcome, .moved(setAside: nil))
        // An Inkwell relaunched now would be running; the link is never a source, so nothing is asked or moved.
        let again = resolve(running: { true }, move: noMove)
        XCTAssertEqual(again.outcome, .existing)
        XCTAssertEqual(again.directory, current)
        assertLegacyIsLinkToCurrent()
    }

    func testLinkToNoteItIsAlreadyMigrated() throws {
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent(".initialized"))
        try fm.createSymbolicLink(atPath: legacy.path, withDestinationPath: "NoteIt")
        let result = resolve(running: { true }, move: noMove)
        XCTAssertEqual(result.outcome, .existing)
        XCTAssertEqual(result.directory, current)
    }

    func testAbsoluteLinkToNoteItIsAlreadyMigrated() throws {
        try fm.createDirectory(at: current.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: legacy.path, withDestinationPath: current.path)
        // NoteIt has no library yet, and following the link would make Inkwell look like one: it mustn't.
        var logged: [String] = []
        let result = resolve(running: { true }, move: noMove, log: { logged.append($0) })
        XCTAssertEqual(result.outcome, .freshInstall)
        XCTAssertEqual(logged.count, 1)
    }

    func testLinkToMissingNoteItIsFreshAndNeverFollowed() throws {
        try fm.createSymbolicLink(atPath: legacy.path, withDestinationPath: "NoteIt")
        var logged: [String] = []
        let result = resolve(running: { true }, move: noMove, log: { logged.append($0) })
        XCTAssertEqual(result.outcome, .freshInstall)
        XCTAssertEqual(result.directory, current)
        XCTAssertEqual(logged.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: current.path), "nothing created")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacy.path), "NoteIt", "link left alone")
    }

    func testIsShared() throws {
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertFalse(LibraryMigration.isShared(legacy: legacy, with: current), "separate libraries")
        XCTAssertTrue(LibraryMigration.isShared(legacy: legacy, with: legacy), "legacy folder used in place")
        try fm.removeItem(at: legacy)
        try fm.createSymbolicLink(atPath: legacy.path, withDestinationPath: "NoteIt")
        XCTAssertTrue(LibraryMigration.isShared(legacy: legacy, with: current))
    }

    func testBothLibrariesKeepsNoteItAndLeavesInkwellUntouched() throws {
        try makeLegacyLibrary()
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent(".initialized"))
        var logged: [String] = []
        let result = resolve(move: noMove, log: { logged.append($0) })
        XCTAssertEqual(result.outcome, .existing)
        XCTAssertFalse(result.outcome.allowsSeeding)
        XCTAssertEqual(result.directory, current)
        XCTAssertEqual(logged.count, 1)
        assertLegacyIntact()
    }

    func testExistingNoteItLibraryWithoutLegacy() throws {
        try fm.createDirectory(at: current.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: current.appendingPathComponent("library.json"))
        let result = resolve(move: noMove)
        XCTAssertEqual(result.outcome, .existing)
        XCTAssertEqual(result.directory, current)
    }

    func testStrayNoteItFolderIsSetAsideAndLibraryMovedIn() throws {
        try makeLegacyLibrary()
        try fm.createDirectory(at: current.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("log".utf8).write(to: current.appendingPathComponent("sync.log"))
        try Data("{}".utf8).write(to: current.appendingPathComponent("search-index.json"))
        let result = resolve()
        let aside = base.appendingPathComponent("NoteIt.pre-migration-" + Self.stamp(Date(timeIntervalSince1970: 0)), isDirectory: true)
        XCTAssertEqual(result.outcome, .moved(setAside: aside))
        XCTAssertFalse(result.outcome.allowsSeeding)
        XCTAssertEqual(result.directory, current)
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("library.json").path))
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent(".initialized").path))
        XCTAssertTrue(fm.fileExists(atPath: aside.appendingPathComponent("sync.log").path))
        XCTAssertTrue(fm.fileExists(atPath: aside.appendingPathComponent("search-index.json").path))
        assertLegacyIsLinkToCurrent()
    }

    func testSetAsideNameIsUniqued() throws {
        try makeLegacyLibrary()
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        let taken = base.appendingPathComponent("NoteIt.pre-migration-" + Self.stamp(Date(timeIntervalSince1970: 0)))
        try fm.createDirectory(at: taken, withIntermediateDirectories: true)
        let result = resolve()
        XCTAssertEqual(result.outcome, .moved(setAside: URL(fileURLWithPath: taken.path + "-2", isDirectory: true)))
    }

    func testEachRealLibraryMarkerCounts() throws {
        XCTAssertFalse(LibraryMigration.hasLibrary(current))
        try fm.createDirectory(at: current.appendingPathComponent("notes/.hidden"), withIntermediateDirectories: true)
        XCTAssertFalse(LibraryMigration.hasLibrary(current), "hidden entries in notes/ aren't bodies")
        try fm.createDirectory(at: current.appendingPathComponent("notes/\(UUID().uuidString).rtfd"), withIntermediateDirectories: true)
        XCTAssertTrue(LibraryMigration.hasLibrary(current))
        for marker in ["library.json", ".initialized"] {
            let dir = base.appendingPathComponent(marker + "-only")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(marker))
            XCTAssertTrue(LibraryMigration.hasLibrary(dir), marker)
        }
    }

    func testFreshInstallUsesNewFolderWithoutCreatingIt() {
        let result = resolve(move: noMove)
        XCTAssertEqual(result.outcome, .freshInstall)
        XCTAssertTrue(result.outcome.allowsSeeding)
        XCTAssertEqual(result.directory, current)
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }

    func testLegacyFolderWithoutLibraryIsAFreshInstall() throws {
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: legacy.appendingPathComponent("sync.log"))
        let result = resolve(move: noMove)
        XCTAssertEqual(result.outcome, .freshInstall)
        XCTAssertEqual(result.directory, current)
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("sync.log").path))
    }

    func testFailedMoveFallsBackToLegacyFolder() throws {
        try makeLegacyLibrary()
        struct Boom: Error {}
        var logged: [String] = []
        let result = resolve(move: { _, _ in throw Boom() }, log: { logged.append($0) })
        XCTAssertEqual(result.directory, legacy)
        guard case .failed = result.outcome else { return XCTFail("expected .failed, got \(result.outcome)") }
        XCTAssertFalse(result.outcome.allowsSeeding)
        XCTAssertEqual(logged.count, 1)
        assertLegacyIntact()
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }

    func testFailedMoveAfterSetAsideRestoresStrayFolder() throws {
        try makeLegacyLibrary()
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: current.appendingPathComponent("sync.log"))
        struct Boom: Error {}
        let result = resolve(move: { from, to in
            if from == self.legacy { throw Boom() }
            try self.fm.moveItem(at: from, to: to)
        })
        XCTAssertEqual(result.directory, legacy)
        guard case .failed = result.outcome else { return XCTFail("expected .failed, got \(result.outcome)") }
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("sync.log").path))
        assertLegacyIntact()
    }

    func testRealMoveFailureFallsBack() throws {
        try makeLegacyLibrary()
        // A read-only base makes the rename itself fail.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path) }
        let result = LibraryMigration.resolve(baseDirectory: base, isLegacyAppRunning: { false }, quitLegacyApp: { false }, log: { _ in })
        XCTAssertEqual(result.directory, legacy)
        guard case .failed = result.outcome else { return XCTFail("expected .failed, got \(result.outcome)") }
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent(".initialized").path))
    }

    func testRunningInkwellThatWontQuitBlocksTheMove() throws {
        try makeLegacyLibrary()
        var asked = 0
        let result = resolve(running: { true }, quit: { asked += 1; return false }, move: noMove)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(result.outcome, .legacyAppRunning)
        XCTAssertFalse(result.outcome.allowsSeeding)
        assertLegacyIntact()
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }

    func testRunningInkwellStillAliveAfterQuitBlocksTheMove() throws {
        try makeLegacyLibrary()
        let result = resolve(running: { true }, quit: { true }, move: noMove)
        XCTAssertEqual(result.outcome, .legacyAppRunning)
        assertLegacyIntact()
    }

    func testMovesOnceInkwellHasQuit() throws {
        try makeLegacyLibrary()
        var running = true
        let result = resolve(running: { running }, quit: { running = false; return true })
        XCTAssertEqual(result.outcome, .moved(setAside: nil))
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("library.json").path))
    }

    func testRunningInkwellIsIgnoredWhenNothingNeedsMoving() throws {
        try makeLegacyLibrary()
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: current.appendingPathComponent("library.json"))
        XCTAssertEqual(resolve(running: { true }, move: noMove).outcome, .existing)
        try fm.removeItem(at: current)
        try fm.removeItem(at: legacy)
        XCTAssertEqual(resolve(running: { true }, move: noMove).outcome, .freshInstall)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

final class DefaultsMigrationTests: XCTestCase {
    private var suiteName: String!
    private var target: UserDefaults!

    override func setUp() {
        suiteName = "noteit.tests.defaults.\(UUID().uuidString)"
        target = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        target.removePersistentDomain(forName: suiteName)
    }

    func testCopiesMissingKeysOnceAndKeepsExistingOnes() {
        target.set(18.0, forKey: "editorFontSize")
        let legacy: [String: Any] = [
            "editorFontSize": 13.0,
            "hideDockIcon": true,
            "defaultNotebookID": "none",
            "syncConfiguration": Data("{\"provider\":\"folder\"}".utf8),
            "hotkey.quickCapture": ["keyCode": 49, "modifiers": 2048],
            "NSWindow Frame main": "0 0 100 100",
            "NSSplitView Subview Frames x": ["a"],
        ]
        let copied = DefaultsMigration.migrate(legacyDomain: legacy, into: target)
        XCTAssertEqual(copied, ["defaultNotebookID", "hideDockIcon", "hotkey.quickCapture", "syncConfiguration"])
        XCTAssertEqual(target.double(forKey: "editorFontSize"), 18)
        XCTAssertTrue(target.bool(forKey: "hideDockIcon"))
        XCTAssertEqual(target.data(forKey: "syncConfiguration"), Data("{\"provider\":\"folder\"}".utf8))
        XCTAssertNil(target.object(forKey: "NSWindow Frame main"))
        XCTAssertNil(target.object(forKey: "NSSplitView Subview Frames x"))
        XCTAssertTrue(target.bool(forKey: DefaultsMigration.doneKey))

        target.removeObject(forKey: "hideDockIcon")
        XCTAssertNil(DefaultsMigration.migrate(legacyDomain: legacy, into: target))
        XCTAssertNil(target.object(forKey: "hideDockIcon"))
    }

    func testNoLegacyDomainStillMarksDone() {
        XCTAssertEqual(DefaultsMigration.migrate(legacyDomain: nil, into: target), [])
        XCTAssertTrue(target.bool(forKey: DefaultsMigration.doneKey))
    }
}

final class SecretMigrationTests: XCTestCase {
    private final class FakeStore: SecretStore {
        var items: [String: String] = [:]
        var failWrite = false
        var failRemove = false
        func read(service: String, account: String) -> String? { items["\(service)|\(account)"] }
        func write(_ value: String, service: String, account: String) throws {
            if failWrite { throw NSError(domain: "fake", code: 1) }
            items["\(service)|\(account)"] = value
        }
        func remove(service: String, account: String) throws {
            if failRemove { throw NSError(domain: "fake", code: 2) }
            items["\(service)|\(account)"] = nil
        }
    }

    private let service = AppIdentity.keychainService
    private let legacyService = AppIdentity.Legacy.keychainService

    private func read(_ store: FakeStore) -> String? {
        SecretMigration.read(account: "passphrase", service: service, legacyService: legacyService, store: store)
    }

    func testServiceNames() {
        XCTAssertEqual(service, "io.github.rutbergphilip.noteit.sync")
        XCTAssertEqual(legacyService, "com.inkwell.app.sync")
    }

    func testPrefersNewService() {
        let store = FakeStore()
        store.items = ["\(service)|passphrase": "new", "\(legacyService)|passphrase": "old"]
        XCTAssertEqual(read(store), "new")
        XCTAssertEqual(store.items["\(legacyService)|passphrase"], "old")
    }

    func testAdoptsLegacyItemAndDeletesIt() {
        let store = FakeStore()
        store.items = ["\(legacyService)|passphrase": "old"]
        XCTAssertEqual(read(store), "old")
        XCTAssertEqual(store.items, ["\(service)|passphrase": "old"])
    }

    func testIgnoresFailedLegacyDelete() {
        let store = FakeStore()
        store.failRemove = true
        store.items = ["\(legacyService)|passphrase": "old"]
        XCTAssertEqual(read(store), "old")
        XCTAssertEqual(store.items["\(service)|passphrase"], "old")
    }

    func testKeepsLegacyItemWhenSaveFails() {
        let store = FakeStore()
        store.failWrite = true
        store.items = ["\(legacyService)|passphrase": "old"]
        XCTAssertEqual(read(store), "old")
        XCTAssertEqual(store.items, ["\(legacyService)|passphrase": "old"])
    }

    func testMissEverywhere() {
        XCTAssertNil(read(FakeStore()))
    }
}

final class AppEnvironmentTests: XCTestCase {
    func testPrefersNewNameAndFallsBackToLegacy() {
        XCTAssertEqual(AppEnvironment.value("DATA_DIR", in: ["NOTEIT_DATA_DIR": "a", "INKWELL_DATA_DIR": "b"]), "a")
        XCTAssertEqual(AppEnvironment.value("DATA_DIR", in: ["INKWELL_DATA_DIR": "b"]), "b")
        XCTAssertNil(AppEnvironment.value("DATA_DIR", in: [:]))
        XCTAssertNil(AppEnvironment.nonEmpty("DATA_DIR", in: ["NOTEIT_DATA_DIR": ""]))
    }

}

/// Sync wire identifiers. Stores created by Inkwell use `inkwell/v1/` and are copied over (see `RemoteMigrationTests`).
final class WireIdentifierTests: XCTestCase {
    func testWireIdentifiers() async throws {
        XCTAssertEqual(RemoteLayout.folder, "noteit")
        XCTAssertEqual(RemoteLayout.root, "noteit/v1/")
        XCTAssertEqual(RemoteLayout.legacyRoot, "inkwell/v1/")
        XCTAssertEqual(RemoteLayout.manifest(), "noteit/v1/manifest.json")
        XCTAssertEqual(RemoteLayout.canaryPrefix, "noteit/.canary/")
        XCTAssertEqual(RemoteLayout.canaryMismatchETag, "noteit-canary-mismatch")
        XCTAssertEqual(SyncEngine.keyCheckPlaintext, Data("noteit-key-check".utf8))
        XCTAssertEqual(SyncEngine.legacyKeyCheckPlaintext, Data("inkwell-key-check".utf8))
        XCTAssertEqual(FolderBackend.lockFileName, ".noteit-lock")
        // Seeds every synced revision; changing it would make every note look edited on every device.
        XCTAssertEqual(RemoteLayout.revisionHashSeed, "inkwell-revision-v1")

        // On disk: the folder backend locks `.noteit-lock` and skips Finder's `noteit/.Trash`.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FolderBackend(root: root)
        try await backend.put("noteit/v1/notes/a.meta", data: Data([1]), ifMatch: nil, ifNoneMatch: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".noteit-lock").path))
        let trash = root.appendingPathComponent("noteit/.Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data([1]).write(to: trash.appendingPathComponent("x"))
        let keys = try await backend.list(prefix: "").map(\.key)
        XCTAssertEqual(keys, ["noteit/v1/notes/a.meta"])
    }
}
