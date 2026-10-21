import Foundation
import NoteItCore
import NoteItSync
import XCTest
@testable import NoteIt

/// Foundations' raw-meta lifecycle tests for the smartFolders kind.
@MainActor
final class SmartFolderRawMetaTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-sfraw-\(UUID().uuidString)", isDirectory: true)
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

    static func payload(_ id: UUID, revision: UUID, name: String, query: String = "tag:work",
                        extra: [String: Any] = [:]) throws -> RecordPayload {
        let folder = SmartFolder(id: id, name: name, query: query, sortIndex: 0)
        return RecordPayload(id: id, kind: .smartFolder, revision: revision, modifiedAt: Date(timeIntervalSince1970: 1_767_225_600),
                             deviceID: "OTHER", meta: try RawMetaSupport.adding(extra, to: LibraryCoding.encoder.encode(folder)))
    }

    private func rename(_ store: NoteStore, _ id: UUID, _ name: String) throws {
        let folder = try XCTUnwrap(store.smartFolder(with: id))
        try store.updateSmartFolder(id, name: name, query: folder.query, symbol: folder.symbol)
        store.flush()
    }

    private func exported(_ store: NoteStore, _ id: UUID) throws -> [String: Any] {
        try RawMetaSupport.exported(store, id, .smartFolder)
    }

    func testUnknownKeySurvivesLocalEdit() throws {
        let store = makeStore()
        let id = UUID()
        try store.applyRemote(Self.payload(id, revision: UUID(), name: "Work", extra: ["futureField": 1]))
        try rename(store, id, "Renamed")
        let meta = try exported(store, id)
        XCTAssertEqual(meta["futureField"] as? Int, 1)
        XCTAssertEqual(meta["name"] as? String, "Renamed")
    }

    func testUnappliedRawMetaNotMerged() throws {
        let store = makeStore()
        let id = UUID()
        try store.applyRemote(Self.payload(id, revision: UUID(), name: "Work", extra: ["futureField": 1]))
        // R2's raw copy is written, then its apply fails: the applied revision stays R1's.
        let r2 = UUID()
        try store.setLastRemoteMeta(RawMeta(sourceRevision: r2, meta: Data(#"{"futureField":2}"#.utf8)), for: id, kind: .smartFolders)
        try rename(store, id, "Local")
        let meta = try exported(store, id)
        XCTAssertNil(meta["futureField"])

        let current = try XCTUnwrap(store.smartFolder(with: id))
        XCTAssertEqual(try store.exportPlan(id: id, kind: .smartFolder, deviceID: "ME").0.meta,
                       try LibraryCoding.encoder.encode(current))

        try store.applyRemote(Self.payload(id, revision: UUID(), name: "Work", extra: ["futureField": 3]))
        try rename(store, id, "Again")
        XCTAssertEqual(try exported(store, id)["futureField"] as? Int, 3)
    }

    func testDeletionWaitsForDurableSave() throws {
        let store = makeStore()
        let id = UUID()
        try store.applyRemote(Self.payload(id, revision: UUID(), name: "Work", extra: ["futureField": 1]))
        let raw = store.rawMetaFileURL(id, kind: .smartFolders)
        XCTAssertTrue(fm.fileExists(atPath: raw.path))

        try fm.removeItem(at: store.smartFoldersURL)
        try fm.createDirectory(at: store.smartFoldersURL, withIntermediateDirectories: false)
        store.deleteSmartFolder(id)
        store.flush()
        XCTAssertTrue(store.hasUnsavedSmartFolders)
        XCTAssertTrue(fm.fileExists(atPath: raw.path))

        try fm.removeItem(at: store.smartFoldersURL)
        let folder = raw.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        store.flush()
        XCTAssertFalse(store.hasUnsavedSmartFolders)
        XCTAssertTrue(fm.fileExists(atPath: raw.path))
        XCTAssertEqual(store.rawMetaDeletionQueue[.smartFolders], [id])

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        store.flush()
        XCTAssertFalse(fm.fileExists(atPath: raw.path))
        XCTAssertNil(store.rawMetaDeletionQueue[.smartFolders])
    }

    func testRawMetaSurvivesRelaunch() throws {
        let id = UUID(), revision = UUID()
        do {
            let store = makeStore()
            try store.applyRemote(Self.payload(id, revision: revision, name: "Work", extra: ["futureField": "keep"]))
            store.flush()
        }
        let store = makeStore()
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .smartFolders), revision)
        try rename(store, id, "Renamed")
        XCTAssertEqual(try exported(store, id)["futureField"] as? String, "keep")
    }

    func testSameUUIDAsNoteKeepsSeparateFiles() throws {
        let store = makeStore()
        let id = UUID(), noteRevision = UUID(), folderRevision = UUID()
        try store.applyRemote(RawMetaSupport.notePayload(id, revision: noteRevision, text: "Note\nbody", extra: ["n": 1]))
        try store.applyRemote(Self.payload(id, revision: folderRevision, name: "Folder", extra: ["f": 2]))
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .notes), noteRevision)
        XCTAssertEqual(store.appliedRemoteRevision(for: id, kind: .smartFolders), folderRevision)
        XCTAssertNotEqual(store.rawMetaFileURL(id, kind: .notes), store.rawMetaFileURL(id, kind: .smartFolders))
        XCTAssertEqual(try exported(store, id)["f"] as? Int, 2)
        XCTAssertNil(try exported(store, id)["n"])
    }

    /// NoteIt 0.2 decodes pending-deletions.json as a whole with only notes and notebooks.
    func testQueuedSmartFolderDeletionStaysOutOfTheLegacyQueueFile() throws {
        let store = makeStore()
        let folder = UUID(), notebook = UUID()
        store.queueRawMetaDeletion(folder, kind: .smartFolders)
        store.queueRawMetaDeletion(notebook, kind: .notebooks)
        let legacy = try Data(contentsOf: store.rawMetaURL.appendingPathComponent("pending-deletions.json"))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [[String: String]])
        XCTAssertEqual(entries.map { $0["kind"] }, ["notebooks"])
        let newer = try Data(contentsOf: store.rawMetaURL.appendingPathComponent("pending-deletions-2.json"))
        let queued = try XCTUnwrap(JSONSerialization.jsonObject(with: newer) as? [[String: String]])
        XCTAssertEqual(queued, [["kind": "smart-folders", "id": folder.uuidString]])
    }
}
