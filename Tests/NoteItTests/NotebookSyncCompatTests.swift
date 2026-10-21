import AppKit
import NoteItCore
import NoteItSync
import XCTest
@testable import NoteIt

/// Nested notebooks against writers that don't know `parent`.
@MainActor
final class NotebookSyncCompatTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-nbcompat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore(_ name: String = "a") -> NoteStore {
        NoteStore(location: LibraryLocation(url: root.appendingPathComponent(name), seedsFreshLibrary: false))
    }

    /// The notebook struct as NoteIt 0.2 shipped it.
    private struct LegacyNotebook: Codable {
        var id: UUID
        var name: String
        var symbol: String
        var colorHex: String
        var sortIndex: Int
        var revision: UUID?
        var modifiedAt: Date?
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func nested(_ store: NoteStore) -> (parent: Notebook, child: Notebook) {
        let parent = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let child = store.createNotebook(name: "Clients", symbol: "folder", colorHex: "#0A84FF", parentID: parent.id)
        return (parent, child)
    }

    func testExportWritesParentKeyEvenAtTopLevel() throws {
        let store = makeStore()
        let (parent, child) = nested(store)
        let top = try store.exportPayload(id: parent.id, kind: .notebook, deviceID: "a")
        XCTAssertTrue(json(top.meta).keys.contains("parent"))
        XCTAssertTrue(json(top.meta)["parent"] is NSNull)
        let inner = try store.exportPayload(id: child.id, kind: .notebook, deviceID: "a")
        XCTAssertEqual(json(inner.meta)["parent"] as? String, parent.id.uuidString)
    }

    func testRemoteWithoutParentKeepsLocalParentAndRepairs() throws {
        let store = makeStore()
        let (parent, child) = nested(store)
        let exported = try store.exportPayload(id: child.id, kind: .notebook, deviceID: "a")
        var legacy = try NoteStore.decoder.decode(LegacyNotebook.self, from: exported.meta)
        legacy.name = "Customers"
        let revision = UUID()
        let payload = RecordPayload(id: child.id, kind: .notebook, revision: revision, modifiedAt: Date(),
                                    deviceID: "legacy", meta: try NoteStore.encoder.encode(legacy))
        try store.applyRemote(payload)
        let applied = try XCTUnwrap(store.notebook(with: child.id))
        XCTAssertEqual(applied.name, "Customers")
        XCTAssertEqual(applied.parent, parent.id)
        XCTAssertNotEqual(applied.revision, revision, "a repair gets a new revision so it's pushed again")
        let repaired = try store.exportPayload(id: child.id, kind: .notebook, deviceID: "a")
        XCTAssertEqual(json(repaired.meta)["parent"] as? String, parent.id.uuidString)
        XCTAssertEqual(json(repaired.meta)["name"] as? String, "Customers")
    }

    func testRemoteWithoutParentForTopLevelDoesNotRepair() throws {
        let store = makeStore()
        let top = store.createNotebook(name: "Top", symbol: "folder", colorHex: "#0A84FF")
        let legacy = LegacyNotebook(id: top.id, name: "Top 2", symbol: "folder", colorHex: "#0A84FF", sortIndex: 0)
        let revision = UUID()
        try store.applyRemote(RecordPayload(id: top.id, kind: .notebook, revision: revision, modifiedAt: Date(),
                                            deviceID: "legacy", meta: try NoteStore.encoder.encode(legacy)))
        XCTAssertEqual(store.notebook(with: top.id)?.revision, revision)
    }

    func testRemoteWithEmptyParentMovesToTop() throws {
        let store = makeStore()
        let (_, child) = nested(store)
        var moved = try XCTUnwrap(store.notebook(with: child.id))
        moved.parent = nil
        let revision = UUID()
        try store.applyRemote(RecordPayload(id: child.id, kind: .notebook, revision: revision, modifiedAt: Date(),
                                            deviceID: "b", meta: try NoteStore.encoder.encode(moved)))
        XCTAssertNil(store.notebook(with: child.id)?.parent)
        XCTAssertEqual(store.notebook(with: child.id)?.revision, revision)
    }

    func testOldDecoderReencodesWithoutParent() throws {
        let store = makeStore()
        let (_, child) = nested(store)
        let exported = try store.exportPayload(id: child.id, kind: .notebook, deviceID: "a")
        let legacy = try NoteStore.decoder.decode(LegacyNotebook.self, from: exported.meta)
        XCTAssertEqual(legacy.name, "Clients")
        XCTAssertFalse(Notebook.recordHasParentKey(try NoteStore.encoder.encode(legacy)))
    }

    func testOverlayKeepsParentForUnawareWriter() throws {
        let store = makeStore()
        let (parent, child) = nested(store)
        let exported = try store.exportPayload(id: child.id, kind: .notebook, deviceID: "a")
        var legacy = try NoteStore.decoder.decode(LegacyNotebook.self, from: exported.meta)
        legacy.name = "Renamed"
        let unawareOwned: Set<String> = ["id", "name", "symbol", "colorHex", "sortIndex", "revision", "modifiedAt"]
        let merged = try RawMetaOverlay(lastDecrypted: exported.meta)
            .merged(with: try NoteStore.encoder.encode(legacy), ownedKeys: unawareOwned)
        XCTAssertEqual(json(merged)["parent"] as? String, parent.id.uuidString)
        XCTAssertEqual(json(merged)["name"] as? String, "Renamed")
    }

    func testTwoStoresConvergeOnParent() throws {
        let a = makeStore("a"), b = makeStore("b")
        let (parent, child) = nested(a)
        for id in [parent.id, child.id] { try b.applyRemote(try a.exportPayload(id: id, kind: .notebook, deviceID: "a")) }
        XCTAssertEqual(b.notebook(with: child.id)?.parent, parent.id)
        XCTAssertEqual(b.notebook(with: child.id)?.revision, a.notebook(with: child.id)?.revision)
        XCTAssertEqual(b.notebookTree.children(of: parent.id), [child.id])
    }
}
