import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItMarkdown

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
        NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                            renameFilesOnTitleChange: renames),
                  bodyStorage: MarkdownBodyStorageTests.make(root, renames: renames))
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
        store.rescanMarkdownFolder()
        XCTAssertTrue(recorder.calls.contains { if case .changed(id, let body) = $0 { return body.contains("new words") } else { return false } })
        XCTAssertEqual(store.note(with: id)?.preview, "new words")
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
