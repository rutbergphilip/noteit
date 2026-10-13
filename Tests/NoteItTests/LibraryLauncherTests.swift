import AppKit
import XCTest
@testable import NoteIt
import NoteItSync

/// The launch path end to end: migration decision → NoteStore load (seeding included).
@MainActor
final class LibraryLauncherTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private var logged: [String] = []

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-launch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        logged = []
    }

    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        try? fm.removeItem(at: base)
    }

    private var legacy: URL { base.appendingPathComponent("Inkwell", isDirectory: true) }
    private var current: URL { base.appendingPathComponent("NoteIt", isDirectory: true) }

    private func launcher(
        override: String? = nil,
        running: @escaping () -> Bool = { false },
        quit: @escaping () -> Bool = { XCTFail("must not ask Inkwell to quit"); return false }
    ) -> LibraryLauncher {
        let base = base!
        return LibraryLauncher(
            dataDirectoryOverride: { override },
            baseDirectory: { base },
            isLegacyAppRunning: running,
            quitLegacyApp: quit,
            log: { [weak self] in self?.logged.append($0) }
        )
    }

    /// Launches through the real store; fails the test if NoteIt was told to quit.
    private func launchStore(_ launcher: LibraryLauncher, file: StaticString = #filePath, line: UInt = #line) -> NoteStore? {
        launcher.launch(open: { NoteStore(location: $0) }, quit: { XCTFail("unexpected quit", file: file, line: line) })
    }

    /// A genuine library written by the store itself, with one note of our own.
    @discardableResult
    private func makeLibrary(at url: URL, title: String) -> UUID {
        let store = NoteStore(rootURL: url)
        let note = store.createNote(in: store.notebooks.first?.id, initial: NSAttributedString(string: "\(title)\nbody"))
        store.flush()
        return note.id
    }

    private func titles(_ store: NoteStore?) -> Set<String> { Set(store?.notes.map(\.title) ?? []) }

    /// Every path under `base` with its type and content, without following links.
    private func snapshot() throws -> [String: String] {
        var result: [String: String] = [:]
        for case let path as String in fm.enumerator(atPath: base.path)! {
            let full = base.appendingPathComponent(path).path
            switch try fm.attributesOfItem(atPath: full)[.type] as? FileAttributeType {
            case .typeSymbolicLink?: result[path] = "link:" + (try fm.destinationOfSymbolicLink(atPath: full))
            case .typeDirectory?: result[path] = "dir"
            default: result[path] = try Data(contentsOf: URL(fileURLWithPath: full)).base64EncodedString()
            }
        }
        return result
    }

    // MARK: - Outcomes through the store

    func testFreshInstallSeedsWelcomeLibrary() throws {
        let launcher = launcher()
        XCTAssertEqual(launcher.decide(), .open(LibraryLocation(url: current, seedsFreshLibrary: true)))
        let store = launchStore(launcher)
        XCTAssertTrue(titles(store).contains("Welcome to NoteIt"))
        XCTAssertEqual(store?.rootURL, current)
    }

    func testExistingNoteItLibraryIsOpenedWithoutSeeding() throws {
        makeLibrary(at: current, title: "Mine")
        let before = titles(NoteStore(rootURL: current))
        let launcher = launcher()
        XCTAssertEqual(launcher.decide(), .open(LibraryLocation(url: current, seedsFreshLibrary: false)))
        XCTAssertEqual(titles(launchStore(launcher)), before)
    }

    func testMovedLibraryIsOpenedAndLinked() throws {
        let id = makeLibrary(at: legacy, title: "From Inkwell")
        let store = launchStore(launcher())
        XCTAssertEqual(store?.rootURL, current)
        XCTAssertNotNil(store?.note(with: id))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacy.path), "NoteIt")
    }

    func testMovedLibraryWithNoNotesLeftIsNotSeeded() throws {
        // The user deleted every note in Inkwell: only the first-launch marker says it's theirs.
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data().write(to: legacy.appendingPathComponent(".initialized"))
        let launcher = launcher()
        XCTAssertEqual(launcher.decide(), .open(LibraryLocation(url: current, seedsFreshLibrary: false)))
        let store = launchStore(launcher)
        XCTAssertEqual(store?.rootURL, current)
        XCTAssertEqual(store?.notes.isEmpty, true)
    }

    func testStrayNoteItFolderIsSetAsideAndRealLibraryOpened() throws {
        let id = makeLibrary(at: legacy, title: "From Inkwell")
        let expected = titles(NoteStore(rootURL: legacy))
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: current.appendingPathComponent("sync.log"))
        let store = launchStore(launcher())
        XCTAssertNotNil(store?.note(with: id))
        XCTAssertEqual(titles(store), expected, "nothing seeded on top")
        let aside = try fm.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix("NoteIt.pre-migration-") }
        XCTAssertEqual(aside.count, 1)
    }

    func testFailedMoveOpensLegacyFolderInPlaceWithoutSeeding() throws {
        let id = makeLibrary(at: legacy, title: "From Inkwell")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)
        let launcher = launcher()
        XCTAssertEqual(launcher.decide(), .open(LibraryLocation(url: legacy, seedsFreshLibrary: false)))
        let store = launchStore(launcher)
        XCTAssertEqual(store?.rootURL, legacy)
        XCTAssertNotNil(store?.note(with: id))
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }

    func testQuitNoteItNeverTouchesTheDisk() throws {
        makeLibrary(at: legacy, title: "From Inkwell")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: current.appendingPathComponent("sync.log"))
        let before = try snapshot()
        var asked = 0, quitCalled = 0, opened = 0
        let launcher = launcher(running: { true }, quit: { asked += 1; return false })
        let store: NoteStore? = launcher.launch(open: { opened += 1; return NoteStore(location: $0) }, quit: { quitCalled += 1 })
        XCTAssertNil(store)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(quitCalled, 1)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(try snapshot(), before)
    }

    func testMovesOnceInkwellQuits() throws {
        let id = makeLibrary(at: legacy, title: "From Inkwell")
        var running = true
        let store = launchStore(launcher(running: { running }, quit: { running = false; return true }))
        XCTAssertEqual(store?.rootURL, current)
        XCTAssertNotNil(store?.note(with: id))
    }

    func testDataDirOverrideSkipsMigrationAndSeeds() throws {
        makeLibrary(at: legacy, title: "From Inkwell")
        let before = try snapshot()
        let scratch = base.appendingPathComponent("scratch", isDirectory: true)
        let store = launchStore(launcher(override: scratch.path, running: { true }))
        XCTAssertEqual(store?.rootURL, scratch)
        XCTAssertTrue(titles(store).contains("Welcome to NoteIt"))
        XCTAssertEqual(try snapshot().filter { !$0.key.hasPrefix("scratch") }, before)
    }

    func testLinkToMissingNoteItStartsFreshWithoutMoving() throws {
        try fm.createSymbolicLink(atPath: legacy.path, withDestinationPath: "NoteIt")
        let store = launchStore(launcher(running: { true }))
        XCTAssertTrue(titles(store).contains("Welcome to NoteIt"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: legacy.path), "NoteIt")
        XCTAssertEqual(logged.count, 1)
    }

    func testAlreadyMigratedLaunchOpensSameLibrary() throws {
        let id = makeLibrary(at: legacy, title: "From Inkwell")
        let expected = titles(launchStore(launcher()))
        let again = launchStore(launcher(running: { true }))
        XCTAssertEqual(again?.rootURL, current)
        XCTAssertNotNil(again?.note(with: id))
        XCTAssertEqual(titles(again), expected, "nothing seeded on top")
    }

    // MARK: - Store seed decision

    func testStoreSeedsOnlyWhenAllowed() {
        let notAllowed = base.appendingPathComponent("a", isDirectory: true)
        XCTAssertTrue(NoteStore(location: LibraryLocation(url: notAllowed, seedsFreshLibrary: false)).notes.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: notAllowed.appendingPathComponent("seed-manifest.json").path))

        let allowed = base.appendingPathComponent("b", isDirectory: true)
        XCTAssertTrue(titles(NoteStore(location: LibraryLocation(url: allowed, seedsFreshLibrary: true))).contains("Welcome to NoteIt"))
    }

    func testStoreNeverSeedsOverAnExistingLibrary() {
        makeLibrary(at: current, title: "Mine")
        let expected = titles(NoteStore(rootURL: current))
        XCTAssertEqual(titles(NoteStore(location: LibraryLocation(url: current, seedsFreshLibrary: true))), expected)
    }
}

@MainActor
final class LegacyAppMonitorTests: XCTestCase {
    private var asked = 0
    private var quitNoteIt = 0

    private func monitor(running: Bool = true, shared: Bool = true, inkwellQuits: Bool = true, bundleID: String = "com.inkwell.app") -> LegacyAppMonitor {
        LegacyAppMonitor(
            legacyBundleID: bundleID,
            isLegacyAppRunning: { running },
            sharesLibrary: { shared },
            quitLegacyApp: { [unowned self] in asked += 1; return inkwellQuits },
            quitNoteIt: { [unowned self] in quitNoteIt += 1 }
        )
    }

    func testIgnoresOtherApps() {
        monitor().handleLaunch(bundleID: "com.apple.TextEdit")
        monitor().handleLaunch(bundleID: nil)
        XCTAssertEqual(asked, 0)
    }

    func testAsksInkwellToQuitWhenItSharesTheLibrary() {
        monitor().handleLaunch(bundleID: "com.inkwell.app")
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(quitNoteIt, 0)
    }

    func testQuitsNoteItWhenUserKeepsInkwell() {
        monitor(inkwellQuits: false).handleLaunch(bundleID: "com.inkwell.app")
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(quitNoteIt, 1)
    }

    func testLeavesInkwellWithItsOwnLibraryAlone() {
        monitor(shared: false).handleLaunch(bundleID: "com.inkwell.app")
        monitor(running: false).handleLaunch(bundleID: "com.inkwell.app")
        XCTAssertEqual(asked, 0)
    }

    func testObservesLaunchNotifications() throws {
        // Any running app with a bundle id stands in for Inkwell (the test runner itself has none).
        let app = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil })
        let bundleID = try XCTUnwrap(app.bundleIdentifier)
        let center = NotificationCenter()
        let monitor = monitor(bundleID: bundleID)
        monitor.start(center: center)
        XCTAssertEqual(asked, 1, "checks once at start")
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: app])
        spinMainQueue()
        XCTAssertEqual(asked, 2)
        monitor.stop(center: center)
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: app])
        spinMainQueue()
        XCTAssertEqual(asked, 2)
    }

    /// Lets the observer's main-queue hops run.
    private func spinMainQueue() {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}
