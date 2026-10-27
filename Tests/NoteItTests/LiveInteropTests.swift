import AppKit
import NoteItCore
import NoteItSync
import XCTest
@testable import NoteIt

/// Interop harness, Mac half (scripts/interop_tests.sh). Skipped unless `NOTEIT_INTEROP_DIR` is set.
///
/// The real `NoteStore` + `NoteStoreSyncAdapter` + `SyncEngine` sync with a running NoteIt web server through its
/// `/s3` endpoint, using an S3 key the web half made through the server's actions, and take turns with the web half
/// (`web/apps/web/test/interop/web-side.test.ts`, the web app's worker code) through marker files in the shared
/// directory. The step list is in the web half's header.
@MainActor
final class LiveInteropTests: XCTestCase {
    private struct Config: Decodable {
        var endpoint: URL
        var bucket: String
        var region: String
        var accessKeyId: String
        var secretAccessKey: String
        var passphrase: String
    }

    private struct WebIDs: Decodable {
        var work: UUID
        var plan: UUID
        var loose: UUID
        var folder: UUID
    }

    private var dir: URL!
    private var root: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTEIT_INTEROP_DIR"] else {
            throw XCTSkip("NOTEIT_INTEROP_DIR not set (see scripts/interop_tests.sh)")
        }
        dir = URL(fileURLWithPath: path, isDirectory: true)
        root = dir.appendingPathComponent("mac-library-\(UUID().uuidString)", isDirectory: true)
        // As SyncController does once sync is set up: local deletions are journaled for the engine.
        NoteStore.syncJournalEnabled = true
    }

    override func tearDownWithError() throws {
        NoteStore.syncJournalEnabled = false
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var stepTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["NOTEIT_INTEROP_STEP_TIMEOUT"].flatMap(TimeInterval.init) ?? 600
    }

    private func waitFor(_ marker: String) async throws {
        let file = dir.appendingPathComponent("\(marker).done")
        let start = Date()
        while !FileManager.default.fileExists(atPath: file.path) {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("web.failed").path) {
                throw XCTSkip("the web half failed; see its log")
            }
            if Date().timeIntervalSince(start) > stepTimeout { XCTFail("timed out waiting for \(marker)"); throw CancellationError() }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func done(_ marker: String) throws {
        try Data(Date().description.utf8).write(to: dir.appendingPathComponent("\(marker).done"))
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }

    func testWebMacRoundTrip() async throws {
        do {
            try await run()
        } catch {
            try? Data("\(error)".utf8).write(to: dir.appendingPathComponent("mac.failed"))
            throw error
        }
    }

    private func run() async throws {
        // MARK: mac-1 — pull what the web made and check it field by field.
        try await waitFor("web-1")
        let config = try read(Config.self, "config.json")
        let ids = try read(WebIDs.self, "web.json")
        let backend = S3Backend(config: S3Config(endpoint: config.endpoint, region: config.region, bucket: config.bucket, pathStyle: true),
                                credentials: S3Credentials(accessKeyID: config.accessKeyId, secretAccessKey: config.secretAccessKey),
                                session: URLSession(configuration: .ephemeral))
        let session = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: .passphrase(config.passphrase),
                                                          deviceName: "Mac Interop", createIfMissing: false, encrypted: true).session
        XCTAssertTrue(session.features.contains(.noteItDoc))
        let ref = StoreSessionRef(session)
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        let engine = SyncEngine(backend: backend, session: ref, local: NoteStoreSyncAdapter(store: store, deviceID: "MAC-INTEROP", session: ref),
                                stateURL: root.appendingPathComponent("sync-state.json"), deviceID: "MAC-INTEROP", deviceName: "Mac Interop")
        func sync() async throws -> SyncReport {
            let report = try await engine.sync()
            XCTAssertTrue(report.errors.isEmpty, "\(report.errors)")
            store.flush()
            return report
        }
        _ = try await sync()

        let work = try XCTUnwrap(store.notebook(with: ids.work), "notebook from the web")
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(work.colorHex.uppercased(), "#FF9500")
        XCTAssertEqual(work.symbol, "briefcase")

        let plan = try XCTUnwrap(store.note(with: ids.plan), "note from the web")
        XCTAssertEqual(plan.title, "Plan #project")
        XCTAssertEqual(plan.tags, ["project"])
        XCTAssertEqual(plan.notebookID, ids.work)
        XCTAssertTrue(plan.isPinned)
        XCTAssertNil(plan.deletedAt)
        let body = store.body(for: ids.plan)
        let text = body.string
        XCTAssertTrue(text.hasPrefix("Plan #project\nShip the release on time\n"), text)
        let release = (text as NSString).range(of: "release")
        let font = try XCTUnwrap(body.attribute(.font, at: release.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "“release” is bold")
        let onTime = (text as NSString).range(of: "on time")
        let plainFont = body.attribute(.font, at: onTime.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(plainFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "“on time” is not bold")

        let tasks = store.tasks(query: "", includeCompleted: true).values.flatMap { $0 }.filter { $0.ref.noteID == ids.plan }
        let ship = try XCTUnwrap(tasks.first { $0.line.text.hasPrefix("ship it") }, "\(tasks.map(\.line.text))")
        XCTAssertFalse(ship.line.checked)
        XCTAssertEqual(ship.line.due, LocalDateTime(year: 2026, month: 11, day: 2))
        let written = try XCTUnwrap(tasks.first { $0.line.text.hasPrefix("write notes") })
        XCTAssertTrue(written.line.checked)
        let call = try XCTUnwrap(tasks.first { $0.line.text.hasPrefix("call Sam") })
        XCTAssertEqual(call.line.remind, LocalDateTime(year: 2026, month: 11, day: 1, hour: 9, minute: 0))
        XCTAssertNil(call.line.due)

        let loose = try XCTUnwrap(store.note(with: ids.loose))
        XCTAssertEqual(loose.title, "Loose #misc")
        XCTAssertEqual(loose.tags, ["misc"])
        XCTAssertNil(loose.notebookID)
        XCTAssertFalse(loose.isPinned)

        let folder = try XCTUnwrap(store.smartFolders.first { $0.id == ids.folder })
        XCTAssertEqual(folder.name, "Projects")
        XCTAssertEqual(folder.query, "tag:project")

        // Then the Mac edits, adds and deletes.
        let edited = NSMutableAttributedString(attributedString: body)
        let firstLineEnd = (edited.string as NSString).range(of: "\n").location
        edited.insert(NSAttributedString(string: "edited on mac\n"), at: firstLineEnd + 1)
        store.updateBody(ids.plan, edited)
        _ = try store.setTaskChecked(ship.ref, true)
        let fromMac = store.createNote(in: ids.work, initial: NSAttributedString(string: "From Mac #mac\nHello web"))
        store.deleteNote(ids.loose)
        try store.updateSmartFolder(ids.folder, name: folder.name, query: "tag:project OR tag:mac", symbol: folder.symbol)
        var renamed = work
        renamed.name = "Work (Mac)"
        store.updateNotebook(renamed)
        store.flush()
        _ = try await sync()
        try JSONEncoder().encode(["fromMac": fromMac.id.uuidString]).write(to: dir.appendingPathComponent("mac.json"))
        try done("mac-1")

        // MARK: mac-2 — the web has an unsynced edit to Plan; the Mac edits it too and syncs first.
        try await waitFor("web-2")
        let current = NSMutableAttributedString(attributedString: store.body(for: ids.plan))
        let end = (current.string as NSString).range(of: "\n").location
        current.insert(NSAttributedString(string: "mac concurrent edit\n"), at: end + 1)
        store.updateBody(ids.plan, current)
        store.flush()
        _ = try await sync()
        try done("mac-2")

        // MARK: mac-3 — the web kept both edits as one conflict copy; the Mac sees the same.
        try await waitFor("web-3")
        let webConflict = try read([String: String].self, "web-conflict.json")
        _ = try await sync()
        _ = try await sync()
        let copies = store.notes.filter { $0.conflictSource != nil && $0.deletedAt == nil }
        XCTAssertEqual(copies.count, 1, "\(store.notes.map { ($0.title, $0.conflictSource ?? "-") })")
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(copy.id.uuidString, webConflict["copy"])
        XCTAssertEqual(copy.conflictSource, webConflict["source"])
        XCTAssertEqual(copy.conflictOriginalID?.uuidString, webConflict["original"])
        let all = store.notes.filter { $0.deletedAt == nil }.map { store.body(for: $0.id).string }.joined(separator: "\n")
        XCTAssertTrue(all.contains("web concurrent edit"), all)
        XCTAssertTrue(all.contains("mac concurrent edit"), all)
        XCTAssertTrue(store.body(for: ids.plan).string.contains("edited on mac"))
        try done("mac-3")
    }
}
