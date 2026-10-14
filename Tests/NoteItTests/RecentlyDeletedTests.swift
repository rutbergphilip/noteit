import AppKit
import XCTest
@testable import NoteIt
import NoteItSync

@MainActor
final class RecentlyDeletedTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-trash-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        NoteStore.syncJournalEnabled = false
        try? fm.removeItem(at: base)
    }

    private func makeStore(_ name: String = "lib") -> NoteStore {
        NoteStore(location: LibraryLocation(url: base.appendingPathComponent(name, isDirectory: true), seedsFreshLibrary: false))
    }

    @discardableResult
    private func addNote(_ store: NoteStore, _ text: String, in notebook: UUID? = nil) -> UUID {
        let id = store.createNote(in: notebook, initial: NSAttributedString(string: text)).id
        store.flush()
        return id
    }

    private func ids(_ notes: [NoteMeta]) -> Set<UUID> { Set(notes.map(\.id)) }

    // MARK: - Moving and views

    func testMovedNoteIsHiddenFromEveryViewSearchAndTags() throws {
        let store = makeStore()
        let nb = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        let gone = addNote(store, "Quarterly zebra plan\nnotes about #budget", in: nb.id)
        let kept = addNote(store, "Shopping\nmilk", in: nb.id)
        store.togglePin(gone)
        store.notes[store.noteIndex(gone)!].conflictSource = "Other Mac"
        let revision = store.note(with: gone)?.revision

        XCTAssertEqual(store.moveToRecentlyDeleted([gone]), [gone])

        let meta = try XCTUnwrap(store.note(with: gone))
        XCTAssertNotNil(meta.deletedAt)
        XCTAssertNotEqual(meta.revision, revision, "moving to Recently Deleted is a synced metadata change")
        for selection in [SidebarSelection.allNotes, .pinned, .recent, .conflicts, .notebook(nb.id), .tag("budget")] {
            XCTAssertFalse(ids(store.notes(for: selection, search: "")).contains(gone), "\(selection)")
        }
        XCTAssertTrue(store.notes(for: .allNotes, search: "zebra").isEmpty)
        XCTAssertFalse(store.allTags.contains("budget"))
        XCTAssertEqual(store.count(for: .notebook(nb.id)), 1)
        XCTAssertEqual(store.count(for: .pinned), 0)
        XCTAssertEqual(store.count(for: .conflicts), 0)
        XCTAssertEqual(ids(store.activeNotes), [kept])
        XCTAssertEqual(ids(store.notes(for: .recentlyDeleted, search: "")), [gone])
        XCTAssertEqual(ids(store.notes(for: .recentlyDeleted, search: "zebra")), [gone])
        XCTAssertEqual(store.count(for: .recentlyDeleted), 1)
        XCTAssertTrue(store.hasRecentlyDeleted)

        store.flush()
        XCTAssertTrue(fm.fileExists(atPath: store.bodyURL(for: gone).path), "the body stays until the note is removed for good")
        XCTAssertFalse(fm.fileExists(atPath: store.tombstonesURL.path))
    }

    func testRecentlyDeletedListsNewestDeletionFirst() {
        let store = makeStore()
        let a = addNote(store, "A")
        let b = addNote(store, "B")
        let now = Date()
        store.moveToRecentlyDeleted([b], at: now.addingTimeInterval(-60))
        store.moveToRecentlyDeleted([a], at: now)
        XCTAssertEqual(store.notes(for: .recentlyDeleted, search: "").map(\.id), [a, b])
    }

    func testDeletedNoteIsReadOnlyAndCantBePinnedOrMoved() {
        let store = makeStore()
        let id = addNote(store, "Frozen")
        store.moveToRecentlyDeleted([id])
        store.updateBody(id, NSAttributedString(string: "Changed"))
        store.togglePin(id)
        store.moveNote(id, to: UUID())
        XCTAssertEqual(store.plainText(for: id), "Frozen")
        XCTAssertEqual(store.note(with: id)?.isPinned, false)
        XCTAssertNil(store.note(with: id)?.notebookID)
    }

    func testSelectionMovesToNeighbourWhenSelectedNoteIsDeleted() {
        let store = makeStore()
        let older = addNote(store, "Older")
        let newer = addNote(store, "Newer")
        store.selectedNoteID = newer
        store.moveToRecentlyDeleted([newer])
        XCTAssertEqual(store.selectedNoteID, older)
    }

    // MARK: - Undo and recover

    func testUndoRecoversAndRedoDeletesAgain() {
        let store = makeStore()
        let id = addNote(store, "Undo me")
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        store.moveToRecentlyDeleted([id], undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Delete Note")

        undo.undo()
        XCTAssertNil(store.note(with: id)?.deletedAt)
        XCTAssertTrue(ids(store.notes(for: .allNotes, search: "")).contains(id))

        undo.redo()
        XCTAssertNotNil(store.note(with: id)?.deletedAt)
    }

    func testRecoverPutsNoteBackInItsNotebook() {
        let store = makeStore()
        let nb = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookBlue)
        let id = addNote(store, "Back home", in: nb.id)
        store.moveToRecentlyDeleted([id])
        let revision = store.note(with: id)?.revision

        XCTAssertEqual(store.recover([id]), [id])

        XCTAssertNil(store.note(with: id)?.deletedAt)
        XCTAssertEqual(store.note(with: id)?.notebookID, nb.id)
        XCTAssertNotEqual(store.note(with: id)?.revision, revision)
        XCTAssertTrue(ids(store.notes(for: .notebook(nb.id), search: "")).contains(id))
        XCTAssertFalse(store.hasRecentlyDeleted)
    }

    func testDeletingNotebookMovesNotesToRecentlyDeletedAndRecoveryFallsBackToInbox() {
        let store = makeStore()
        let inbox = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: Tokens.Hex.notebookBlue)
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookRed)
        let id = addNote(store, "Orphan", in: work.id)

        store.deleteNotebook(work.id)

        XCTAssertNotNil(store.note(with: id)?.deletedAt)
        XCTAssertEqual(store.note(with: id)?.notebookID, work.id, "deleted notes keep their notebook ID")
        XCTAssertTrue(ids(store.notes(for: .recentlyDeleted, search: "")).contains(id))

        store.recover([id])
        XCTAssertEqual(store.note(with: id)?.notebookID, inbox.id)
        XCTAssertNil(store.note(with: id)?.deletedAt)
    }

    func testRecoveryWithoutNotebookOrInboxLeavesNoNotebook() {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "briefcase", colorHex: Tokens.Hex.notebookRed)
        let id = addNote(store, "Orphan", in: work.id)
        store.moveToRecentlyDeleted([id])
        store.deleteNotebook(work.id)
        store.recover([id])
        XCTAssertNil(store.note(with: id)?.notebookID)
        XCTAssertTrue(ids(store.notes(for: .allNotes, search: "")).contains(id))
    }

    // MARK: - Removing for good

    func testDeleteNowUsesThePermanentDeletePath() {
        NoteStore.syncJournalEnabled = true
        let store = makeStore()
        let id = addNote(store, "Bye")
        store.updateBody(id, NSAttributedString(string: "Bye again"))
        store.flush()
        XCTAssertFalse(store.versions(of: id).isEmpty)

        store.deleteNow([id])
        XCTAssertNotNil(store.note(with: id), "Delete Now only removes notes already in Recently Deleted")

        store.moveToRecentlyDeleted([id])
        store.deleteNow([id])

        XCTAssertNil(store.note(with: id))
        XCTAssertFalse(fm.fileExists(atPath: store.bodyURL(for: id).path))
        let trashed = (try? fm.contentsOfDirectory(atPath: store.trashURL.path)) ?? []
        XCTAssertTrue(trashed.contains { $0.hasPrefix(id.uuidString) }, "the body moves to .trash")
        XCTAssertEqual(store.syncDeletionJournal[id]?.kind, .note)
        XCTAssertFalse(fm.fileExists(atPath: store.history.directory(for: id).path), "history goes with the note")
        XCTAssertFalse(store.hasRecentlyDeleted)
    }

    func testEmptyRecentlyDeletedRemovesOnlyDeletedNotes() {
        let store = makeStore()
        let a = addNote(store, "A")
        let b = addNote(store, "B")
        let kept = addNote(store, "Kept")
        store.moveToRecentlyDeleted([a, b])

        store.emptyRecentlyDeleted()

        XCTAssertEqual(ids(store.notes), [kept])
        XCTAssertFalse(store.hasRecentlyDeleted)
        let reopened = makeStore()
        XCTAssertEqual(ids(reopened.notes), [kept])
    }

    func testDeleteNowRemovesManyNotesInOneBatch() throws {
        NoteStore.syncJournalEnabled = true
        let store = makeStore()
        let gone = (0..<5).map { addNote(store, "Note \($0)") }
        let kept = addNote(store, "Kept")
        for id in gone {
            store.updateBody(id, NSAttributedString(string: "Edited \(id)"))
        }
        store.flush()
        XCTAssertTrue(gone.allSatisfy { fm.fileExists(atPath: store.history.directory(for: $0).path) })
        store.moveToRecentlyDeleted(gone)
        store.selection = .recentlyDeleted
        store.selectedNoteID = gone[2]

        store.deleteNow(gone + [kept])

        XCTAssertEqual(ids(store.notes), [kept], "notes not in Recently Deleted are left alone")
        XCTAssertNil(store.selectedNoteID, "the selection doesn't land on another removed note")
        for id in gone {
            XCTAssertEqual(store.syncDeletionJournal[id]?.kind, .note)
            XCTAssertFalse(fm.fileExists(atPath: store.history.directory(for: id).path))
            XCTAssertFalse(fm.fileExists(atPath: store.bodyURL(for: id).path))
        }
        let trashed = (try? fm.contentsOfDirectory(atPath: store.trashURL.path)) ?? []
        XCTAssertEqual(trashed.count, gone.count)
        XCTAssertFalse(fm.fileExists(atPath: store.tombstonesURL.path), "tombstones clear once the removal is saved")
        let journal = try String(contentsOf: store.syncDeletionsURL, encoding: .utf8)
        XCTAssertTrue(gone.allSatisfy { journal.contains($0.uuidString) })
        XCTAssertEqual(ids(makeStore().notes), [kept])
    }

    func testPurgeWithNothingExpiredLeavesTheLibraryAlone() throws {
        let store = makeStore()
        let id = addNote(store, "Recent")
        store.moveToRecentlyDeleted([id])
        store.flush()
        let saved = try fm.attributesOfItem(atPath: store.libraryURL.path)[.modificationDate] as? Date
        XCTAssertEqual(store.purgeExpiredDeletedNotes(), 0)
        XCTAssertEqual(try fm.attributesOfItem(atPath: store.libraryURL.path)[.modificationDate] as? Date, saved)
        XCTAssertNotNil(store.note(with: id))
    }

    func testPurgeRemovesNotesDeletedMoreThan30DaysAgo() {
        let store = makeStore()
        let old = addNote(store, "Old")
        let recent = addNote(store, "Recent")
        let active = addNote(store, "Active")
        let now = Date()
        store.moveToRecentlyDeleted([old], at: now.addingTimeInterval(-31 * day))
        store.moveToRecentlyDeleted([recent], at: now.addingTimeInterval(-29 * day))

        XCTAssertEqual(store.purgeExpiredDeletedNotes(now: now), 1)
        XCTAssertNil(store.note(with: old))
        XCTAssertNotNil(store.note(with: recent))
        XCTAssertNotNil(store.note(with: active))

        XCTAssertEqual(store.purgeExpiredDeletedNotes(now: now.addingTimeInterval(2 * day)), 1)
        XCTAssertNil(store.note(with: recent))
        XCTAssertNotNil(store.note(with: active))

        XCTAssertEqual(ids(makeStore().notes), [active])
    }

    func testDeletionSummary() {
        let now = Date()
        XCTAssertEqual(NoteStore.deletionSummary(deletedAt: now.addingTimeInterval(-3 * day), now: now),
                       "Deleted 3 days ago. It will be removed in 27 days.")
        XCTAssertEqual(NoteStore.deletionSummary(deletedAt: now.addingTimeInterval(-60), now: now),
                       "Deleted today. It will be removed in 30 days.")
        XCTAssertEqual(NoteStore.deletionSummary(deletedAt: now.addingTimeInterval(-29.5 * day), now: now),
                       "Deleted 29 days ago. It will be removed in 1 day.")
    }

    // MARK: - Persistence and sync

    func testDeletedAtRoundTripsThroughLibraryJSON() throws {
        let store = makeStore()
        let id = addNote(store, "Persisted")
        let deletedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 3 * day)
        store.moveToRecentlyDeleted([id], at: deletedAt)
        store.flush()

        let json = try String(contentsOf: store.libraryURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"deletedAt\""))

        let reopened = makeStore()
        XCTAssertEqual(reopened.note(with: id)?.deletedAt, deletedAt)
        XCTAssertTrue(reopened.notes(for: .allNotes, search: "").isEmpty)
        reopened.recover([id])
        reopened.flush()
        XCTAssertFalse(try String(contentsOf: reopened.libraryURL, encoding: .utf8).contains("\"deletedAt\""))
        XCTAssertNil(makeStore().note(with: id)?.deletedAt)
    }

    func testMetaWithoutDeletedAtDecodesAsNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","preview":"","isPinned":false,
         "createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z","tags":[]}
        """
        let meta = try NoteStore.decoder.decode(NoteMeta.self, from: Data(json.utf8))
        XCTAssertNil(meta.deletedAt)
    }

    func testDeletedAtRoundTripsThroughSyncRecords() throws {
        let a = makeStore("a")
        let b = makeStore("b")
        let id = addNote(a, "Synced note")
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))
        XCTAssertNil(b.note(with: id)?.deletedAt)

        let deletedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        a.moveToRecentlyDeleted([id], at: deletedAt)
        let payload = try a.exportPayload(id: id, kind: .note, deviceID: "A")
        XCTAssertEqual(payload.revision, a.note(with: id)?.revision)
        XCTAssertTrue(String(decoding: payload.meta, as: UTF8.self).contains("deletedAt"))
        try b.applyRemote(payload)

        XCTAssertEqual(b.note(with: id)?.deletedAt, deletedAt)
        XCTAssertEqual(b.syncRevision(of: id, kind: .note), payload.revision)
        XCTAssertTrue(b.notes(for: .allNotes, search: "").isEmpty)
        XCTAssertEqual(ids(b.notes(for: .recentlyDeleted, search: "")), [id])

        a.recover([id])
        try b.applyRemote(a.exportPayload(id: id, kind: .note, deviceID: "A"))
        XCTAssertNil(b.note(with: id)?.deletedAt)
        XCTAssertEqual(ids(b.notes(for: .allNotes, search: "")), [id])
    }

    func testDerivedRevisionIncludesDeletedAt() {
        let store = makeStore()
        let id = addNote(store, "Same")
        store.notes[store.noteIndex(id)!].revision = nil
        let active = store.missingRevisionInputs().first { $0.id == id }?.fields
        store.notes[store.noteIndex(id)!].deletedAt = Date(timeIntervalSince1970: 1_000)
        let deleted = store.missingRevisionInputs().first { $0.id == id }?.fields
        XCTAssertEqual(active?.count, 4, "notes never deleted derive the same revision as before")
        XCTAssertNotNil(deleted)
        XCTAssertNotEqual(active, deleted)
    }
}
