import AppKit
import NoteItDoc
import NoteItSync
import XCTest
@testable import NoteIt

/// web-app Task 0.4: the app's body transport. A store with `noteit-doc` carries noteit-doc containers (with the
/// note's extras) between Macs; one without it carries RTFD; incoming bodies dispatch on `bodyFormat`.
@MainActor
final class SyncDocBodyTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-syncdoc-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeStore(_ name: String) -> NoteStore {
        NoteStore(location: LibraryLocation(url: root.appendingPathComponent(name), seedsFreshLibrary: false))
    }

    /// Opens the store like `SyncController` and shares one session ref between the engine and the adapter.
    private func engine(_ name: String, _ store: NoteStore, _ backend: StorageBackend) async throws -> (SyncEngine, StoreSessionRef) {
        let session = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: nil, deviceName: name,
                                                          createIfMissing: true, encrypted: false).session
        let ref = StoreSessionRef(session)
        let engine = SyncEngine(backend: backend, session: ref, local: NoteStoreSyncAdapter(store: store, deviceID: name, session: ref),
                                stateURL: root.appendingPathComponent("\(name)-sync.json"), deviceID: name, deviceName: name)
        return (engine, ref)
    }

    private func envelope(_ backend: InMemoryBackend, _ id: UUID) async throws -> RemoteEnvelope {
        try JSONDecoder().decode(RemoteEnvelope.self, from: try await backend.get(RemoteLayout.meta(.note, id)).data)
    }

    func testUpgradedStoreCarriesNoteItDocBodiesBetweenMacs() async throws {
        let backend = InMemoryBackend()
        // A store as every earlier build created it: RTFD bodies, no features.
        _ = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: nil, deviceName: "",
                                                createIfMissing: true, encrypted: false)
        let a = makeStore("a")
        let note = a.createNote(in: nil, initial: NSAttributedString(string: "Groceries\nMilk and eggs"))
        a.setBodyExtras(ContainerExtras(frontMatter: "source: web", extra: [:]), for: note.id)
        a.flush()
        let (engineA, refA) = try await engine("a", a, backend)
        let first = try await engineA.sync()
        XCTAssertTrue(first.errors.isEmpty, "\(first.errors)")
        XCTAssertTrue(refA.current.features.contains(.noteItDoc), "the only device upgrades on its first clean pass")

        let env = try await envelope(backend, note.id)
        XCTAssertEqual(env.bodyFormat, BodyFormat.noteItDocV1)
        let version = try XCTUnwrap(env.bodyVersion)
        let listed = try await backend.list(prefix: RemoteLayout.bodiesPrefix)
        let bodyKey = try XCTUnwrap(listed.first { $0.key.contains(version.uuidString) }?.key)
        let container = try BodyContainer.decode(try await backend.get(bodyKey).data)
        XCTAssertEqual(container.frontMatter, "source: web", "the note's extras travel in the container")

        let b = makeStore("b")
        let (engineB, _) = try await engine("b", b, backend)
        let pulled = try await engineB.sync()
        XCTAssertTrue(pulled.errors.isEmpty, "\(pulled.errors)")
        XCTAssertEqual(b.body(for: note.id).string.trimmingCharacters(in: .newlines), "Groceries\nMilk and eggs")
        XCTAssertEqual(b.note(with: note.id)?.title, "Groceries")
        XCTAssertEqual(b.note(with: note.id)?.revision, a.note(with: note.id)?.revision, "conversion keeps the revision")

        b.updateBody(note.id, NSAttributedString(string: "Groceries\nMilk, eggs and bread"))
        b.flush()
        _ = try await engineB.sync()
        _ = try await engineA.sync()
        XCTAssertEqual(a.body(for: note.id).string.trimmingCharacters(in: .newlines), "Groceries\nMilk, eggs and bread")
        let edited = try await envelope(backend, note.id)
        XCTAssertEqual(edited.bodyFormat, BodyFormat.noteItDocV1)
        XCTAssertNotEqual(edited.bodyVersion, version)
    }

    func testStoreWithoutNoteItDocStillCarriesRTFD() async throws {
        let backend = InMemoryBackend()
        _ = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: nil, deviceName: "",
                                                createIfMissing: true, encrypted: false, supported: [.keyring])
        let a = makeStore("a")
        let note = a.createNote(in: nil, initial: NSAttributedString(string: "Plain\nold"))
        a.flush()
        let session = try await SyncEngine.connectSession(backend: backend, kind: .library, credential: nil, deviceName: "a",
                                                          createIfMissing: false, encrypted: false, supported: [.keyring]).session
        let ref = StoreSessionRef(session)
        let engine = SyncEngine(backend: backend, session: ref, local: NoteStoreSyncAdapter(store: a, deviceID: "a", session: ref),
                                stateURL: root.appendingPathComponent("a-sync.json"), deviceID: "a", deviceName: "a")
        _ = try await engine.sync()
        let env = try await envelope(backend, note.id)
        XCTAssertNil(env.bodyFormat, "a build that can't add noteit-doc keeps RTFD")
        let body = try await backend.get(RemoteLayout.body(note.id)).data
        XCTAssertNotNil(NSAttributedString(rtfd: body, documentAttributes: nil))
    }

    func testDecodeSyncBodyDispatchesOnFormatWithRTFDFallback() throws {
        let text = NSAttributedString(string: "Title\nbody")
        let rtfd = try NoteStore.serializeBody(text)
        let doc = try BodyCodec.noteItDoc(of: text, extras: ContainerExtras(frontMatter: "k: v", extra: [:])).encoded()

        let legacy = try NoteStore.decodeSyncBody(rtfd, format: nil)
        XCTAssertTrue(legacy.isRTFD)
        XCTAssertEqual(legacy.body.text.string.trimmingCharacters(in: .newlines), "Title\nbody")

        let labelled = try NoteStore.decodeSyncBody(doc, format: BodyFormat.noteItDocV1)
        XCTAssertFalse(labelled.isRTFD)
        XCTAssertEqual(labelled.body.text.string.trimmingCharacters(in: .newlines), "Title\nbody")
        XCTAssertEqual(labelled.body.extras.frontMatter, "k: v")

        let sniffed = try NoteStore.decodeSyncBody(doc, format: nil)
        XCTAssertFalse(sniffed.isRTFD, "an unlabelled container that isn't RTFD is read as noteit-doc")

        XCTAssertThrowsError(try NoteStore.decodeSyncBody(doc, format: "noteit-doc/2"))
        XCTAssertThrowsError(try NoteStore.decodeSyncBody(rtfd, format: BodyFormat.noteItDocV1))
    }

    func testPreparedNoteItDocNoteKeepsItsExtrasAndIsNotRTFD() throws {
        let store = makeStore("p")
        let id = UUID()
        let text = NSAttributedString(string: "From the web\nhello")
        let meta = NoteMeta(id: id, notebookID: nil, title: "", preview: "", isPinned: false, createdAt: Date(), updatedAt: Date(),
                            tags: [], revision: UUID())
        let payload = RecordPayload(id: id, kind: .note, revision: meta.revision!, modifiedAt: meta.updatedAt, deviceID: "web",
                                    meta: try NoteStore.encoder.encode(meta),
                                    body: try BodyCodec.noteItDoc(of: text, extras: ContainerExtras(frontMatter: "a: b", extra: [:])).encoded(),
                                    bodyFormat: BodyFormat.noteItDocV1)
        var prepared = try NoteStore.prepareRemoteNote(payload, storage: store.bodyStorage)
        defer { prepared.discard() }
        XCTAssertFalse(prepared.bodyIsRTFD)
        XCTAssertEqual(prepared.extras.frontMatter, "a: b")
        XCTAssertEqual(prepared.meta.title, "From the web")
        try store.applyPreparedRemoteNote(prepared)
        XCTAssertEqual(store.body(for: id).string.trimmingCharacters(in: .newlines), "From the web\nhello")
    }
}
