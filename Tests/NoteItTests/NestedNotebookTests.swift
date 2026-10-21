import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class NestedNotebookTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-nested-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func chain(_ store: NoteStore, _ depth: Int) -> [Notebook] {
        var result: [Notebook] = []
        for level in 0..<depth {
            result.append(store.createNotebook(name: "L\(level)", symbol: "folder", colorHex: "#0A84FF", parentID: result.last?.id))
        }
        return result
    }

    func testCreateNestedAndPath() {
        let store = makeStore()
        let books = chain(store, 3)
        XCTAssertEqual(store.notebook(with: books[2].id)?.parent, books[1].id)
        XCTAssertEqual(store.notebookPathTitle(books[2].id), "L0 › L1 › L2")
        XCTAssertEqual(store.notebookTree.roots, [books[0].id])
    }

    func testMoveRefusesCyclesAndFifthLevel() {
        let store = makeStore()
        let books = chain(store, 4)
        XCTAssertFalse(store.moveNotebook(books[0].id, under: books[2].id))
        XCTAssertFalse(store.moveNotebook(books[1].id, under: books[1].id))
        let extra = store.createNotebook(name: "X", symbol: "folder", colorHex: "#0A84FF")
        XCTAssertFalse(store.moveNotebook(extra.id, under: books[3].id))
        XCTAssertTrue(store.moveNotebook(extra.id, under: books[2].id))
        XCTAssertEqual(store.notebook(with: extra.id)?.parent, books[2].id)
        XCTAssertTrue(store.moveNotebook(books[1].id, under: nil, at: 0))
        XCTAssertEqual(store.notebookTree.roots, [books[1].id, books[0].id])
    }

    func testMoveRenumbersOnlySiblings() {
        let store = makeStore()
        let a = store.createNotebook(name: "A", symbol: "folder", colorHex: "#0A84FF")
        let b = store.createNotebook(name: "B", symbol: "folder", colorHex: "#0A84FF")
        let c1 = store.createNotebook(name: "C1", symbol: "folder", colorHex: "#0A84FF", parentID: a.id)
        let c2 = store.createNotebook(name: "C2", symbol: "folder", colorHex: "#0A84FF", parentID: a.id)
        let bRevision = store.notebook(with: b.id)?.revision
        store.moveNotebooks(from: IndexSet(integer: 1), to: 0, parent: a.id)
        XCTAssertEqual(store.notebookTree.children(of: a.id), [c2.id, c1.id])
        XCTAssertEqual(store.notebook(with: b.id)?.revision, bRevision)
    }

    func testSelectionAndCountIncludeDescendants() {
        let store = makeStore()
        let books = chain(store, 2)
        _ = store.createNote(in: books[0].id, initial: NSAttributedString(string: "Top"))
        _ = store.createNote(in: books[1].id, initial: NSAttributedString(string: "Inner"))
        XCTAssertEqual(store.count(for: .notebook(books[0].id)), 2)
        XCTAssertEqual(store.count(for: .notebook(books[1].id)), 1)
        XCTAssertEqual(store.notes(for: .notebook(books[0].id), search: "").count, 2)
    }

    func testDeleteCascadesToSubNotebooksAndTheirNotes() {
        let store = makeStore()
        let books = chain(store, 3)
        let note = store.createNote(in: books[2].id, initial: NSAttributedString(string: "Deep"))
        store.deleteNotebook(books[0].id)
        XCTAssertTrue(store.notebooks.isEmpty)
        XCTAssertNotNil(store.note(with: note.id)?.deletedAt)
    }

    func testOrphanShowsAtTop() {
        let store = makeStore()
        var orphan = store.createNotebook(name: "Orphan", symbol: "folder", colorHex: "#0A84FF")
        orphan.parent = UUID()
        store.notebooks[store.notebooks.firstIndex { $0.id == orphan.id }!] = orphan
        XCTAssertEqual(store.notebookTree.roots, [orphan.id])
    }

    func testRevisionFieldsStableForTopLevel() {
        let top = Notebook(name: "A", symbol: "tray", colorHex: "#0A84FF", sortIndex: 1)
        XCTAssertEqual(NoteStore.revisionFields(top), ["notebook", "A", "tray", "#0A84FF", "1"])
        var nested = top
        nested.parent = UUID()
        XCTAssertEqual(NoteStore.revisionFields(nested).last, "parent \(nested.parent!.uuidString)")
    }
}
