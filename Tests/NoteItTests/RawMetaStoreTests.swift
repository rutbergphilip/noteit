import AppKit
import XCTest
@testable import NoteIt
import NoteItCore
import NoteItSync

/// foundations Task 3.5: the Mac keeps the last applied remote meta per record so unknown fields survive.
@MainActor
final class RawMetaStoreTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private typealias S = RawMetaSupport

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-rawmeta-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let items = fm.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let url as URL in items { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try? fm.removeItem(at: base)
    }

    private var root: URL { base.appendingPathComponent("lib", isDirectory: true) }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
    }

    private func rawFile(_ store: NoteStore, _ id: UUID, _ kind: RawMetaKind) throws -> RawMeta {
        try LibraryCoding.decoder.decode(RawMeta.self, from: Data(contentsOf: store.rawMetaFileURL(id, kind: kind)))
    }

    func testUnknownFieldSurvivesLocalEdit() throws {
        let store = makeStore()
        let id = UUID()
        try store.applyRemote(S.notePayload(id, revision: UUID(), text: "Remote\nbody", extra: ["futureField": "x"]))
        S.editNote(store, id, "Edited title\nbody")
        let meta = try S.exported(store, id, .note)
        XCTAssertEqual(meta["futureField"] as? String, "x")
        XCTAssertEqual(meta["title"] as? String, "Edited title")
    }

    func testNoteWithoutRawFileExportsSameBytes() throws {
        let store = makeStore()
        let notebook = store.createNotebook(name: "Work", symbol: "tray", colorHex: "#0A84FF")
        let note = store.createNote(in: notebook.id, initial: NSAttributedString(string: "Local\nonly"))
        store.flush()
        let current = try XCTUnwrap(store.note(with: note.id))
        XCTAssertEqual(try store.exportPlan(id: note.id, kind: .note, deviceID: "ME").0.meta, try LibraryCoding.encoder.encode(current))
        let currentNotebook = try XCTUnwrap(store.notebook(with: notebook.id))
        XCTAssertEqual(try store.exportPlan(id: notebook.id, kind: .notebook, deviceID: "ME").0.meta,
                       try LibraryCoding.encoder.encode(currentNotebook))
        let library = try String(contentsOf: store.libraryURL, encoding: .utf8)
        XCTAssertFalse(library.contains("appliedRemoteRevisions"), "a library with nothing applied keeps its shape")
        XCTAssertFalse(fm.fileExists(atPath: store.rawMetaURL.path))
    }

    func testRawMetaKindsDoNotCollide() throws {
        let store = makeStore()
        let id = UUID()
        let noteRevision = UUID(), notebookRevision = UUID()
        try store.applyRemote(S.notePayload(id, revision: noteRevision, text: "Note\nbody", extra: ["noteFuture": 1]))
        try store.applyRemote(S.notebookPayload(id, revision: notebookRevision, name: "Book", extra: ["notebookFuture": 2]))
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), noteRevision)
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notebooks), notebookRevision)
        XCTAssertEqual(try rawFile(store, id, .notes).sourceRevision, noteRevision)
        XCTAssertEqual(try rawFile(store, id, .notebooks).sourceRevision, notebookRevision)

        let noteRevision2 = UUID()
        try store.applyRemote(S.notePayload(id, revision: noteRevision2, text: "Note\nbody 2", extra: ["noteFuture": 1]))
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notebooks), notebookRevision)
        let notebookRevision2 = UUID()
        try store.applyRemote(S.notebookPayload(id, revision: notebookRevision2, name: "Book", extra: ["notebookFuture": 2]))
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), noteRevision2)

        S.editNote(store, id, "Edited note\nbody")
        S.renameNotebook(store, id, "Renamed")
        let note = try S.exported(store, id, .note)
        let notebook = try S.exported(store, id, .notebook)
        XCTAssertEqual(note["noteFuture"] as? Int, 1)
        XCTAssertNil(note["notebookFuture"])
        XCTAssertEqual(notebook["notebookFuture"] as? Int, 2)
        XCTAssertNil(notebook["noteFuture"])
        XCTAssertEqual(notebook["name"] as? String, "Renamed")

        S.purge(store, id)
        XCTAssertNil(store.note(with: id))
        XCTAssertFalse(fm.fileExists(atPath: store.rawMetaFileURL(id, kind: .notes).path))
        XCTAssertTrue(fm.fileExists(atPath: store.rawMetaFileURL(id, kind: .notebooks).path))
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notebooks), notebookRevision2)
    }

    func testUnappliedRawMetaNotMerged() async throws {
        let store = makeStore()
        let adapter = NoteStoreSyncAdapter(store: store, deviceID: "ME")
        let id = UUID()
        let r1 = UUID(), r2 = UUID(), r3 = UUID()
        try await adapter.apply(S.notePayload(id, revision: r1, text: "One\nbody", extra: ["futureField": 1]))
        _ = await adapter.records()

        let r2Payload = try S.notePayload(id, revision: r2, text: "Two\nbody", extra: ["futureField": 2])
        try store.setLastRemoteMeta(RawMeta(sourceRevision: r2, meta: r2Payload.meta), for: id, kind: .notes)
        S.editNote(store, id, "Local\nedit")
        do {
            try await adapter.apply(r2Payload)
            XCTFail("the apply should be refused after a local edit")
        } catch {}
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), r1)
        XCTAssertEqual(try rawFile(store, id, .notes).sourceRevision, r2)
        XCTAssertNil(store.lastRemoteMeta(for: id, kind: .notes))

        S.editNote(store, id, "Local title\nedit")
        let current = try XCTUnwrap(store.note(with: id))
        let exported = try store.exportPlan(id: id, kind: .note, deviceID: "ME").0.meta
        XCTAssertEqual(exported, try LibraryCoding.encoder.encode(current), "exports as if there were no raw file")

        _ = await adapter.records()
        try await adapter.apply(S.notePayload(id, revision: r3, text: "Three\nbody", extra: ["futureField": 3]))
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), r3)
        S.editNote(store, id, "After three\nedit")
        XCTAssertEqual(try S.exported(store, id, .note)["futureField"] as? Int, 3)
    }

    func testRawMetaSurvivesRelaunch() throws {
        let id = UUID(), bookID = UUID()
        let noteRevision = UUID(), notebookRevision = UUID()
        do {
            let store = makeStore()
            try store.applyRemote(S.notebookPayload(bookID, revision: notebookRevision, name: "Book", extra: ["futureField": "book"]))
            try store.applyRemote(S.notePayload(id, revision: noteRevision, text: "Note\nbody", notebookID: bookID,
                                                extra: ["futureField": "note"]))
            store.flush()
        }
        let store = makeStore()
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), noteRevision)
        XCTAssertEqual(store.appliedRemoteRevision(for: bookID, kind: .notebooks), notebookRevision)
        S.editNote(store, id, "Edited\nbody")
        S.renameNotebook(store, bookID, "Renamed")
        XCTAssertEqual(try S.exported(store, id, .note)["futureField"] as? String, "note")
        XCTAssertEqual(try S.exported(store, bookID, .notebook)["futureField"] as? String, "book")
    }

    func testKindFolders() throws {
        let store = makeStore()
        let id = UUID()
        let raws = RawMetaKind.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for kind in RawMetaKind.allCases {
            XCTAssertFalse(kind.rawValue.isEmpty)
            XCTAssertNotNil(kind.rawValue.range(of: "^[a-z-]+$", options: .regularExpression), kind.rawValue)
            try store.setLastRemoteMeta(RawMeta(sourceRevision: UUID(), meta: Data("{}".utf8)), for: id, kind: kind)
            let expected = root.appendingPathComponent("sync-meta-raw/\(kind.rawValue)/\(id.uuidString).json")
            XCTAssertEqual(store.rawMetaFileURL(id, kind: kind).standardizedFileURL, expected.standardizedFileURL)
            XCTAssertTrue(fm.fileExists(atPath: expected.path), kind.rawValue)
        }
    }

    func testRawMetaSurvivesOwnPush() async throws {
        let store = makeStore()
        let adapter = NoteStoreSyncAdapter(store: store, deviceID: "ME")
        let id = UUID(), revision = UUID()
        try await adapter.apply(S.notePayload(id, revision: revision, text: "Remote\nbody", extra: ["futureField": true]))
        S.editNote(store, id, "First\nedit")
        let pushed = try await adapter.export(id, kind: .note)
        XCTAssertNotNil(pushed.body)
        S.editNote(store, id, "Second\nedit")
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), revision)
        let meta = try S.exported(store, id, .note)
        XCTAssertEqual(meta["futureField"] as? Bool, true)
        XCTAssertEqual(meta["title"] as? String, "Second")
    }

    func testRawMetaWriteFailureSkipsApply() throws {
        let store = makeStore()
        let id = UUID()
        let r1 = UUID(), r2 = UUID()
        try store.applyRemote(S.notePayload(id, revision: r1, text: "One\nbody", extra: ["futureField": 1]))
        let folder = store.rawMetaFileURL(id, kind: .notes).deletingLastPathComponent()

        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try store.applyRemote(S.notePayload(id, revision: r2, text: "Two\nbody", extra: ["futureField": 2])))
        XCTAssertEqual(store.note(with: id)?.revision, r1)
        XCTAssertEqual(store.note(with: id)?.title, "One")
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), r1)

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try store.applyRemote(S.notePayload(id, revision: r2, text: "Two\nbody", extra: ["futureField": 2]))
        XCTAssertEqual(store.note(with: id)?.revision, r2)
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), r2)
        XCTAssertEqual(try rawFile(store, id, .notes).sourceRevision, r2)

        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        S.purge(store, id)
        XCTAssertNil(store.note(with: id))
        XCTAssertTrue(fm.fileExists(atPath: store.rawMetaFileURL(id, kind: .notes).path))
        let tombstones = try LibraryCoding.decoder.decode([UUID].self, from: Data(contentsOf: store.tombstonesURL))
        XCTAssertEqual(tombstones, [id], "the ID stays in pendingTrash until the raw file is gone")

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        store.flush()
        XCTAssertFalse(fm.fileExists(atPath: store.rawMetaFileURL(id, kind: .notes).path))
        XCTAssertFalse(fm.fileExists(atPath: store.tombstonesURL.path))
    }
}

/// Shared helpers for the raw meta tests (foundations Task 3.5).
@MainActor
enum RawMetaSupport {
    static func notePayload(_ id: UUID, revision: UUID, text: String, notebookID: UUID? = nil,
                            extra: [String: Any] = [:]) throws -> RecordPayload {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let meta = NoteMeta(id: id, notebookID: notebookID, title: "", preview: "", isPinned: false,
                            createdAt: date, updatedAt: date, tags: [])
        return RecordPayload(id: id, kind: .note, revision: revision, modifiedAt: date, deviceID: "OTHER",
                             meta: try adding(extra, to: LibraryCoding.encoder.encode(meta)),
                             body: try NoteStore.serializeBody(NSAttributedString(string: text)))
    }

    static func notebookPayload(_ id: UUID, revision: UUID, name: String, extra: [String: Any] = [:]) throws -> RecordPayload {
        let notebook = Notebook(id: id, name: name, symbol: "tray", colorHex: "#0A84FF", sortIndex: 0)
        return RecordPayload(id: id, kind: .notebook, revision: revision, modifiedAt: Date(timeIntervalSince1970: 1_767_225_600),
                             deviceID: "OTHER", meta: try adding(extra, to: LibraryCoding.encoder.encode(notebook)))
    }

    static func adding(_ extra: [String: Any], to json: Data) throws -> Data {
        guard !extra.isEmpty else { return json }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        for (key, value) in extra { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func exported(_ store: NoteStore, _ id: UUID, _ kind: RecordKind) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try store.exportPlan(id: id, kind: kind, deviceID: "ME").0.meta)
            as? [String: Any])
    }

    static func editNote(_ store: NoteStore, _ id: UUID, _ text: String) {
        store.updateBody(id, NSAttributedString(string: text))
        store.flush()
    }

    static func renameNotebook(_ store: NoteStore, _ id: UUID, _ name: String) {
        var notebook = store.notebook(with: id)!
        notebook.name = name
        store.updateNotebook(notebook)
        store.flush()
    }

    static func purge(_ store: NoteStore, _ id: UUID) {
        store.moveToRecentlyDeleted([id])
        store.flush()
        store.deleteNow([id])
    }
}
