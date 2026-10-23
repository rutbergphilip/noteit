import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItMarkdown
import NoteItDoc
import NoteItSync

/// markdown-storage Task 3.3: a `NoteStore` on a Markdown library.
@MainActor
final class MarkdownNoteStoreTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-mdstore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func open(renames: Bool = true) -> NoteStore {
        let store = NoteStore.opened(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                        renameFilesOnTitleChange: renames),
                              bodyStorage: MarkdownBodyStorageTests.make(root, renames: renames))
        store.markdownFlushWait = 10
        store.waitForMarkdownWrites(upTo: 10)
        store.flush()
        return store
    }

    private func put(_ path: String, _ text: String) throws {
        let url = content.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: content.appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool {
        fm.fileExists(atPath: content.appendingPathComponent(path).path)
    }

    private func body(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            result.append(EditorStyle.paragraph(line, kind: index == 0 ? .title : .body))
        }
        return result
    }

    private func note(_ store: NoteStore, titled title: String) throws -> NoteMeta {
        try XCTUnwrap(store.notes.first { $0.title == title }, "no note titled \(title)")
    }

    func testANewLibraryIsSavedAtOnceEvenBeforeItsDataFolderExistsAndTheScanEnds() throws {
        XCTAssertFalse(fm.fileExists(atPath: data.path))
        let store = NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content),
                              bodyStorage: MarkdownBodyStorageTests.make(root))
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("library.json").path))
        store.waitForLaunchScan()
    }

    func testLoadsNotebooksAndNotesFromTheFolderWithoutALibraryFile() throws {
        try put("Inbox note.md", "# Loose\n\nNo notebook #idea\n")
        try put("Work/Plan.md", "---\npinned: true\n---\n# Plan\n\nQuarter goals\n")
        try put("Work/Projects/Launch.md", "# Launch\n\nShip it\n")

        let store = open()
        let work = try XCTUnwrap(store.notebooks.first { $0.name == "Work" })
        let projects = try XCTUnwrap(store.notebooks.first { $0.name == "Projects" })
        XCTAssertNil(work.parent)
        XCTAssertEqual(projects.parent, work.id)

        let loose = try note(store, titled: "Loose")
        XCTAssertNil(loose.notebookID)
        XCTAssertEqual(loose.tags, ["idea"])
        let plan = try note(store, titled: "Plan")
        XCTAssertEqual(plan.notebookID, work.id)
        XCTAssertTrue(plan.isPinned)
        XCTAssertEqual(plan.preview, "Quarter goals")
        XCTAssertEqual(try note(store, titled: "Launch").notebookID, projects.id)

        XCTAssertTrue(try read("Work/Projects/Launch.md").hasPrefix("---\nid: \(try note(store, titled: "Launch").id.uuidString)\n---\n"),
                      "a file without an id gets one; nothing else is added until the note changes")
        XCTAssertTrue(try read("Work/Plan.md").contains("pinned: true"))
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent("Work/.noteit-notebook.json").path))
        store.flush()
        XCTAssertTrue(fm.fileExists(atPath: store.libraryURL.path))

        let reopened = open()
        XCTAssertEqual(Set(reopened.notes.map(\.id)), Set(store.notes.map(\.id)))
        XCTAssertEqual(Set(reopened.notebooks.map(\.id)), Set(store.notebooks.map(\.id)))

        try fm.removeItem(at: reopened.libraryURL)
        let rebuilt = open()
        XCTAssertEqual(Set(rebuilt.notes.map(\.id)), Set(store.notes.map(\.id)), "library.json is rebuilt from the files")
        XCTAssertEqual(try note(rebuilt, titled: "Plan").notebookID, work.id)
        XCTAssertEqual(try note(rebuilt, titled: "Launch").notebookID, projects.id)
    }

    func testMetadataChangesMoveAndRewriteFilesOnFlush() throws {
        let store = open()
        let work = store.createNotebook(name: "Work", symbol: "tray", colorHex: "#0A84FF")
        let id = store.createNote(in: work.id, initial: body("Report\nnumbers")).id
        store.flush()
        XCTAssertTrue(exists("Work/Report.md"))

        store.togglePin(id)
        store.flush()
        XCTAssertTrue(try read("Work/Report.md").contains("pinned: true"))

        store.moveNote(id, to: nil)
        store.flush()
        XCTAssertTrue(exists("Report.md"))
        XCTAssertFalse(exists("Work/Report.md"))

        store.moveNote(id, to: work.id)
        var renamed = try XCTUnwrap(store.notebook(with: work.id))
        renamed.name = "Office"
        store.updateNotebook(renamed)
        store.flush()
        XCTAssertTrue(exists("Office/Report.md"))
        XCTAssertFalse(exists("Work"))

        store.deleteNotebook(work.id)
        store.flush()
        XCTAssertTrue(exists(".trash/Report.md"))
        XCTAssertTrue(try read(".trash/Report.md").contains("deleted: "))
        XCTAssertFalse(exists("Office"), "an emptied notebook folder goes to the Trash")
        XCTAssertNotNil(store.note(with: id)?.deletedAt)
    }

    func testDeletingANestedNotebookRemovesEveryFolderAndNothingComesBack() throws {
        for _ in 0..<5 {
            try? fm.removeItem(at: root)
            try fm.createDirectory(at: content, withIntermediateDirectories: true)
            let store = open()
            var parent: UUID?
            var top: UUID?
            for name in ["A", "B", "C", "D"] {
                let notebook = store.createNotebook(name: name, symbol: "tray", colorHex: "#0A84FF", parentID: parent)
                _ = store.createNote(in: notebook.id, initial: body("\(name) note\nx"))
                parent = notebook.id
                top = top ?? notebook.id
            }
            store.flush()
            XCTAssertTrue(exists("A/B/C/D/D note.md"))

            store.deleteNotebook(try XCTUnwrap(top))
            store.flush()
            XCTAssertFalse(exists("A"))
            XCTAssertEqual(open().notebooks.count, 0, "no notebook comes back from a folder left behind")
        }
    }

    func testANotebookFolderThatCantBeTrashedIsTriedAgain() throws {
        let store = open()
        let storage = try XCTUnwrap(store.markdownStorage)
        let work = store.createNotebook(name: "Work", symbol: "tray", colorHex: "#0A84FF")
        store.flush()
        let trash = storage.trash
        storage.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        store.deleteNotebook(work.id)
        store.flush()
        XCTAssertTrue(exists("Work"))
        XCTAssertEqual(storage.index.notebookFolder(work.id), "Work")

        storage.trash = trash
        store.flush()
        XCTAssertFalse(exists("Work"))
        XCTAssertNil(storage.index.notebookFolder(work.id))
    }

    func testFilesAreRenamedAfterTheTitleOnlyWhenIdleOrDeselected() throws {
        let store = open()
        var now = Date()
        store.markdownClock = { now }
        let id = store.createNote(in: nil, initial: body("First\nx")).id
        store.flush()
        store.selectedNoteID = id
        store.updateBody(id, body("Second\nx"))
        now = try XCTUnwrap(store.note(with: id)).updatedAt.addingTimeInterval(1)
        store.flush()
        XCTAssertTrue(exists("First.md"), "not while the note is being edited")
        XCTAssertTrue(store.hasPendingMarkdownRenames)

        now = now.addingTimeInterval(5)
        store.flush()
        XCTAssertTrue(exists("Second.md"))
        XCTAssertFalse(exists("First.md"))

        store.updateBody(id, body("Third\nx"))
        now = try XCTUnwrap(store.note(with: id)).updatedAt.addingTimeInterval(1)
        store.flush()
        XCTAssertTrue(exists("Second.md"))
        store.selectedNoteID = nil
        store.flush()
        XCTAssertTrue(exists("Third.md"), "leaving the note renames it")
    }

    func testAnOutsideEditReachesTheDerivedIndexes() throws {
        try put("Note.md", "# Note\n\nold\n")
        let store = open()
        let id = try note(store, titled: "Note").id
        store.flush()
        let recorder = RecordingDerivedIndex()
        store.registerDerivedIndex(recorder)
        let text = try read("Note.md").replacingOccurrences(of: "old", with: "new words")
        try Data(text.utf8).write(to: content.appendingPathComponent("Note.md"))
        store.rescanNow()
        XCTAssertTrue(recorder.calls.contains { if case .changed(id, let body) = $0 { return body.contains("new words") } else { return false } })
        XCTAssertEqual(store.note(with: id)?.preview, "new words")
    }

    func testSyncExportsAMarkdownFileAsRTFD() throws {
        try put("Plan.md", "---\nmood: calm\n---\n# Plan\n\n- [ ] ship\n")
        let store = open()
        let id = try note(store, titled: "Plan").id
        store.dropCachedBody(id)
        let payload = try store.exportPayload(id: id, kind: .note, deviceID: "md")
        let text = try NoteStore.deserializeBody(XCTUnwrap(payload.body))
        XCTAssertEqual(text.string, store.body(for: id).string)
        XCTAssertTrue(text.string.hasPrefix("Plan\n"))

        try fm.removeItem(at: content.appendingPathComponent("Plan.md"))
        store.dropCachedBody(id)
        XCTAssertThrowsError(try store.exportPayload(id: id, kind: .note, deviceID: "md"), "a missing file never syncs as empty")
    }

    func testRemoteNotesAndNotebooksLandInTheirFolders() throws {
        let rtfd = NoteStore(rootURL: root.appendingPathComponent("rtfd", isDirectory: true))
        let work = rtfd.createNotebook(name: "Work", symbol: "tray", colorHex: "#0A84FF")
        let id = rtfd.createNote(in: work.id, initial: body("Remote\nfrom the other Mac")).id
        rtfd.flush()
        try put("Local.md", "# Local\n")

        let store = open()
        try store.applyRemote(rtfd.exportPayload(id: work.id, kind: .notebook, deviceID: "a"))
        let payload = try rtfd.exportPayload(id: id, kind: .note, deviceID: "a")
        try store.applyRemote(payload)
        XCTAssertEqual(store.note(with: id)?.revision, payload.revision)
        XCTAssertTrue(try read("Work/Remote.md").contains("id: \(id.uuidString)"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: content.appendingPathComponent(".noteit/staging").path), [])
        XCTAssertTrue(store.versions(of: id).isEmpty)

        let text = try read("Work/Remote.md").replacingOccurrences(of: "Z\n---\n", with: "Z\nmood: calm\n---\n")
        try Data(text.utf8).write(to: content.appendingPathComponent("Work/Remote.md"))
        store.rescanNow()
        rtfd.updateBody(id, body("Remote\nedited"))
        try store.applyRemote(rtfd.exportPayload(id: id, kind: .note, deviceID: "a"))
        XCTAssertTrue(try read("Work/Remote.md").contains("mood: calm"), "unknown keys survive a remote edit")
        XCTAssertTrue(try read("Work/Remote.md").hasSuffix("edited\n"))

        var renamed = try XCTUnwrap(rtfd.notebook(with: work.id))
        renamed.name = "Office"
        rtfd.updateNotebook(renamed)
        try store.applyRemote(rtfd.exportPayload(id: work.id, kind: .notebook, deviceID: "a"))
        XCTAssertTrue(exists("Office/Remote.md"))
        XCTAssertFalse(exists("Work"))

        store.applyRemoteDeletion(work.id, kind: .notebook)
        XCTAssertTrue(exists("Remote.md"), "a note of a notebook deleted elsewhere moves to the top")
        XCTAssertFalse(exists("Office"))
    }

    func testANoteWithAnAttachmentOver25MBSaysWhyItIsUnsavedAndWaitsForAChangeInsteadOfRetrying() throws {
        let store = open()
        let id = store.createNote(in: nil, initial: body("Small\nfine")).id
        store.flush()
        store.waitForMarkdownWrites(upTo: 10)
        let saved = try read("Small.md")

        store.updateBody(id, OversizedAttachment.body("Small", attachmentNamed: "huge.mov"))
        store.flush()
        store.waitForMarkdownWrites(upTo: 10)
        let notice = try XCTUnwrap(store.bodySaveNotice(for: id))
        XCTAssertTrue(notice.contains("huge.mov") && notice.contains("25 MB"), notice)
        XCTAssertTrue(store.isBodyDirty(id))
        XCTAssertFalse(store.isBodyWriteBlocked(id), "the note stays editable so the attachment can be removed")
        XCTAssertEqual(try read("Small.md"), saved)
        func recoveredNotes() throws -> [URL] {
            try fm.contentsOfDirectory(at: store.recoveryURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
        }
        XCTAssertEqual(try recoveredNotes().count, 1, "the unsaved body is kept outside memory too")

        let attempts = store.markdownBodyWritesStarted
        store.flush()
        store.waitForMarkdownWrites(upTo: 10)
        XCTAssertEqual(store.markdownBodyWritesStarted, attempts, "the same body isn't tried again")

        store.updateBody(id, body("Small\nwithout it"))
        store.flush()
        store.waitForMarkdownWrites(upTo: 10)
        XCTAssertNil(store.bodySaveNotice(for: id))
        XCTAssertFalse(store.isBodyDirty(id))
        XCTAssertTrue(try read("Small.md").hasSuffix("without it\n"))
        XCTAssertEqual(try recoveredNotes(), [])
    }

    func testAnEditAfterAnOversizedOneIsSavedEvenWhenItTakesTheFreedSnapshotsAddress() throws {
        let store = open()
        let id = store.createNote(in: nil, initial: body("Small\nfine")).id
        store.flush()
        store.waitForMarkdownWrites(upTo: 10)
        store.updateBody(id, OversizedAttachment.body("Small", attachmentNamed: "huge.mov"))
        store.flush()
        store.waitForMarkdownWrites(upTo: 10)
        XCTAssertNotNil(store.bodySaveNotice(for: id))
        let failed = ObjectIdentifier(try XCTUnwrap(store.cachedBody(id)))

        store.updateBody(id, OversizedAttachment.body("Small", attachmentNamed: "huge.mov", bytes: 10))
        let edited = body("Small\nwithout it")
        var held: [NSAttributedString] = []
        var reused: NSAttributedString?
        for _ in 0..<200_000 {
            let candidate = NSAttributedString(attributedString: edited)
            if ObjectIdentifier(candidate) == failed { reused = candidate; break }
            held.append(candidate)
        }
        held.removeAll()
        let newer = try XCTUnwrap(reused, "no allocation took the freed snapshot's address")
        store.updateBody(id, newer)
        store.flush()
        store.waitForMarkdownWrites(upTo: 10)
        XCTAssertNil(store.bodySaveNotice(for: id))
        XCTAssertFalse(store.isBodyDirty(id))
        XCTAssertTrue(try read("Small.md").hasSuffix("without it\n"))
    }

    func testAnEditThatCantBeSavedIsntSyncedSoARelaunchCantPushAnOlderVersionOverIt() async throws {
        let backend = InMemoryBackend()
        _ = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false)
        let stateURL = root.appendingPathComponent("a-sync.json")
        func engine(_ store: NoteStore) -> SyncEngine {
            SyncEngine(backend: backend, cipher: PassthroughCipher(), local: NoteStoreSyncAdapter(store: store, deviceID: "A"),
                       stateURL: stateURL, deviceID: "A", deviceName: "A")
        }
        var store: NoteStore? = open()
        let id = store!.createNote(in: nil, initial: body("Small\nfine")).id
        store!.flush()
        store!.waitForMarkdownWrites(upTo: 10)
        var sync: SyncEngine? = engine(store!)
        let first = try await sync!.sync()
        XCTAssertEqual(first.pushed, 1)
        let saved = store!.note(with: id)?.revision

        store!.updateBody(id, OversizedAttachment.body("Small", attachmentNamed: "huge.mov"))
        store!.flush()
        store!.waitForMarkdownWrites(upTo: 10)
        XCTAssertNotNil(store!.bodySaveNotice(for: id))
        let unsaved = try await sync!.sync()
        XCTAssertEqual(unsaved.pushed, 0, "an edit that isn't in the note's file isn't sent to other devices")
        XCTAssertFalse(unsaved.errors.isEmpty)

        sync = nil
        store = nil
        let relaunched = open()
        XCTAssertEqual(relaunched.note(with: id)?.revision, saved)
        let kept = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("data/recovery").path)
        XCTAssertTrue(kept.contains { $0.hasPrefix(id.uuidString) }, "a copy that can't be restored in full stays in recovery/")
        let afterRelaunch = try await engine(relaunched).sync()
        XCTAssertEqual(afterRelaunch.pushed, 0, "nothing older is pushed over what other devices have")
        XCTAssertEqual(afterRelaunch.errors, [])
    }

    func testARemoteNoteWithAnAttachmentOver25MBIsRefusedForSync() async throws {
        let rtfd = NoteStore(rootURL: root.appendingPathComponent("rtfd", isDirectory: true))
        let id = rtfd.createNote(in: nil, initial: OversizedAttachment.body("Remote", attachmentNamed: "huge.mov")).id
        rtfd.flush()
        let payload = try rtfd.exportPayload(id: id, kind: .note, deviceID: "a")

        let store = open()
        let adapter = NoteStoreSyncAdapter(store: store, deviceID: "b")
        do {
            try await adapter.apply(payload)
            XCTFail("applied")
        } catch let refusal as SyncRecordRefused {
            XCTAssertTrue(refusal.reason.contains("huge.mov") && refusal.reason.contains("25 MB"), refusal.reason)
        }
        do {
            try await adapter.importConflictCopy(payload, fromDevice: "a")
            XCTFail("copied")
        } catch is SyncRecordRefused {}
        XCTAssertNil(store.note(with: id))
        XCTAssertFalse(exists("Remote.md"))
    }

    func testAdoptedFolderKeepsFileNames() throws {
        try put("my-file.md", "# Some title\n\ntext\n")
        let store = open(renames: false)
        let id = try note(store, titled: "Some title").id
        store.updateBody(id, body("New title\ntext"))
        store.flush()
        XCTAssertTrue(exists("my-file.md"))
        XCTAssertFalse(exists("New title.md"))
    }

    func testVersionsAreNoteItDocuments() throws {
        let store = open()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        store.history.now = { clock }
        let id = store.createNote(in: nil, initial: body("V1\none")).id
        store.flush()
        store.updateBody(id, body("V1\ntwo"))
        store.flush()
        clock.addTimeInterval(11 * 60)
        store.updateBody(id, body("V1\nthree"))
        store.flush()

        let versions = store.versions(of: id)
        XCTAssertEqual(versions.map(\.url.pathExtension), ["noteitdoc", "noteitdoc"])
        XCTAssertEqual(try versions.map { try store.history.load($0).text.string.withoutFinalNewline }, ["V1\ntwo", "V1\none"])
    }

    func testFileChangedWhileNoteItWasClosedIsReadAtLaunch() throws {
        let store = open()
        let id = store.createNote(in: nil, initial: body("Draft\nold")).id
        store.flush()
        let text = try read("Draft.md").replacingOccurrences(of: "old", with: "new #edited")
        try Data(text.utf8).write(to: content.appendingPathComponent("Draft.md"))

        let reopened = open()
        let meta = try XCTUnwrap(reopened.note(with: id))
        XCTAssertEqual(meta.tags, ["edited"])
        XCTAssertEqual(reopened.body(for: id).string.withoutFinalNewline, "Draft\nnew #edited")
        XCTAssertNotEqual(meta.revision, store.note(with: id)?.revision)
        XCTAssertEqual(reopened.notes.count, 1)
    }

    func testNothingIsWrittenWhileTheContentFolderIsMissing() throws {
        let store = open()
        let id = store.createNote(in: nil, initial: body("Away\nx")).id
        store.flush()
        let moved = root.appendingPathComponent("unmounted", isDirectory: true)
        try fm.moveItem(at: content, to: moved)
        store.updateBody(id, body("Away\nchanged"))
        store.flush()
        XCTAssertFalse(fm.fileExists(atPath: content.path), "the folder isn't created again")
        XCTAssertTrue(store.isBodyDirty(id))
    }
}
