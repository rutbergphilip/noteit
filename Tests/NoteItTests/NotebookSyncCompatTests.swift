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

    // MARK: Through the sync engine

    private struct Peer {
        let engine: SyncEngine
        func sync() async throws -> SyncReport { try await engine.sync() }
    }

    private func peer(_ name: String, _ local: SyncLocalStore, backend: InMemoryBackend) -> Peer {
        Peer(engine: SyncEngine(backend: backend, cipher: PassthroughCipher(), local: local,
                                stateURL: root.appendingPathComponent("\(name)-sync.json"), deviceID: name, deviceName: name))
    }

    private func adapter(_ store: NoteStore, _ name: String) -> NoteStoreSyncAdapter {
        NoteStoreSyncAdapter(store: store, deviceID: name)
    }

    private func isQuiet(_ report: SyncReport) -> Bool {
        report.pushed == 0 && report.pulled == 0 && report.deleted == 0 && report.conflicts == 0 && report.errors.isEmpty
    }

    func testOlderClientRenameKeepsParentAfterRepair() async throws {
        let backend = InMemoryBackend()
        _ = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false)
        let a = makeStore("a"), b = makeStore("b")
        let legacyStore = LegacyNotebookStore()
        let devA = peer("A", adapter(a, "A"), backend: backend)
        let devB = peer("B", adapter(b, "B"), backend: backend)
        let devL = peer("L", legacyStore, backend: backend)
        let (parent, child) = nested(a)

        _ = try await devA.sync()
        _ = try await devL.sync()
        let strippedOnL = await legacyStore.hasParentKey(child.id)
        XCTAssertEqual(strippedOnL, false)
        try await Task.sleep(nanoseconds: 5_000_000)
        await legacyStore.rename(child.id, to: "Customers")
        _ = try await devL.sync()

        _ = try await devA.sync()
        XCTAssertEqual(a.notebook(with: child.id)?.name, "Customers")
        XCTAssertEqual(a.notebook(with: child.id)?.parent, parent.id)

        for _ in 0..<2 { for dev in [devA, devL, devB] { _ = try await dev.sync() } }
        for _ in 0..<3 {
            for (name, dev) in [("A", devA), ("L", devL), ("B", devB)] {
                let report = try await dev.sync()
                XCTAssertTrue(isQuiet(report), "\(name) still syncing: \(report)")
            }
        }
        XCTAssertEqual(a.notebook(with: child.id)?.parent, parent.id)
        XCTAssertEqual(b.notebook(with: child.id)?.parent, parent.id)
        XCTAssertEqual(b.notebook(with: child.id)?.name, "Customers")
        XCTAssertEqual(a.notebooks.count, 2)
        XCTAssertEqual(b.notebooks.count, 2)
        let legacyCount = await legacyStore.notebookCount()
        XCTAssertEqual(legacyCount, 2)
    }

    func testConcurrentMovesLastWriterWinsWithoutCopies() async throws {
        let backend = InMemoryBackend()
        _ = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false)
        let a = makeStore("a"), b = makeStore("b")
        let devA = peer("A", adapter(a, "A"), backend: backend)
        let devB = peer("B", adapter(b, "B"), backend: backend)
        let first = a.createNotebook(name: "First", symbol: "folder", colorHex: "#0A84FF")
        let second = a.createNotebook(name: "Second", symbol: "folder", colorHex: "#0A84FF")
        let moving = a.createNotebook(name: "Moving", symbol: "folder", colorHex: "#0A84FF")
        _ = try await devA.sync()
        _ = try await devB.sync()

        XCTAssertTrue(a.moveNotebook(moving.id, under: first.id))
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(b.moveNotebook(moving.id, under: second.id))
        _ = try await devA.sync()
        _ = try await devB.sync()
        _ = try await devA.sync()

        XCTAssertEqual(a.notebook(with: moving.id)?.parent, second.id)
        XCTAssertEqual(b.notebook(with: moving.id)?.parent, second.id)
        XCTAssertEqual(a.notebooks.count, 3)
        XCTAssertEqual(b.notebooks.count, 3)
        XCTAssertTrue(a.notes.isEmpty && b.notes.isEmpty, "no conflict copies")
    }
}

/// A `SyncLocalStore` that keeps notebooks the way NoteIt 0.2 did: decoding drops keys it doesn't know,
/// so `parent` is gone from everything it pushes.
private actor LegacyNotebookStore: SyncLocalStore {
    private struct Entry {
        var record: LocalRecord
        var meta: [String: Any]
        var body: Data?
    }

    private var entries: [UUID: Entry] = [:]
    private static let known: Set<String> = ["id", "name", "symbol", "colorHex", "sortIndex", "revision", "modifiedAt"]

    func hasParentKey(_ id: UUID) -> Bool? { entries[id].map { $0.meta.keys.contains("parent") } }

    func notebookCount() -> Int { entries.values.filter { $0.record.kind == .notebook }.count }

    func rename(_ id: UUID, to name: String) {
        guard var entry = entries[id] else { return }
        let revision = UUID(), now = Date()
        entry.meta["name"] = name
        entry.meta["revision"] = revision.uuidString
        entry.meta["modifiedAt"] = ISO8601DateFormatter().string(from: now)
        entry.record.revision = revision
        entry.record.modifiedAt = now
        entries[id] = entry
    }

    func records() -> [LocalRecord] { entries.values.map(\.record) }

    func deletions() -> [UUID: LocalDeletion] { [:] }

    func export(_ id: UUID, kind: RecordKind) throws -> RecordPayload {
        guard let entry = entries[id] else { throw CocoaError(.fileNoSuchFile) }
        return RecordPayload(id: id, kind: kind, revision: entry.record.revision, modifiedAt: entry.record.modifiedAt,
                             deviceID: "legacy", meta: try JSONSerialization.data(withJSONObject: entry.meta), body: entry.body)
    }

    func apply(_ payload: RecordPayload) throws {
        var meta = (try JSONSerialization.jsonObject(with: payload.meta) as? [String: Any]) ?? [:]
        if payload.kind == .notebook { meta = meta.filter { Self.known.contains($0.key) } }
        entries[payload.id] = Entry(record: LocalRecord(id: payload.id, kind: payload.kind, revision: payload.revision,
                                                        modifiedAt: payload.modifiedAt), meta: meta, body: payload.body)
    }

    func applyDeletion(_ id: UUID, kind: RecordKind) { entries[id] = nil }

    func importConflictCopy(_ payload: RecordPayload, fromDevice name: String) throws {}

    func clearDeletion(_ id: UUID) {}
}
