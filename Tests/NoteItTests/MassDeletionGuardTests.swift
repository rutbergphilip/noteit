import AppKit
import XCTest
@testable import NoteIt
import NoteItCore

/// markdown-storage Task 4.3: many files disappearing at once wait for the user.
@MainActor
final class MassDeletionGuardTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-massdelete-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func open() -> NoteStore {
        let data = root.appendingPathComponent("data", isDirectory: true)
        let store = NoteStore(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                        renameFilesOnTitleChange: false),
                              bodyStorage: MarkdownBodyStorageTests.make(root, renames: false))
        store.markdownClock = { Date().addingTimeInterval(10) }
        return store
    }

    private func put(_ path: String, _ text: String) throws {
        let url = content.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// `count` notes in `folder`, plus `others` loose notes.
    private func library(_ count: Int, in folder: String = "Work", others: Int = 0) throws -> NoteStore {
        for index in 0..<count { try put("\(folder)/Note \(index).md", "# Note \(index)\n\ntext \(index)\n") }
        for index in 0..<others { try put("Other \(index).md", "# Other \(index)\n") }
        let store = open()
        store.flush()
        return store
    }

    private func ids(_ store: NoteStore, prefix: String) -> [UUID] {
        store.notes.filter { $0.title.hasPrefix(prefix) }.map(\.id)
    }

    func testThreshold() {
        XCTAssertTrue(MassDeletionGuard.mustHold(removed: 21, totalFiles: 1000))
        XCTAssertFalse(MassDeletionGuard.mustHold(removed: 20, totalFiles: 201))
        XCTAssertTrue(MassDeletionGuard.mustHold(removed: 5, totalFiles: 50))
        XCTAssertFalse(MassDeletionGuard.mustHold(removed: 4, totalFiles: 10))
        XCTAssertFalse(MassDeletionGuard.mustHold(removed: 0, totalFiles: 10))
    }

    func testAHeldBatchChangesNothingUntilTheUserConfirms() throws {
        let store = try library(6, in: "Work", others: 10)
        let held = ids(store, prefix: "Note ")
        let work = try XCTUnwrap(store.notebooks.first { $0.name == "Work" }).id
        let revisions = held.map { store.note(with: $0)?.revision }
        var asked: [Int] = []
        store.onManyNotesDisappeared = { asked.append($0) }

        try fm.removeItem(at: content.appendingPathComponent("Work"))
        store.rescanMarkdownFolder()
        store.flush()

        XCTAssertEqual(asked, [6], "a deleted notebook folder counts its notes")
        XCTAssertEqual(store.heldMarkdownDeletions, Set(held))
        XCTAssertNotNil(store.notebook(with: work))
        XCTAssertEqual(held.map { store.note(with: $0)?.revision }, revisions)
        XCTAssertTrue(held.allSatisfy { store.note(with: $0)?.deletedAt == nil })
        XCTAssertTrue(store.syncDeletions().isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent(".trash").path))
        XCTAssertFalse(fm.fileExists(atPath: content.appendingPathComponent("Work").path), "nothing recreates the folder")

        let first = held[0]
        store.dropCachedBody(first)
        XCTAssertEqual(store.loadError(for: first), NoteStore.missingFileReason)
        XCTAssertTrue(store.body(for: first).string.contains("text"), "a held note shows its last known text")

        store.rescanMarkdownFolder()
        XCTAssertEqual(asked, [6], "the same batch isn't asked about twice")

        store.confirmHeldDeletions()
        store.flush()
        XCTAssertTrue(store.heldMarkdownDeletions.isEmpty)
        XCTAssertTrue(held.allSatisfy { store.note(with: $0)?.deletedAt != nil })
        XCTAssertNil(store.notebook(with: work))
        XCTAssertNil(store.loadError(for: first))
        let trash = try fm.contentsOfDirectory(atPath: content.appendingPathComponent(".trash").path)
        XCTAssertEqual(trash.filter { $0.hasSuffix(".md") }.count, 6)
    }

    func testFilesComingBackClearTheBatch() throws {
        let store = try library(6, others: 10)
        let held = ids(store, prefix: "Note ")
        let away = root.appendingPathComponent("away")
        try fm.moveItem(at: content.appendingPathComponent("Work"), to: away)
        store.rescanMarkdownFolder()
        XCTAssertEqual(store.heldMarkdownDeletions.count, 6)

        try fm.moveItem(at: away, to: content.appendingPathComponent("Work"))
        store.rescanMarkdownFolder()
        store.flush()
        XCTAssertTrue(store.heldMarkdownDeletions.isEmpty)
        XCTAssertTrue(held.allSatisfy { store.note(with: $0)?.deletedAt == nil && store.loadError(for: $0) == nil })
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("data/\(MassDeletionGuard.fileName)").path))
    }

    func testNotNowAsksAgainAtTheNextLaunch() throws {
        var store: NoteStore? = try library(6, others: 10)
        let held = try XCTUnwrap(store.map { ids($0, prefix: "Note ") })
        try fm.removeItem(at: content.appendingPathComponent("Work"))
        store?.rescanMarkdownFolder()
        store?.flush()
        store = nil

        let reopened = open()
        var asked: [Int] = []
        reopened.onManyNotesDisappeared = { asked.append($0) }
        reopened.askAboutHeldDeletions()
        XCTAssertEqual(asked, [6])
        XCTAssertEqual(reopened.heldMarkdownDeletions, Set(held))
        XCTAssertTrue(held.allSatisfy { reopened.note(with: $0)?.deletedAt == nil })
        XCTAssertEqual(reopened.loadError(for: held[0]), NoteStore.missingFileReason)
    }

    func testASyncApplyToAHeldNoteWritesItsFileBackAndReleasesIt() throws {
        let store = try library(6, others: 10)
        let held = ids(store, prefix: "Note ")
        let work = try XCTUnwrap(store.notebooks.first { $0.name == "Work" }).id
        try fm.removeItem(at: content.appendingPathComponent("Work"))
        store.rescanMarkdownFolder()
        XCTAssertEqual(store.heldMarkdownDeletions, Set(held))

        let id = held[0]
        try store.applyRemote(RawMetaSupport.notePayload(id, revision: UUID(), text: "From sync\nnew text", notebookID: work))
        XCTAssertEqual(store.heldMarkdownDeletions, Set(held.dropFirst()))
        XCTAssertNil(store.loadError(for: id))
        let file = try XCTUnwrap(store.markdownStorage).fileURL(for: id)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("new text"))

        store.rescanMarkdownFolder()
        store.flush()
        XCTAssertEqual(store.heldMarkdownDeletions, Set(held.dropFirst()))
        XCTAssertNil(store.note(with: id)?.deletedAt)
        XCTAssertEqual(store.notebooks.filter { $0.name.hasPrefix("Work") }.map(\.id), [work], "the folder it brought back is the same notebook")
        XCTAssertTrue(held.dropFirst().allSatisfy { store.note(with: $0)?.deletedAt == nil })
    }

    func testASmallDeletionAppliesRightAway() throws {
        let store = try library(4, others: 6)
        var asked: [Int] = []
        store.onManyNotesDisappeared = { asked.append($0) }
        try fm.removeItem(at: content.appendingPathComponent("Work"))
        store.rescanMarkdownFolder()
        XCTAssertTrue(asked.isEmpty)
        XCTAssertTrue(ids(store, prefix: "Note ").allSatisfy { store.note(with: $0)?.deletedAt != nil })
    }

    func testAMassDeletionWhileNoteItWasClosedIsHeldAtLaunch() throws {
        var store: NoteStore? = try library(25)
        let held = try XCTUnwrap(store.map { ids($0, prefix: "Note ") })
        store = nil
        try fm.removeItem(at: content.appendingPathComponent("Work"))

        let reopened = open()
        XCTAssertEqual(reopened.heldMarkdownDeletions, Set(held))
        XCTAssertTrue(held.allSatisfy { reopened.note(with: $0)?.deletedAt == nil })
        XCTAssertNotNil(reopened.notebooks.first { $0.name == "Work" })
    }
}
