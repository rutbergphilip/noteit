import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItSync

/// foundations Task 4.1: `persistNow(_:)` makes one note durable without a flush.
@MainActor
final class PersistNowTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-persist-now-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    func testPersistNowWritesBodyAndLibrary() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Captured\nfrom elsewhere")).id
        try store.persistNow(id)
        XCTAssertFalse(store.isBodyDirty(id))
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.note(with: id)?.title, "Captured")
        XCTAssertEqual(relaunched.body(for: id).string, "Captured\nfrom elsewhere")

        let remoteID = UUID()
        let extras = ContainerExtras(frontMatter: "title: Remote", extra: ["future": .number("1.50")])
        var prepared = try NoteStore.prepareRemoteNote(
            RawMetaSupport.notePayload(remoteID, revision: UUID(), text: "Remote\nbody"), storage: store.bodyStorage)
        prepared.extras = extras
        prepared.bodyIsRTFD = false
        try store.applyPreparedRemoteNote(prepared)
        store.updateBody(remoteID, NSAttributedString(string: "Remote\nedited"))
        try store.persistNow(remoteID)
        let again = makeStore()
        XCTAssertEqual(again.body(for: remoteID).string, "Remote\nedited")
        XCTAssertEqual(again.bodyExtras[remoteID], extras)
        let sidecar = try BodyExtrasSidecar.decode(Data(contentsOf: store.bodyExtrasFileURL(remoteID)))
        XCTAssertNil(sidecar.previous)
    }

    func testPersistNowSavesMetadataAnEarlierLibrarySaveHeldBack() throws {
        let store = makeStore()
        let a = store.createNote(in: nil, initial: NSAttributedString(string: "Old title\nbody")).id
        let b = store.createNote(in: nil, initial: NSAttributedString(string: "Other\nbody")).id
        try store.persistNow(a)
        try store.persistNow(b)
        store.updateBody(a, NSAttributedString(string: "New title\nbody"))
        try store.persistNow(b)
        try store.persistNow(a)
        XCTAssertEqual(makeStore().note(with: a)?.title, "New title")
    }

    func testPersistNowCommitsStagedSnapshot() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "First")).id
        store.flush()
        store.stageEditorCommit(id, NSAttributedString(string: "Staged\nsnapshot"))
        try store.persistNow(id)
        XCTAssertEqual(makeStore().body(for: id).string, "Staged\nsnapshot")
    }

    func testPersistNowBodyFailureThrows() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Saved")).id
        store.flush()
        let library = try Data(contentsOf: store.libraryURL)
        try fm.removeItem(at: store.notesURL)
        try Data("not a folder".utf8).write(to: store.notesURL)

        store.updateBody(id, NSAttributedString(string: "Saved\nthen edited"))
        XCTAssertThrowsError(try store.persistNow(id)) { XCTAssertEqual($0 as? PersistNowError, .bodyNotSaved) }
        XCTAssertTrue(store.isBodyDirty(id))
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), library)
    }

    func testPersistNowLibraryFailureThrows() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Saved")).id
        store.flush()
        try fm.removeItem(at: store.libraryURL)
        try fm.createDirectory(at: store.libraryURL, withIntermediateDirectories: false)

        store.updateBody(id, NSAttributedString(string: "Body\nsaved first"))
        XCTAssertThrowsError(try store.persistNow(id)) { XCTAssertEqual($0 as? PersistNowError, .libraryNotSaved) }
        XCTAssertFalse(store.isBodyDirty(id))
        XCTAssertEqual(try RTFDBodyStorage.readBody(at: store.bodyURL(for: id)).string, "Body\nsaved first")
    }

    func testPersistNowEdgeCases() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.persistNow(UUID())) { XCTAssertEqual($0 as? PersistNowError, .noteMissing) }

        let clean = store.createNote(in: nil, initial: NSAttributedString(string: "Clean")).id
        let other = store.createNote(in: nil, initial: NSAttributedString(string: "Other")).id
        store.flush()
        let bodyDate = try modificationDate(store.bodyURL(for: clean))
        let libraryDate = try modificationDate(store.libraryURL)
        try store.persistNow(clean)
        XCTAssertEqual(try modificationDate(store.bodyURL(for: clean)), bodyDate)
        XCTAssertEqual(try modificationDate(store.libraryURL), libraryDate)

        store.updateBody(other, NSAttributedString(string: "Other\nedited"))
        store.updateBody(clean, NSAttributedString(string: "Clean\nedited"))
        try store.persistNow(clean)
        XCTAssertTrue(store.isBodyDirty(other), "other notes are left to the scheduled flush")
        XCTAssertEqual(try RTFDBodyStorage.readBody(at: store.bodyURL(for: other)).string, "Other")

        // A sidecar that can't be read blocks writes to its note.
        store.setBodyExtras(ContainerExtras(frontMatter: "x: 1"), for: clean)
        store.updateBody(clean, NSAttributedString(string: "Clean\nwith extras"))
        try store.persistNow(clean)
        try Data("{".utf8).write(to: store.bodyExtrasFileURL(clean))
        let blocked = makeStore()
        _ = blocked.body(for: clean)
        XCTAssertTrue(blocked.isBodyWriteBlocked(clean))
        let package = try RTFDBodyStorage.packageDigest(at: blocked.bodyURL(for: clean))
        blocked.updateBody(clean, NSAttributedString(string: "Clean\nblocked edit"))
        XCTAssertThrowsError(try blocked.persistNow(clean)) { XCTAssertEqual($0 as? PersistNowError, .writeBlocked) }
        XCTAssertEqual(try RTFDBodyStorage.packageDigest(at: blocked.bodyURL(for: clean)), package)
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }
}
