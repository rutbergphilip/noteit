import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItSync

/// foundations Tasks 3.5 and 4.1: per-record files in the data folder go only after the removing library save lands.
@MainActor
final class PurgeAuxFilesTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private typealias S = RawMetaSupport

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-purge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private var root: URL { base.appendingPathComponent("lib", isDirectory: true) }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func trashItems(_ store: NoteStore) -> [String] {
        (try? fm.contentsOfDirectory(atPath: store.trashURL.path)) ?? []
    }

    /// Replaces library.json with a directory so the next library save fails; returns the saved bytes.
    private func breakLibrary(_ store: NoteStore) throws -> Data {
        let saved = try Data(contentsOf: store.libraryURL)
        try fm.removeItem(at: store.libraryURL)
        try fm.createDirectory(at: store.libraryURL, withIntermediateDirectories: false)
        return saved
    }

    private func restoreLibrary(_ store: NoteStore, _ saved: Data?) throws {
        try fm.removeItem(at: store.libraryURL)
        if let saved { try saved.write(to: store.libraryURL) }
    }

    private func libraryLists(_ store: NoteStore, _ id: UUID) throws -> Bool {
        let library = try LibraryCoding.decode(Data(contentsOf: store.libraryURL))
        return library.notes.contains { $0.id == id } || library.notebooks.contains { $0.id == id }
    }

    /// Sync apply whose incoming body carries `extras` (Task 4.1).
    private func apply(_ store: NoteStore, _ payload: RecordPayload, extras: ContainerExtras) throws {
        var prepared = try NoteStore.prepareRemoteNote(payload, storage: store.bodyStorage)
        prepared.extras = extras
        try store.applyPreparedRemoteNote(prepared)
    }

    private let frontMatter = ContainerExtras(frontMatter: "title: Remote")

    func testFailedLibrarySaveKeepsAuxFiles() throws {
        let id = UUID()
        let store = makeStore()
        try apply(store, S.notePayload(id, revision: UUID(), text: "Remote\nbody", extra: ["futureField": "kept"]),
                  extras: frontMatter)
        let version = try XCTUnwrap(store.history.record(NSAttributedString(string: "Older"), extras: frontMatter, of: id))
        let history = store.history.directory(for: id)
        let versionExtras = VersionHistory.extrasURL(of: version.url)
        store.moveToRecentlyDeleted([id])
        store.flush()
        let raw = store.rawMetaFileURL(id, kind: .notes)
        let body = store.bodyURL(for: id)
        let sidecar = store.bodyExtrasFileURL(id)
        XCTAssertTrue(fm.fileExists(atPath: raw.path))
        XCTAssertTrue(fm.fileExists(atPath: sidecar.path))
        XCTAssertTrue(fm.fileExists(atPath: versionExtras.path))

        let saved = try breakLibrary(store)
        store.deleteNow([id])
        store.flush()
        XCTAssertTrue(store.hasUnsavedLibrary)
        XCTAssertNil(store.note(with: id))
        XCTAssertTrue(fm.fileExists(atPath: raw.path))
        XCTAssertTrue(fm.fileExists(atPath: body.path))
        XCTAssertTrue(fm.fileExists(atPath: sidecar.path))
        XCTAssertTrue(fm.fileExists(atPath: version.url.path), "Version History stays after a failed save")
        XCTAssertTrue(fm.fileExists(atPath: versionExtras.path))
        store.purgeExpiredDeletedNotes()
        XCTAssertTrue(fm.fileExists(atPath: versionExtras.path), "pruning keeps a purge's history until it is saved")
        XCTAssertTrue(trashItems(store).isEmpty)

        // The tombstone was written before the failed save, so a relaunch finishes the deletion; the files go
        // only once that store's save no longer lists the note.
        try restoreLibrary(store, saved)
        let snapshot = try snapshotRoot()
        let relaunched = makeStore()
        XCTAssertNil(relaunched.note(with: id))
        XCTAssertFalse(try libraryLists(relaunched, id))
        XCTAssertFalse(fm.fileExists(atPath: raw.path))
        XCTAssertFalse(fm.fileExists(atPath: body.path))
        XCTAssertFalse(fm.fileExists(atPath: sidecar.path))
        XCTAssertFalse(fm.fileExists(atPath: history.path))
        XCTAssertEqual(trashItems(relaunched).count, 1)

        // Had the tombstone not landed either, the note comes back with its raw meta, which still merges.
        try restoreRoot(snapshot)
        try fm.removeItem(at: root.appendingPathComponent("tombstones.json"))
        let recovered = makeStore()
        XCTAssertNotNil(recovered.note(with: id))
        _ = recovered.body(for: id)
        XCTAssertEqual(recovered.bodyExtras[id], frontMatter)
        S.editNote(recovered, id, "Edited\nbody")
        XCTAssertEqual(try S.exported(recovered, id, .note)["futureField"] as? String, "kept")
    }

    func testAuxFilesRemovedAfterDurableDelete() throws {
        let id = UUID()
        let store = makeStore()
        try apply(store, S.notePayload(id, revision: UUID(), text: "Remote\nbody", extra: ["futureField": 1]),
                  extras: frontMatter)
        let raw = store.rawMetaFileURL(id, kind: .notes)
        let sidecar = store.bodyExtrasFileURL(id)
        XCTAssertTrue(fm.fileExists(atPath: raw.path))
        store.moveToRecentlyDeleted([id])
        store.flush()
        XCTAssertTrue(fm.fileExists(atPath: sidecar.path), "the sidecar stays until the delete's flush")
        let version = try XCTUnwrap(store.history.record(NSAttributedString(string: "Older"), extras: frontMatter, of: id))
        XCTAssertTrue(fm.fileExists(atPath: VersionHistory.extrasURL(of: version.url).path))
        store.deleteNow([id])
        XCTAssertFalse(fm.fileExists(atPath: sidecar.path))
        XCTAssertFalse(fm.fileExists(atPath: store.history.directory(for: id).path), "Version History goes with the body")
        XCTAssertFalse(try libraryLists(store, id))
        XCTAssertFalse(fm.fileExists(atPath: store.bodyURL(for: id).path))
        XCTAssertEqual(trashItems(store).count, 1)
        XCTAssertFalse(fm.fileExists(atPath: raw.path))
        XCTAssertNil(store.appliedRemoteRevision(for: id, kind: .notes))

        let bookID = UUID()
        try store.applyRemote(S.notebookPayload(bookID, revision: UUID(), name: "Book", extra: ["futureField": 1]))
        let bookRaw = store.rawMetaFileURL(bookID, kind: .notebooks)
        XCTAssertTrue(fm.fileExists(atPath: bookRaw.path))
        _ = try breakLibrary(store)
        store.deleteNotebook(bookID)
        store.flush()
        XCTAssertTrue(store.hasUnsavedLibrary)
        XCTAssertTrue(fm.fileExists(atPath: bookRaw.path), "a failed save keeps the file")
        XCTAssertTrue(store.isDurablyListed(bookID, kind: .notebooks))

        try restoreLibrary(store, nil)
        store.flush()
        XCTAssertFalse(store.hasUnsavedLibrary)
        XCTAssertFalse(try libraryLists(store, bookID))
        XCTAssertFalse(fm.fileExists(atPath: bookRaw.path))
        XCTAssertFalse(fm.fileExists(atPath: store.rawMetaURL.appendingPathComponent("pending-deletions.json").path))
        XCTAssertNil(store.appliedRemoteRevision(for: bookID, kind: .notebooks))
    }

    func testRemoteNotebookDeletionQueuedUntilSaved() throws {
        let bookID = UUID()
        let store = makeStore()
        try store.applyRemote(S.notebookPayload(bookID, revision: UUID(), name: "Book", extra: ["futureField": 1]))
        let bookRaw = store.rawMetaFileURL(bookID, kind: .notebooks)
        _ = try breakLibrary(store)
        store.applyRemoteDeletion(bookID, kind: .notebook)
        XCTAssertTrue(fm.fileExists(atPath: bookRaw.path))
        // The queue is persisted, so a relaunch after the library is fixed still deletes the file.
        try restoreLibrary(store, nil)
        let relaunched = makeStore()
        XCTAssertNil(relaunched.notebook(with: bookID))
        XCTAssertFalse(fm.fileExists(atPath: bookRaw.path))
    }

    // MARK: Root snapshots

    private func snapshotRoot() throws -> URL {
        let copy = base.appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: root, to: copy)
        return copy
    }

    private func restoreRoot(_ snapshot: URL) throws {
        try fm.removeItem(at: root)
        try fm.copyItem(at: snapshot, to: root)
    }
}
