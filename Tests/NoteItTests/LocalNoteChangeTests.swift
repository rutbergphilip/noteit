import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItSync

/// foundations Task 4.5: `localNoteChange` is posted for local changes only (program §7).
@MainActor
final class LocalNoteChangeTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private typealias S = RawMetaSupport
    private var posted: [(UUID, LocalNoteChangeKind)] = []
    private var token: NSObjectProtocol?

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-localchange-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let token { NotificationCenter.default.removeObserver(token) }
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        token = NotificationCenter.default.addObserver(forName: .localNoteChange, object: store, queue: nil) { [weak self] note in
            guard let id = note.userInfo?["noteID"] as? UUID, let kind = note.userInfo?["kind"] as? LocalNoteChangeKind
            else { return XCTFail("malformed userInfo") }
            MainActor.assumeIsolated { self?.posted.append((id, kind)) }
        }
        return store
    }

    private func kinds(_ id: UUID) -> [LocalNoteChangeKind] {
        posted.filter { $0.0 == id }.map(\.1)
    }

    func testEdited() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Body")).id
        store.flush()
        posted = []

        try store.editBody(id, actionName: "Edit") { $0.append(NSAttributedString(string: " closed")) }
        XCTAssertEqual(kinds(id), [.edited])

        posted = []
        store.updateBody(id, NSAttributedString(string: "Updated"))
        XCTAssertEqual(kinds(id), [.edited])

        posted = []
        try store.editBody(id, actionName: "Nothing") { _ in }
        store.updateBody(id, NSAttributedString(string: "Updated"))
        XCTAssertTrue(posted.isEmpty, "an unchanged edit posts nothing")

        try store.applyRemote(S.notePayload(id, revision: UUID(), text: "Remote"))
        XCTAssertEqual(store.body(for: id).string, "Remote")
        XCTAssertTrue(posted.isEmpty, "a sync apply posts nothing")
    }

    func testCreated() throws {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "New")).id
        XCTAssertEqual(posted.map(\.0), [id])
        XCTAssertEqual(kinds(id), [.created])

        posted = []
        let remote = UUID()
        try store.applyRemote(S.notePayload(remote, revision: UUID(), text: "Remote"))
        XCTAssertNotNil(store.note(with: remote))
        XCTAssertTrue(posted.isEmpty)

        store.flush()
        let before = Set(store.notes.map(\.id))
        try store.importConflictCopy(S.notePayload(remote, revision: UUID(), text: "Conflict"), fromDevice: "Other Mac")
        XCTAssertEqual(Set(store.notes.map(\.id)).subtracting(before).count, 1, "the conflict copy is created")
        XCTAssertTrue(posted.isEmpty, "a conflict copy from sync posts nothing")
    }

    func testDeleted() throws {
        let store = makeStore()
        let a = store.createNote(in: nil, initial: NSAttributedString(string: "A")).id
        let b = store.createNote(in: nil, initial: NSAttributedString(string: "B")).id
        let c = store.createNote(in: nil, initial: NSAttributedString(string: "C")).id
        store.flush()
        posted = []

        store.moveToRecentlyDeleted([a, b])
        XCTAssertEqual(kinds(a), [.deleted])
        XCTAssertEqual(kinds(b), [.deleted])

        posted = []
        store.applyRemoteDeletion(c, kind: .note)
        XCTAssertNil(store.note(with: c))
        XCTAssertTrue(posted.isEmpty, "a remote removal posts nothing")
    }
}
