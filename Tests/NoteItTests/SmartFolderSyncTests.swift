import Foundation
import NoteItCore
import NoteItSync
import XCTest
@testable import NoteIt

/// Smart folders through the real engine between two libraries.
@MainActor
final class SmartFolderSyncTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-sfsync-\(UUID().uuidString)", isDirectory: true)
        NoteStore.syncJournalEnabled = true
    }

    override func tearDownWithError() throws {
        NoteStore.syncJournalEnabled = false
        try? fm.removeItem(at: root)
    }

    private func makeStore(_ name: String) -> NoteStore {
        NoteStore(location: LibraryLocation(url: root.appendingPathComponent(name), seedsFreshLibrary: false))
    }

    private func engine(_ name: String, _ store: NoteStore, _ backend: InMemoryBackend) -> SyncEngine {
        SyncEngine(backend: backend, cipher: PassthroughCipher(), local: NoteStoreSyncAdapter(store: store, deviceID: name),
                   stateURL: root.appendingPathComponent("\(name)-sync.json"), deviceID: name, deviceName: name)
    }

    func testCreateEditDeleteReachTheOtherMacWithoutTouchingNotes() async throws {
        let backend = InMemoryBackend()
        _ = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false)
        let a = makeStore("a"), b = makeStore("b")
        let syncA = engine("A", a, backend), syncB = engine("B", b, backend)
        let note = a.createNote(in: nil, initial: NSAttributedString(string: "Plan\n#work"))
        let folder = try a.createSmartFolder(name: "Work", query: "tag:work")
        a.flush()
        _ = try await syncA.sync()
        _ = try await syncB.sync()
        XCTAssertEqual(b.smartFolder(with: folder.id)?.query, "tag:work")
        XCTAssertEqual(b.notes(for: .smartFolder(folder.id), search: "").map(\.id), [note.id])

        try b.updateSmartFolder(folder.id, name: "Work stuff", query: "tag:work is:pinned", symbol: "star")
        b.flush()
        _ = try await syncB.sync()
        _ = try await syncA.sync()
        XCTAssertEqual(a.smartFolder(with: folder.id)?.name, "Work stuff")
        XCTAssertEqual(a.smartFolders.count, 1)

        a.deleteSmartFolder(folder.id)
        a.flush()
        _ = try await syncA.sync()
        _ = try await syncB.sync()
        XCTAssertNil(b.smartFolder(with: folder.id))
        XCTAssertTrue(a.syncDeletions().isEmpty)
        let keys = try await backend.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertFalse(keys.contains(RemoteLayout.meta(.smartFolder, folder.id)))
        XCTAssertTrue(keys.contains(RemoteLayout.tombstone(folder.id)))
        XCTAssertEqual(a.notes.map(\.id), [note.id])
        XCTAssertEqual(b.notes.map(\.id), [note.id])

        let quietA = try await syncA.sync(), quietB = try await syncB.sync()
        XCTAssertEqual(quietA.pushed + quietA.pulled + quietB.pushed + quietB.pulled, 0)
    }

    /// An unreadable smart-folders.json starts empty; the next pass fills it again from the other Mac's records.
    func testUnreadableFileRefillsFromSync() async throws {
        let backend = InMemoryBackend()
        _ = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false)
        var a = makeStore("a")
        let folder = try a.createSmartFolder(name: "Due", query: "has:due")
        a.flush()
        _ = try await engine("A", a, backend).sync()

        try Data("garbage".utf8).write(to: a.smartFoldersURL)
        a = makeStore("a")
        XCTAssertTrue(a.smartFolders.isEmpty)
        _ = try await engine("A", a, backend).sync()
        XCTAssertEqual(a.smartFolder(with: folder.id)?.name, "Due")
        let keys = try await backend.list(prefix: RemoteLayout.root).map(\.key)
        XCTAssertTrue(keys.contains(RemoteLayout.meta(.smartFolder, folder.id)))
    }
}
