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

    func testMovesLegacyLibraryIncludingHiddenFiles() throws {
        try makeLegacyLibrary()
        let result = LibraryMigration.resolve(baseDirectory: base, log: { _ in })
        XCTAssertEqual(result.outcome, .moved)
        XCTAssertEqual(result.directory.standardizedFileURL, current.standardizedFileURL)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        for path in ["library.json", ".initialized", ".trash/abc.rtfd/TXT.rtf", "sync-deletions.json"] {
            XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent(path).path), path)
        }
    }

    func testNoMoveWhenNewFolderExists() throws {
        try makeLegacyLibrary()
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        let result = LibraryMigration.resolve(baseDirectory: base, move: { _, _ in XCTFail("must not move") }, log: { _ in })
        XCTAssertEqual(result.outcome, .notNeeded)
        XCTAssertEqual(result.directory, current)
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("library.json").path))
    }

    func testFreshInstallUsesNewFolderWithoutCreatingIt() {
        let result = LibraryMigration.resolve(baseDirectory: base, move: { _, _ in XCTFail("must not move") }, log: { _ in })
        XCTAssertEqual(result.outcome, .notNeeded)
        XCTAssertEqual(result.directory, current)
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }

    func testFailedMoveFallsBackToLegacyFolder() throws {
        try makeLegacyLibrary()
        struct Boom: Error {}
        var logged: [String] = []
        let result = LibraryMigration.resolve(baseDirectory: base, move: { _, _ in throw Boom() }, log: { logged.append($0) })
        XCTAssertEqual(result.directory, legacy)
        guard case .failed = result.outcome else { return XCTFail("expected .failed, got \(result.outcome)") }
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("library.json").path))
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }

    func testRealMoveFailureFallsBack() throws {
        try makeLegacyLibrary()
        // A read-only base makes the rename itself fail.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path) }
        let result = LibraryMigration.resolve(baseDirectory: base, log: { _ in })
        XCTAssertEqual(result.directory, legacy)
        guard case .failed = result.outcome else { return XCTFail("expected .failed, got \(result.outcome)") }
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent(".initialized").path))
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

    func testWireIdentifiersAreUnchanged() {
        XCTAssertEqual(RemoteLayout.root, "inkwell/v1/")
        XCTAssertEqual(RemoteLayout.folder, "inkwell")
    }
}
