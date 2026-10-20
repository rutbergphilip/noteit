import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItSync

@MainActor
final class RecordingDerivedIndex: DerivedIndex {
    enum Call: Equatable {
        case changed(UUID, String)
        case removed(UUID)
        case metadata(UUID)
        case rebuild([UUID], [UUID: String])
        case flush
    }

    let indexID: String
    private(set) var calls: [Call] = []
    var rebuilt: XCTestExpectation?

    init(_ indexID: String = "recording") {
        self.indexID = indexID
    }

    func noteChanged(_ note: NoteMeta, body: NSAttributedString) { calls.append(.changed(note.id, body.string)) }
    func noteRemoved(_ noteID: UUID) { calls.append(.removed(noteID)) }
    func metadataChanged(_ note: NoteMeta) { calls.append(.metadata(note.id)) }
    func flush() { calls.append(.flush) }

    func rebuild(notes: [NoteMeta], body: @escaping (UUID) -> NSAttributedString?) async {
        let ids = notes.map(\.id)
        let bodies = await Task.detached {
            var result: [UUID: String] = [:]
            for id in ids { if let text = body(id) { result[id] = text.string } }
            return result
        }.value
        calls.append(.rebuild(ids, bodies))
        rebuilt?.fulfill()
    }

    /// Every call except flush, which every save sends.
    var changes: [Call] { calls.filter { $0 != .flush } }

    func reset() { calls = [] }
}

/// foundations Task 4.4: the derived-index registry and its hooks (program §7).
@MainActor
final class DerivedIndexRegistryTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private typealias S = RawMetaSupport

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-derived-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> (NoteStore, RecordingDerivedIndex) {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        let index = RecordingDerivedIndex()
        store.registerDerivedIndex(index)
        return (store, index)
    }

    private func lock(_ store: NoteStore, _ id: UUID) {
        let index = store.noteIndex(id)!
        store.notes[index].lock = NoteLock(keyID: "k1", sealedID: UUID())
    }

    func testCreateEditAndRemoteApplySendNoteChanged() throws {
        let (store, index) = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Created")).id
        XCTAssertEqual(index.changes, [.changed(id, "Created")])

        index.reset()
        store.updateBody(id, NSAttributedString(string: "Edited"))
        XCTAssertEqual(index.changes, [.changed(id, "Edited")])

        index.reset()
        let remote = UUID()
        try store.applyRemote(S.notePayload(remote, revision: UUID(), text: "Remote"))
        XCTAssertEqual(index.changes, [.changed(remote, "Remote")])
    }

    func testMetadataChangesSendOnlyMetadataChanged() throws {
        let (store, index) = makeStore()
        let book = store.createNotebook(name: "Book", symbol: "tray", colorHex: "#0A84FF")
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Note")).id
        store.flush()

        index.reset()
        store.togglePin(id)
        XCTAssertEqual(index.changes, [.metadata(id)])

        index.reset()
        store.moveNote(id, to: book.id)
        XCTAssertEqual(index.changes, [.metadata(id)])

        index.reset()
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        _ = store.moveToRecentlyDeleted([id], undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(index.changes, [.metadata(id)])

        index.reset()
        undo.undo()
        XCTAssertEqual(index.changes, [.metadata(id)], "undo recovers the note")

        index.reset()
        _ = store.moveToRecentlyDeleted([id])
        _ = store.recover([id])
        XCTAssertEqual(index.changes, [.metadata(id), .metadata(id)])
    }

    func testPermanentRemovalsSendNoteRemoved() throws {
        let (store, index) = makeStore()
        let deleted = store.createNote(in: nil, initial: NSAttributedString(string: "Delete now")).id
        let expired = store.createNote(in: nil, initial: NSAttributedString(string: "Expired")).id
        let remote = store.createNote(in: nil, initial: NSAttributedString(string: "Remote")).id
        _ = store.moveToRecentlyDeleted([deleted])
        _ = store.moveToRecentlyDeleted([expired], at: Date(timeIntervalSinceNow: -40 * 24 * 60 * 60))
        store.flush()

        index.reset()
        store.deleteNow([deleted])
        XCTAssertEqual(index.changes, [.removed(deleted)])

        index.reset()
        _ = store.purgeExpiredDeletedNotes()
        XCTAssertEqual(index.changes, [.removed(expired)])

        index.reset()
        store.applyRemoteDeletion(remote, kind: .note)
        XCTAssertEqual(index.changes, [.removed(remote)])
    }

    func testFlushAndRebuild() throws {
        let (store, index) = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Body")).id
        let locked = store.createNote(in: nil, initial: NSAttributedString(string: "Secret")).id
        lock(store, locked)
        index.reset()
        store.flush()
        XCTAssertEqual(index.calls, [.flush])

        index.reset()
        let rebuilt = expectation(description: "rebuild")
        index.rebuilt = rebuilt
        store.scheduleIndexRebuild()
        wait(for: [rebuilt], timeout: 5)
        XCTAssertEqual(index.calls, [.rebuild([id, locked], [id: "Body"])], "a locked note's body is nil")
    }

    func testLockedNoteGetsNoteRemovedOnly() throws {
        let (store, index) = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Secret")).id
        store.flush()
        lock(store, id)

        index.reset()
        store.updateBody(id, NSAttributedString(string: "Still secret"))
        XCTAssertEqual(index.changes, [.removed(id)])

        index.reset()
        store.refreshDerivedIndexes(for: id)
        XCTAssertEqual(index.changes, [.removed(id)])

        index.reset()
        store.notes[store.noteIndex(id)!].lock = nil
        store.refreshDerivedIndexes(for: id)
        XCTAssertEqual(index.changes, [.changed(id, "Still secret")])

        index.reset()
        store.togglePin(id)
        lock(store, id)
        store.togglePin(id)
        XCTAssertEqual(index.changes, [.metadata(id), .metadata(id)], "metadataChanged is sent for locked notes too")
    }

    func testRemoteApplyOfLockedNoteSendsNoteRemoved() throws {
        let (store, index) = makeStore()
        let id = UUID()
        let payload = try S.notePayload(id, revision: UUID(), text: "Sealed",
                                        extra: ["lock": ["keyID": "k1", "sealedID": UUID().uuidString]])
        try store.applyRemote(payload)
        XCTAssertTrue(store.note(with: id)?.isLocked == true)
        XCTAssertEqual(index.changes, [.removed(id)])
    }

    func testDuplicateIndexIDCannotRegister() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.canRegisterDerivedIndex("recording"))
        XCTAssertTrue(store.canRegisterDerivedIndex("other"))
        store.registerDerivedIndex(RecordingDerivedIndex("other"))
        XCTAssertFalse(store.canRegisterDerivedIndex("other"))
        XCTAssertEqual(store.derivedIndexes.map(\.indexID), ["recording", "other"])
    }
}
