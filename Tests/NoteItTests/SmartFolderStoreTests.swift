import Foundation
import NoteItCore
import NoteItSync
import XCTest
@testable import NoteIt

@MainActor
final class SmartFolderStoreTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-smart-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        NoteStore.syncJournalEnabled = false
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    func testRoundTripKeepsOrderAndFields() throws {
        let store = makeStore()
        let a = try store.createSmartFolder(name: " Due soon ", query: "due:7d", symbol: "calendar")
        let b = try store.createSmartFolder(name: "Work", query: "tag:work is:todo")
        store.moveSmartFolders(fromOffsets: [1], toOffset: 0)
        store.flush()
        XCTAssertFalse(fm.fileExists(atPath: store.rootURL.appendingPathComponent("sync-deletions.json").path))

        let reopened = makeStore()
        XCTAssertEqual(reopened.sortedSmartFolders.map(\.id), [b.id, a.id])
        let due = try XCTUnwrap(reopened.smartFolder(with: a.id))
        XCTAssertEqual(due.name, "Due soon")
        XCTAssertEqual(due.symbol, "calendar")
        XCTAssertNotNil(due.revision)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.smartFoldersURL)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNil(json["appliedRemoteRevisions"])
        XCTAssertNil(json["pendingDeletions"])
    }

    func testCorruptFileIsCopiedAsideAndListStartsEmpty() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: root.appendingPathComponent("smart-folders.json"))
        let store = makeStore()
        XCTAssertTrue(store.smartFolders.isEmpty)
        let copies = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("smart-folders.corrupt-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(copies[0]), encoding: .utf8), "{not json")

        try store.createSmartFolder(name: "New", query: "is:pinned")
        store.flush()
        XCTAssertEqual(makeStore().smartFolders.map(\.name), ["New"])
    }

    func testLimits() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.createSmartFolder(name: "  ", query: "x")) { XCTAssertEqual($0 as? SmartFolderError, .emptyName) }
        XCTAssertThrowsError(try store.createSmartFolder(name: String(repeating: "n", count: 61), query: "x")) {
            XCTAssertEqual($0 as? SmartFolderError, .nameTooLong)
        }
        XCTAssertThrowsError(try store.createSmartFolder(name: "n", query: "")) { XCTAssertEqual($0 as? SmartFolderError, .emptyQuery) }
        XCTAssertThrowsError(try store.createSmartFolder(name: "n", query: String(repeating: "q", count: 501))) {
            XCTAssertEqual($0 as? SmartFolderError, .queryTooLong)
        }
        XCTAssertNoThrow(try store.createSmartFolder(name: String(repeating: "n", count: 60), query: String(repeating: "q", count: 500)))
        for i in 1..<SmartFolder.maxCount { try store.createSmartFolder(name: "F\(i)", query: "x") }
        XCTAssertThrowsError(try store.createSmartFolder(name: "One more", query: "x")) { XCTAssertEqual($0 as? SmartFolderError, .tooMany) }
    }

    func testFolderShowsMatchingActiveNotesAndSearchNarrowsIt() throws {
        let store = makeStore()
        let work = store.createNote(in: nil, initial: NSAttributedString(string: "Report\n#work draft"))
        let other = store.createNote(in: nil, initial: NSAttributedString(string: "Shopping\n#home"))
        let gone = store.createNote(in: nil, initial: NSAttributedString(string: "Old\n#work"))
        _ = other
        store.moveToRecentlyDeleted([gone.id])
        store.flush()
        let folder = try store.createSmartFolder(name: "Work", query: "tag:work")
        XCTAssertEqual(store.notes(for: .smartFolder(folder.id), search: "").map(\.id), [work.id])
        XCTAssertEqual(store.count(for: .smartFolder(folder.id)), 1)
        XCTAssertTrue(store.notes(for: .smartFolder(folder.id), search: "shopping").isEmpty)
        XCTAssertEqual(store.notes(for: .smartFolder(folder.id), search: "draft").map(\.id), [work.id])

        try store.updateSmartFolder(folder.id, name: "Home", query: "tag:home", symbol: "")
        XCTAssertEqual(store.notes(for: .smartFolder(folder.id), search: "").map(\.id), [other.id])
        XCTAssertEqual(store.smartFolder(with: folder.id)?.symbol, SmartFolder.defaultSymbol)
        XCTAssertTrue(store.notes(for: .smartFolder(UUID()), search: "").isEmpty)
    }

    func testTagAndNotebookRenamesRewriteQueries() async throws {
        let store = makeStore()
        let parent = store.createNotebook(name: "Work", symbol: "tray", colorHex: "#0A84FF")
        let child = store.createNotebook(name: "Clients", symbol: "tray", colorHex: "#0A84FF", parentID: parent.id)
        _ = store.createNote(in: child.id, initial: NSAttributedString(string: "Acme\n#proj/alpha"))
        store.flush()
        let folder = try store.createSmartFolder(name: "Mixed", query: "tag:proj/alpha notebook:Work/Clients in:Clients")
        let before = try XCTUnwrap(store.smartFolder(with: folder.id)?.revision)

        _ = await store.renameTag("proj", to: "project")
        var renamed = try XCTUnwrap(store.notebook(with: child.id))
        renamed.name = "Customers"
        store.updateNotebook(renamed)
        let after = try XCTUnwrap(store.smartFolder(with: folder.id))
        XCTAssertEqual(after.query, "tag:project/alpha notebook:Work/Customers in:Customers")
        XCTAssertNotEqual(after.revision, before)

        XCTAssertTrue(store.moveNotebook(child.id, under: nil))
        XCTAssertEqual(store.smartFolder(with: folder.id)?.query, "tag:project/alpha notebook:Customers in:Customers")
        XCTAssertEqual(store.count(for: .smartFolder(folder.id)), 1)
    }

    func testDeletionIsJournaledInTheSmartFolderFileUntilCleared() throws {
        NoteStore.syncJournalEnabled = true
        let store = makeStore()
        let folder = try store.createSmartFolder(name: "Work", query: "tag:work")
        store.selection = .smartFolder(folder.id)
        store.deleteSmartFolder(folder.id)
        XCTAssertEqual(store.selection, .allNotes)
        store.flush()
        XCTAssertFalse(fm.fileExists(atPath: store.syncDeletionsURL.path), "older versions read that file with a closed set of kinds")

        let reopened = makeStore()
        XCTAssertEqual(reopened.syncDeletions()[folder.id]?.kind, .smartFolder)
        reopened.clearSyncDeletion(folder.id)
        XCTAssertNil(makeStore().syncDeletions()[folder.id])
    }

    func testRemoteApplyAndDeletionAreSavedRightAway() throws {
        let store = makeStore()
        let id = UUID()
        try store.applyRemote(SmartFolderRawMetaTests.payload(id, revision: UUID(), name: "Remote", query: "is:pinned"))
        XCTAssertFalse(store.hasUnsavedSmartFolders)
        XCTAssertEqual(makeStore().smartFolder(with: id)?.name, "Remote")
        XCTAssertEqual(store.syncRecords().first { $0.id == id }?.kind, .smartFolder)

        store.applyRemoteDeletion(id, kind: .smartFolder)
        XCTAssertFalse(store.hasUnsavedSmartFolders)
        XCTAssertNil(makeStore().smartFolder(with: id))
        XCTAssertFalse(fm.fileExists(atPath: store.rawMetaFileURL(id, kind: .smartFolders).path))
    }
}
