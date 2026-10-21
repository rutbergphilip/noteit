import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class TagEditTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-tagedit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func add(_ store: NoteStore, _ string: String) -> UUID {
        store.createNote(in: nil, initial: NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 14)])).id
    }

    private func text(_ store: NoteStore, _ id: UUID) -> String { store.body(for: id).string }

    func testRenameRewritesTextAndNestedTags() async {
        let store = makeStore()
        let a = add(store, "Plan\n#work and #work/q3")
        let b = add(store, "Other\n#home")
        let result = await store.renameTag("work", to: "job")
        XCTAssertEqual(text(store, a), "Plan\n#job and #job/q3")
        XCTAssertEqual(text(store, b), "Other\n#home")
        XCTAssertEqual(Set(result.changed.keys), [a])
        XCTAssertTrue(store.notesTagged("work").isEmpty)
        XCTAssertEqual(store.notesTagged("job").map(\.id), [a])
    }

    func testRenameRefusesToNestTagsTooDeep() async {
        let store = makeStore()
        let a = add(store, "Plan\n#a and #a/b/c/d")
        let result = await store.renameTag("a", to: "x/y/z")
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertEqual(text(store, a), "Plan\n#a and #a/b/c/d")
    }

    func testRenameOntoExistingTagMerges() async {
        let store = makeStore()
        let a = add(store, "A\n#work")
        let b = add(store, "B\n#job")
        _ = await store.renameTag("work", to: "job")
        XCTAssertEqual(Set(store.notesTagged("job").map(\.id)), [a, b])
        XCTAssertEqual(store.tagTree.map(\.path), ["job"])
    }

    func testDeleteKeepsWords() async {
        let store = makeStore()
        let a = add(store, "A\nsee #draft later")
        _ = await store.deleteTag("draft")
        XCTAssertEqual(text(store, a), "A\nsee later")
    }

    func testTrashedAndLockedNotesAreLeftAlone() async {
        let store = makeStore()
        let trashed = add(store, "T\n#work")
        let locked = add(store, "L\n#work")
        _ = store.moveToRecentlyDeleted([trashed])
        store.notes[store.noteIndex(locked)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        let result = await store.renameTag("work", to: "job")
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertEqual(result.untouchedInTrash, 1)
        XCTAssertEqual(text(store, trashed), "T\n#work")
    }

    func testEditRecordsOneVersionPerNote() async throws {
        let store = makeStore()
        let a = add(store, "A\n#work #work/x")
        let before = try store.versions(of: a).count
        _ = await store.renameTag("work", to: "job")
        XCTAssertEqual(try store.versions(of: a).count, before + 1)
    }

    func testUndoRestoresOnlyNotesNotEditedSince() async throws {
        let store = makeStore()
        let a = add(store, "A\n#work")
        let b = add(store, "B\n#work")
        let result = await store.renameTag("work", to: "job")
        try store.editBody(b, actionName: "Typing") { $0.append(NSAttributedString(string: " more")) }
        XCTAssertEqual(store.undoTagEdit(result), 1)
        XCTAssertEqual(text(store, a), "A\n#work")
        XCTAssertEqual(text(store, b), "B\n#job more")
    }

    func testUndoPutsBackSmartFolderQueriesNotEditedSince() async throws {
        let store = makeStore()
        _ = add(store, "A\n#work")
        _ = try store.createSmartFolder(name: "Work", query: "tag:work is:todo", symbol: SmartFolder.defaultSymbol)
        _ = try store.createSmartFolder(name: "Mine", query: "tag:work", symbol: SmartFolder.defaultSymbol)
        let result = await store.renameTag("work", to: "job")
        XCTAssertEqual(store.smartFolders.map(\.query), ["tag:job is:todo", "tag:job"])
        let mine = try XCTUnwrap(store.smartFolders.first { $0.name == "Mine" })
        try store.updateSmartFolder(mine.id, name: "Mine", query: "tag:job -x", symbol: SmartFolder.defaultSymbol)
        store.undoTagEdit(result)
        XCTAssertEqual(store.smartFolders.map(\.query), ["tag:work is:todo", "tag:job -x"])
    }

    func testSelectionFollowsRenamedTagAndUndo() async {
        let store = makeStore()
        _ = add(store, "A\n#work/q3")
        store.selection = .tag("work/q3")
        let result = await store.renameTag("work", to: "job/y26")
        XCTAssertEqual(store.selection, .tag("job/y26/q3"))
        store.undoTagEdit(result)
        XCTAssertEqual(store.selection, .tag("work/q3"))

        store.selection = .tag("work")
        let deleted = await store.deleteTag("work")
        XCTAssertEqual(store.selection, .allNotes)
        store.undoTagEdit(deleted)
        XCTAssertEqual(store.selection, .tag("work"))

        store.selection = .tag("home")
        _ = await store.deleteTag("work")
        XCTAssertEqual(store.selection, .tag("home"))
    }

    func testCancelStopsBetweenBatches() async {
        let store = makeStore()
        for i in 0..<120 { _ = add(store, "N\(i)\n#bulk") }
        let result = await store.renameTag("bulk", to: "mass") { _, _ in false }
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.changed.count, NoteStore.tagEditBatchSize)
    }

    func testRenameFiveHundredNotesUnderBudget() async {
        let store = makeStore()
        for i in 0..<500 { _ = add(store, "N\(i)\nsome text #big here") }
        let start = Date()
        let result = await store.renameTag("big", to: "large")
        XCTAssertEqual(result.changed.count, 500)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }
}
