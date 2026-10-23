import Combine
import XCTest
import NoteItDocTestSupport
import NoteItAPI
import NoteItCore
@testable import NoteIt

@MainActor
final class LibraryDiffTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-feed-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func note(_ id: UUID = UUID(), pinned: Bool = false, deletedAt: Date? = nil) -> NoteMeta {
        NoteMeta(id: id, notebookID: nil, title: "T", preview: "", isPinned: pinned, createdAt: at, updatedAt: at, tags: [],
                 revision: nil, deletedAt: deletedAt)
    }

    private func notebook(_ id: UUID = UUID(), name: String = "Work") -> Notebook {
        Notebook(id: id, name: name, symbol: "folder", colorHex: "#0A84FF", sortIndex: 0, revision: nil, modifiedAt: at)
    }

    private func diff(_ oldNotes: [NoteMeta], _ newNotes: [NoteMeta], _ oldBooks: [Notebook] = [],
                      _ newBooks: [Notebook] = []) -> [LibraryChange] {
        func map<T: Identifiable>(_ items: [T]) -> [UUID: T] where T.ID == UUID {
            Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        }
        return LibraryDiff.changes(oldNotes: map(oldNotes), newNotes: map(newNotes), oldNotebooks: map(oldBooks),
                                   newNotebooks: map(newBooks), at: at)
    }

    func testCreatedUpdatedPurged() {
        let kept = note()
        var edited = kept
        edited.title = "Changed"
        let gone = note()
        let added = note()
        let book = notebook()
        let changes = diff([kept, gone], [edited, added], [], [book])
        XCTAssertEqual(changes.first, LibraryChange(kind: .notebook, id: book.id, op: .created, at: at))
        let notes = changes.dropFirst()
        XCTAssertEqual(notes.map(\.id), [kept.id, gone.id, added.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.op) }),
                       [kept.id: .updated, gone.id: .purged, added.id: .created])
    }

    func testDeleteAndRestore() {
        let live = note()
        let trashed = note(live.id, deletedAt: at)
        XCTAssertEqual(diff([live], [trashed]).map(\.op), [.deleted])
        XCTAssertEqual(diff([trashed], [live]).map(\.op), [.restored])
        let book = notebook()
        XCTAssertEqual(diff([], [], [book], []), [LibraryChange(kind: .notebook, id: book.id, op: .deleted, at: at)])
    }

    func testPinOnlyIsUpdated() {
        let plain = note()
        XCTAssertEqual(diff([plain], [note(plain.id, pinned: true)]).map(\.op), [.updated])
    }

    func testNotebookRenameIsUpdated() {
        let book = notebook()
        XCTAssertEqual(diff([], [], [book], [notebook(book.id, name: "Home")]),
                       [LibraryChange(kind: .notebook, id: book.id, op: .updated, at: at)])
    }

    func testNoChangeNoOutput() {
        let same = note()
        let book = notebook()
        XCTAssertTrue(diff([same], [same], [book], [book]).isEmpty)
    }

    func testFeedCoalescesBurst() {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        let feed = LibraryChangeFeed(store: store, debounce: .milliseconds(150))
        var batches: [[LibraryChange]] = []
        let delivered = expectation(description: "one batch")
        let subscription = feed.subscribe { batch in
            batches.append(batch)
            delivered.fulfill()
        }
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Start")).id
        for index in 0..<9 { store.updateBody(id, NSAttributedString(string: "Edit \(index)")) }
        wait(for: [delivered], timeout: TestTiming.scaled(2))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.map(\.op), [.created])
        XCTAssertEqual(batches.first?.map(\.id), [id])
        subscription.cancel()
        store.togglePin(id)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(batches.count, 1)
    }
}
