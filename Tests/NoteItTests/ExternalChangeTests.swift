import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItMarkdown

/// markdown-storage Task 4.2: changes made to the Markdown folder while NoteIt is open.
@MainActor
final class ExternalChangeTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-external-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func open() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                        renameFilesOnTitleChange: false),
                              bodyStorage: MarkdownBodyStorageTests.make(root, renames: false))
        store.markdownClock = { Date().addingTimeInterval(10) }
        return store
    }

    private func put(_ path: String, _ text: String, modified: Date? = nil) throws {
        let url = content.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: content.appendingPathComponent(path), encoding: .utf8)
    }

    private func edit(_ path: String, _ old: String, _ new: String, modified: Date? = nil) throws {
        try put(path, read(path).replacingOccurrences(of: old, with: new), modified: modified)
    }

    private func note(_ store: NoteStore, titled title: String) throws -> NoteMeta {
        try XCTUnwrap(store.notes.first { $0.title == title }, "no note titled \(title)")
    }

    func testEditsMadeWhileNoteItWasClosedReachSpotlightAtTheNextLaunch() async throws {
        try put("Kept.md", "# Kept\n\nfirst\n")
        try put("Gone.md", "# Gone\n\nsoon\n")
        let suite = "noteit-external-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SpotlightIndexer.indexVersion, forKey: PrefKey.spotlightIndexVersion)
        var store: NoteStore? = open()
        let kept = try note(store!, titled: "Kept").id
        let gone = try note(store!, titled: "Gone").id
        store?.flush()
        store = nil

        try edit("Kept.md", "first", "edited while closed")
        try fm.removeItem(at: content.appendingPathComponent("Gone.md"))
        try put("Added.md", "# Added\n\nnew\n")
        let reopened = open()
        let added = try note(reopened, titled: "Added").id
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: reopened, defaults: defaults, index: fake, isSupported: true, flushDelay: 60)
        indexer.start()
        let deadline = Date().addingTimeInterval(5)
        while fake.items[added.uuidString] == nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        await indexer.settle()

        XCTAssertNotNil(fake.items[added.uuidString], "a file added while closed is indexed")
        XCTAssertTrue(fake.items[kept.uuidString]?.textContent?.contains("edited while closed") == true)
        XCTAssertTrue(fake.calls.contains(.deleteAll) || fake.items[gone.uuidString] == nil)
    }

    func testACleanNoteReloadsAndKeepsItsPreviousTextInHistory() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        XCTAssertTrue(store.body(for: id).string.contains("first"))
        let before = try XCTUnwrap(store.note(with: id))
        let versions = store.history.versions(of: id).count
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .noteItLocalChange, object: store, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let modified = Date(timeIntervalSince1970: 1_900_000_000)
        try edit("Note.md", "first", "second", modified: modified)
        store.rescanMarkdownFolder()
        store.flush()

        let after = try XCTUnwrap(store.note(with: id))
        XCTAssertTrue(store.body(for: id).string.contains("second"))
        XCTAssertNotEqual(after.revision, before.revision)
        XCTAssertEqual(after.updatedAt.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(store.history.versions(of: id).count, versions + 1, "the text before the outside edit is a version")
        XCTAssertEqual(posted, 1)
        XCTAssertTrue(try read("Note.md").contains("second"))

        store.rescanMarkdownFolder()
        store.flush()
        XCTAssertEqual(store.note(with: id)?.revision, after.revision, "a second scan changes nothing")
        XCTAssertEqual(store.history.versions(of: id).count, versions + 1)
    }

    func testUnsavedEditsWinAndTheFileBecomesAConflictCopy() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        let mine = NSMutableAttributedString(attributedString: store.body(for: id))
        mine.mutableString.replaceOccurrences(of: "first", with: "mine", range: NSRange(location: 0, length: mine.length))
        store.updateBody(id, mine)

        try edit("Note.md", "first", "theirs")
        store.rescanMarkdownFolder()
        store.flush()

        XCTAssertTrue(store.body(for: id).string.contains("mine"))
        let copy = try note(store, titled: "Note (Outside NoteIt)")
        XCTAssertEqual(copy.conflictSource, NoteStore.outsideNoteItSource)
        XCTAssertEqual(copy.conflictOriginalID, id)
        XCTAssertTrue(store.body(for: copy.id).string.contains("theirs"))
        XCTAssertTrue(try read("Note.md").contains("mine"))
    }

    func testANewFileWaitsUntilItHasSettled() throws {
        let store = open()
        store.flush()
        let now = Date()
        store.markdownClock = { now }
        try put("Fresh.md", "# Fresh\n\nstill being written\n", modified: now.addingTimeInterval(-1))
        store.rescanMarkdownFolder()
        XCTAssertNil(store.notes.first { $0.title == "Fresh" }, "a file younger than 2 seconds isn't read yet")

        store.markdownClock = { now.addingTimeInterval(1.5) }
        store.rescanMarkdownFolder()
        let fresh = try note(store, titled: "Fresh")
        XCTAssertEqual(fresh.preview, "still being written")
        XCTAssertTrue(try read("Fresh.md").contains("id: \(fresh.id.uuidString)"))
    }

    func testADeletedFileMovesItsNoteToRecentlyDeletedWithACopyInTrash() throws {
        try put("Gone.md", "# Gone\n\nkeep me\n")
        try put("Stay.md", "# Stay\n")
        let store = open()
        let id = try note(store, titled: "Gone").id
        store.flush()

        try fm.removeItem(at: content.appendingPathComponent("Gone.md"))
        store.rescanMarkdownFolder()
        store.flush()

        XCTAssertNotNil(store.note(with: id)?.deletedAt)
        XCTAssertTrue(try read(".trash/Gone.md").contains("keep me"))
        XCTAssertTrue(store.body(for: id).string.contains("keep me"))
        XCTAssertNil(try note(store, titled: "Stay").deletedAt)
    }

    func testRenamedMovedAndDeletedFoldersFollowTheirNotebooks() throws {
        try put("Work/Plan.md", "# Plan\n")
        try put("Home/List.md", "# List\n")
        try put("Archive/Old.md", "# Old\n")
        let store = open()
        let plan = try note(store, titled: "Plan").id
        let list = try note(store, titled: "List").id
        let old = try note(store, titled: "Old").id
        let work = try XCTUnwrap(store.notebooks.first { $0.name == "Work" }).id
        let home = try XCTUnwrap(store.notebooks.first { $0.name == "Home" }).id
        let archive = try XCTUnwrap(store.notebooks.first { $0.name == "Archive" }).id
        store.flush()

        try fm.moveItem(at: content.appendingPathComponent("Work"), to: content.appendingPathComponent("Office"))
        try fm.moveItem(at: content.appendingPathComponent("Home"), to: content.appendingPathComponent("Office/Home"))
        try fm.removeItem(at: content.appendingPathComponent("Archive"))
        store.rescanMarkdownFolder()
        store.flush()

        XCTAssertEqual(store.notebook(with: work)?.name, "Office")
        XCTAssertEqual(store.notebook(with: home)?.parent, work)
        XCTAssertEqual(store.note(with: plan)?.notebookID, work)
        XCTAssertEqual(store.note(with: list)?.notebookID, home)
        XCTAssertNil(store.note(with: list)?.deletedAt)
        XCTAssertNil(store.notebook(with: archive))
        XCTAssertNotNil(store.note(with: old)?.deletedAt)
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent(".trash/Old.md").path))
    }

    func testNoteItsOwnWritesAreNotOutsideChanges() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        let body = NSMutableAttributedString(attributedString: store.body(for: id))
        body.append(NSAttributedString(string: "\nmore"))
        store.updateBody(id, body)
        store.flush()
        let saved = try XCTUnwrap(store.note(with: id))
        let versions = store.history.versions(of: id).count

        store.rescanMarkdownFolder()
        XCTAssertEqual(store.note(with: id)?.revision, saved.revision)
        XCTAssertEqual(store.history.versions(of: id).count, versions)
        XCTAssertNil(store.notes.first { $0.conflictSource != nil })
    }

    func testAFileThatIsNoLongerMarkdownIsReadOnly() throws {
        try put("Note.md", "# Note\n\nfirst\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        try Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]).write(to: content.appendingPathComponent("Note.md"))
        store.rescanMarkdownFolder()
        XCTAssertEqual(store.loadError(for: id), MarkdownBodyStorage.unreadableReason)
        store.updateBody(id, NSAttributedString(string: "Note\nreplaced"))
        store.flush()
        XCTAssertEqual(try Data(contentsOf: content.appendingPathComponent("Note.md")), Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]))
    }

    func testAMissingContentFolderIsReportedOnceAndNothingChanges() throws {
        try put("Note.md", "# Note\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        var reported: [URL] = []
        store.onMarkdownFolderMissing = { reported.append($0) }
        try fm.moveItem(at: content, to: root.appendingPathComponent("elsewhere"))
        store.rescanMarkdownFolder()
        store.rescanMarkdownFolder()
        XCTAssertEqual(reported, [content])
        XCTAssertNil(store.note(with: id)?.deletedAt)
    }

    func testTheWatcherPicksUpANewFile() throws {
        let store = open()
        store.flush()
        store.startWatchingMarkdownFolder()
        defer { store.stopWatchingMarkdownFolder() }
        XCTAssertNotNil(store.markdownWatcher)
        try put("Dropped.md", "# Dropped\n\nfrom another app\n")
        let deadline = Date().addingTimeInterval(5)
        while store.notes.first(where: { $0.title == "Dropped" }) == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(store.notes.first { $0.title == "Dropped" })
    }

    func testAFileWrittenWithoutPauseDoesNotPostponeTheRescanForever() throws {
        var rescans: [Date] = []
        let watcher = MarkdownFolderWatcher(root: content, ledger: WriteLedger(), onChange: { rescans.append(Date()) },
                                            onRootChanged: {})
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let start = Date()
        try put("Settled.md", "# Settled\n")
        var tick = 0
        while Date().timeIntervalSince(start) < MarkdownFolderWatcher.maxDelay + 2 {
            tick += 1
            try put("Log.md", "# Log\n\nline \(tick)\n")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let first = try XCTUnwrap(rescans.first, "a file written every 0.1 s must not hold the rescan back")
        XCTAssertLessThan(first.timeIntervalSince(start), MarkdownFolderWatcher.maxDelay + 1)
    }
}
