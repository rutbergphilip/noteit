import AppKit
import XCTest
import NoteItAPI
import NoteItCore
@testable import NoteIt

@MainActor
final class LocalAPIHandlersTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-localapi-\(UUID().uuidString)", isDirectory: true)
        suiteName = "noteit-localapi-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    private struct Fixture {
        let handlers: LocalAPIHandlers
        let store: NoteStore
        let registry: LocalAPIRouteRegistry
    }

    private func makeFixture(loading: Bool = false, opened: ((UUID) -> Void)? = nil) -> Fixture {
        let store = NoteStore(location: LibraryLocation(url: root.appendingPathComponent("lib"), seedsFreshLibrary: false))
        let staged = StagedUploads(directory: root.appendingPathComponent("staged"))
        let service = AutomationService(store: store, defaults: defaults, staged: staged, dailyNotesAvailable: { false },
                                        isLoading: { loading })
        let registry = LocalAPIRouteRegistry()
        let handlers = LocalAPIHandlers(service: service, registry: registry, openNote: { id in
            _ = try service.note(id)
            opened?(id)
        })
        return Fixture(handlers: handlers, store: store, registry: registry)
    }

    private func call(_ fixture: Fixture, _ route: RouteID, params: [String: String] = [:], query: [String: String] = [:],
                      headers: [(String, String)] = [], body: Data = Data(),
                      scopes: [APIScope] = [.read, .write]) async -> HTTPResponse {
        let spec = APIRoutes.all.first { $0.id == route.rawValue }!
        let request = HTTPRequest(method: spec.method.rawValue, path: spec.pattern, query: query, headers: HTTPHeaders(headers),
                                  body: body)
        let client = ClientRecord(id: UUID(), name: "Test", kind: .script, scopes: scopes, origin: nil, tokenHash: "h",
                                  tokenHint: "nit_test", createdAt: Date())
        let context = LocalAPIContext(request: request, route: RouteMatch(spec: spec, params: params), client: client,
                                      origin: .native)
        return await fixture.handlers.respond(context)
    }

    private func json<T: Encodable>(_ value: T) -> Data {
        try! APIJSON.encoder().encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse, file: StaticString = #filePath,
                                      line: UInt = #line) throws -> T {
        do {
            return try APIJSON.decoder().decode(type, from: response.body)
        } catch {
            XCTFail("Status \(response.status): \(String(decoding: response.body, as: UTF8.self))", file: file, line: line)
            throw error
        }
    }

    private func object(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func errorCode(_ response: HTTPResponse) -> String? {
        (try? APIJSON.decoder().decode(APIErrorBody.self, from: response.body))?.error.code.rawValue
    }

    @discardableResult
    private func addNote(_ store: NoteStore, _ text: String, in notebook: UUID? = nil) -> UUID {
        store.createNote(in: notebook, initial: NSAttributedString(string: text)).id
    }

    private func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath,
                                           line: UInt = #line) {
        XCTAssertEqual(a, b, message, file: file, line: line)
    }

    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func lock(_ store: NoteStore, _ id: UUID) {
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: Notes

    func testNotesList() async throws {
        let f = makeFixture()
        let work = f.store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        addNote(f.store, "One\nfirst", in: work.id)
        addNote(f.store, "Two\nsecond", in: work.id)
        addNote(f.store, "Three\nthird")
        let page = try decode(Page<NoteSummaryDTO>.self, await call(f, .notesList, query: ["notebook": "work", "limit": "1"]))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.notebookName, "Work")
        let next = try decode(Page<NoteSummaryDTO>.self,
                              await call(f, .notesList, query: ["notebook": work.id.uuidString, "cursor": try XCTUnwrap(page.nextCursor)]))
        XCTAssertEqual(next.items.count, 1)
        XCTAssertNil(next.nextCursor)
        XCTAssertNotEqual(next.items.first?.id, page.items.first?.id)
        let all = await call(f, .notesList)
        XCTAssertEqual(try decode(Page<NoteSummaryDTO>.self, all).items.count, 3)
        XCTAssertTrue(try object(all).keys.contains("nextCursor"))
        assertEqual(await call(f, .notesList, query: ["deleted": "maybe"]).status, 400)
        assertEqual(await call(f, .notesList, query: ["updatedSince": "yesterday"]).status, 400)
        let future = try decode(Page<NoteSummaryDTO>.self, await call(f, .notesList, query: ["updatedSince": "2999-01-01T00:00:00Z"]))
        XCTAssertTrue(future.items.isEmpty)
    }

    func testNoteCreate201() async throws {
        let f = makeFixture()
        let inbox = f.store.createNotebook(name: "Inbox", symbol: "tray", colorHex: "#0A84FF")
        let response = await call(f, .noteCreate, body: json(CreateNoteRequest(title: "Groceries", body: "- Milk", tags: ["home"])))
        XCTAssertEqual(response.status, 201)
        let note = try decode(NoteDTO.self, response)
        XCTAssertEqual(note.summary.title, "Groceries")
        XCTAssertEqual(note.summary.notebookID, inbox.id)
        XCTAssertEqual(note.summary.tags, ["home"])
        XCTAssertNotNil(note.summary.revision)
        XCTAssertEqual(note.format, .markdown)
        XCTAssertTrue(note.body.contains("Milk"))
        XCTAssertNotNil(f.store.note(with: note.summary.id))
        let named = await call(f, .noteCreate, body: json(CreateNoteRequest(body: "x", format: .text, notebook: "Nowhere")))
        XCTAssertEqual(named.status, 404)
    }

    func testNoteGetFormats() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Plan\nBuy milk")
        for format in ["markdown", "text", "html", "noteit-doc"] {
            let note = try decode(NoteDTO.self, await call(f, .noteGet, params: ["id": id.uuidString], query: ["format": format]))
            XCTAssertEqual(note.format.rawValue, format)
            XCTAssertTrue(note.body.contains("Buy milk"), format)
        }
        assertEqual(try decode(NoteDTO.self, await call(f, .noteGet, params: ["id": id.uuidString])).format, .markdown)
        assertEqual(await call(f, .noteGet, params: ["id": id.uuidString], query: ["format": "rtf"]).status, 400)
    }

    func testNotePatchIfMatch412IncludesCurrent() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Plan\nold")
        let revision = try XCTUnwrap(f.store.note(with: id)?.revision)
        let patched = await call(f, .notePatch, params: ["id": id.uuidString], headers: [("If-Match", "\"\(revision.uuidString)\"")],
                                 body: json(PatchNoteRequest(body: "Plan\n\nnew", format: .markdown, pinned: true)))
        let note = try decode(NoteDTO.self, patched)
        XCTAssertTrue(note.summary.pinned)
        XCTAssertTrue(note.body.contains("new"))
        let current = try XCTUnwrap(note.summary.revision)
        XCTAssertNotEqual(current, revision)

        let stale = await call(f, .notePatch, params: ["id": id.uuidString], headers: [("If-Match", "\"\(revision.uuidString)\"")],
                               body: json(PatchNoteRequest(title: "Changed")))
        XCTAssertEqual(stale.status, 412)
        XCTAssertEqual(errorCode(stale), "revision_mismatch")
        let body = try object(stale)
        let currentNote = try XCTUnwrap(body["current"] as? [String: Any])
        XCTAssertEqual(currentNote["revision"] as? String, current.uuidString)
        XCTAssertEqual(currentNote["title"] as? String, "Plan")
        assertEqual(await call(f, .notePatch, params: ["id": id.uuidString], headers: [("If-Match", "nope")],
                                  body: json(PatchNoteRequest(pinned: false))).status, 400)
    }

    func testNoteDeleteAndRestore() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Gone")
        assertEqual(await call(f, .noteDelete, params: ["id": id.uuidString]).status, 204)
        XCTAssertNotNil(f.store.note(with: id)?.deletedAt)
        let deleted = try decode(Page<NoteSummaryDTO>.self, await call(f, .notesList, query: ["deleted": "only"]))
        XCTAssertEqual(deleted.items.map(\.id), [id])
        XCTAssertNotNil(deleted.items.first?.deletedAt)
        assertEqual(await call(f, .noteGet, params: ["id": id.uuidString]).status, 200)
        let restored = try decode(NoteDTO.self, await call(f, .noteRestore, params: ["id": id.uuidString]))
        XCTAssertNil(restored.summary.deletedAt)
        XCTAssertNil(f.store.note(with: id)?.deletedAt)
    }

    func testPermanentDeleteNeedsAdmin() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Gone")
        f.store.moveToRecentlyDeleted([id])
        let denied = await call(f, .noteDelete, params: ["id": id.uuidString], query: ["permanent": "true"])
        XCTAssertEqual(denied.status, 403)
        XCTAssertEqual(errorCode(denied), "forbidden_scope")
        XCTAssertNotNil(f.store.note(with: id))
        let allowed = await call(f, .noteDelete, params: ["id": id.uuidString], query: ["permanent": "true"],
                                 scopes: [.read, .write, .admin])
        XCTAssertEqual(allowed.status, 204)
        XCTAssertNil(f.store.note(with: id))
    }

    func testAppend() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Log\nfirst")
        let note = try decode(NoteDTO.self, await call(f, .noteAppend, params: ["id": id.uuidString],
                                                      body: json(AppendRequest(text: "second"))))
        XCTAssertTrue(note.body.contains("second"), note.body)
        XCTAssertTrue(note.body.contains("second"))
        _ = await call(f, .noteAppend, params: ["id": id.uuidString], body: json(AppendRequest(text: "zero", position: .start)))
        XCTAssertTrue(f.store.plainText(for: id).contains("zero"))
        assertEqual(await call(f, .noteAppend, params: ["id": id.uuidString],
                                  body: json(AppendRequest(text: "x", format: .html))).status, 400)
    }

    func testAppendIfRevision412() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Log\nfirst")
        let response = await call(f, .noteAppend, params: ["id": id.uuidString],
                                  body: json(AppendRequest(text: "second", ifRevision: UUID())))
        XCTAssertEqual(response.status, 412)
        let current = try XCTUnwrap(try object(response)["current"] as? [String: Any])
        XCTAssertEqual(current["revision"] as? String, f.store.note(with: id)?.revision?.uuidString)
        XCTAssertFalse(f.store.plainText(for: id).contains("second"))
    }

    func testNoteOpen204() async {
        var opened: [UUID] = []
        let f = makeFixture(opened: { opened.append($0) })
        let id = addNote(f.store, "Open me")
        let response = await call(f, .noteOpen, params: ["id": id.uuidString])
        XCTAssertEqual(response.status, 204)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(opened, [id])
    }

    func testListSortUpdated() async throws {
        let f = makeFixture()
        let pinned = addNote(f.store, "Pinned")
        f.store.togglePin(pinned)
        let older = addNote(f.store, "Older")
        let newer = addNote(f.store, "Newer")
        f.store.notes[f.store.noteIndex(pinned)!].updatedAt = Date(timeIntervalSinceNow: -300)
        f.store.notes[f.store.noteIndex(older)!].updatedAt = Date(timeIntervalSinceNow: -200)
        f.store.notes[f.store.noteIndex(newer)!].updatedAt = Date(timeIntervalSinceNow: -100)
        let list = try decode(Page<NoteSummaryDTO>.self, await call(f, .notesList))
        XCTAssertEqual(list.items.map(\.id), [pinned, newer, older])
        let updated = try decode(Page<NoteSummaryDTO>.self, await call(f, .notesList, query: ["sort": "updated"]))
        XCTAssertEqual(updated.items.map(\.id), [newer, older, pinned])
        assertEqual(await call(f, .notesList, query: ["sort": "title"]).status, 400)
    }

    // MARK: Notebooks and tags

    func testNotebooksIncludeDefault() async throws {
        let f = makeFixture()
        let work = f.store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let inbox = f.store.createNotebook(name: "Inbox", symbol: "tray", colorHex: "#0A84FF")
        addNote(f.store, "A", in: work.id)
        let response = await call(f, .notebooksList)
        let body = try decode(NotebooksResponseDTO.self, response)
        XCTAssertEqual(body.defaultNotebookID, inbox.id)
        XCTAssertEqual(body.notebooks.map(\.name), f.store.sortedNotebooks.map(\.name))
        XCTAssertEqual(body.notebooks.first { $0.id == work.id }?.noteCount, 1)
        XCTAssertNil(try object(response)["notebooks"].flatMap { ($0 as? [[String: Any]])?.first?["parentID"] })

        defaults.set(PrefDefault.noNotebook, forKey: PrefKey.defaultNotebookID)
        let none = await call(f, .notebooksList)
        XCTAssertTrue(try object(none)["defaultNotebookID"] is NSNull)
    }

    func testNotebooksCRUD() async throws {
        let f = makeFixture()
        let created = await call(f, .notebookCreate, body: json(NotebookRequest(name: "Ideas", symbol: "lightbulb", color: "#FF9500")))
        XCTAssertEqual(created.status, 201)
        let notebook = try decode(NotebookDTO.self, created)
        XCTAssertEqual(notebook.name, "Ideas")
        XCTAssertEqual(notebook.symbol, "lightbulb")
        XCTAssertEqual(notebook.color.uppercased(), "#FF9500")
        assertEqual(await call(f, .notebookCreate, body: json(NotebookRequest(symbol: "x"))).status, 400)

        let renamed = try decode(NotebookDTO.self, await call(f, .notebookPatch, params: ["id": notebook.id.uuidString],
                                                              body: json(NotebookRequest(name: "Later"))))
        XCTAssertEqual(renamed.name, "Later")
        XCTAssertEqual(f.store.notebook(with: notebook.id)?.name, "Later")

        let note = addNote(f.store, "Inside", in: notebook.id)
        assertEqual(await call(f, .notebookDelete, params: ["id": notebook.id.uuidString]).status, 204)
        XCTAssertNil(f.store.notebook(with: notebook.id))
        XCTAssertNotNil(f.store.note(with: note)?.deletedAt)
        assertEqual(await call(f, .notebookDelete, params: ["id": notebook.id.uuidString]).status, 404)
    }

    func testTags() async throws {
        let f = makeFixture()
        addNote(f.store, "A\n#work #home")
        addNote(f.store, "B\n#work")
        let tags = try decode([TagDTO].self, await call(f, .tags))
        XCTAssertEqual(tags, [TagDTO(name: "home", noteCount: 1), TagDTO(name: "work", noteCount: 2)])
    }

    func testTagsTreeWithoutProviderIs501() async {
        let f = makeFixture()
        let response = await call(f, .tags, query: ["tree": "1"])
        XCTAssertEqual(response.status, 501)
        XCTAssertEqual(errorCode(response), "not_implemented")
    }

    func testTagsTreeUsesProvider() async throws {
        let f = makeFixture()
        let node = TagNodeDTO(name: "work", path: "work", noteCount: 1, totalCount: 2,
                              children: [TagNodeDTO(name: "clients", path: "work/clients", noteCount: 1, totalCount: 1, children: [])])
        f.registry.extendTags { [node] }
        assertEqual(try decode([TagNodeDTO].self, await call(f, .tags, query: ["tree": "1"])), [node])
    }

    private final class PathExtender: NotebookDTOExtending, @unchecked Sendable {
        let parent = UUID()
        func extend(_ dto: inout NotebookDTO, notebookID: UUID) {
            dto.parentID = parent
            dto.path = ["Parent", dto.name]
        }
    }

    func testNotebookExtenderFillsParentAndPath() async throws {
        let f = makeFixture()
        _ = f.store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let extender = PathExtender()
        f.registry.extendNotebooks(with: extender)
        let listed = try decode(NotebooksResponseDTO.self, await call(f, .notebooksList)).notebooks
        XCTAssertEqual(listed.first?.parentID, extender.parent)
        XCTAssertEqual(listed.first?.path, ["Parent", "Work"])
        let created = try decode(NotebookDTO.self, await call(f, .notebookCreate, body: json(NotebookRequest(name: "New"))))
        XCTAssertEqual(created.path, ["Parent", "New"])
    }

    // MARK: Search

    func testSearch() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Groceries\nBuy oat milk today")
        addNote(f.store, "Other\nnothing")
        let response = await call(f, .search, query: ["q": "oat"])
        let body = try decode(SearchResponseDTO.self, response)
        XCTAssertEqual(body.mode, "keyword")
        XCTAssertEqual(body.results.map(\.note.id), [id])
        XCTAssertTrue(body.results.first?.snippet.contains("oat milk") == true)
        assertEqual(await call(f, .search).status, 400)
        assertEqual(await call(f, .search, query: ["q": "oat", "limit": "0"]).status, 400)
    }

    func testUnknownSearchModeIs400() async {
        let f = makeFixture()
        let response = await call(f, .search, query: ["q": "x", "mode": "telepathy"])
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(errorCode(response), "bad_request")
    }

    func testRegisteredSearchModeOffIs501() async {
        let f = makeFixture()
        f.registry.registerSearchMode("meaning") { _, _ in .failure(.notAvailable) }
        let response = await call(f, .search, query: ["q": "x", "mode": "meaning"])
        XCTAssertEqual(response.status, 501)
        XCTAssertEqual(errorCode(response), "not_available")
    }

    func testHighlightsShape() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Groceries\nBuy oat milk")
        let keyword = try object(await call(f, .search, query: ["q": "oat"]))
        let first = try XCTUnwrap((keyword["results"] as? [[String: Any]])?.first)
        XCTAssertNil(first["score"])
        XCTAssertNil(first["highlights"])

        let summary = try decode(NoteDTO.self, await call(f, .noteGet, params: ["id": id.uuidString])).summary
        f.registry.registerSearchMode("ranked") { query, _ in
            .success([SearchResultDTO(note: summary, snippet: "Buy oat milk", score: 0.5,
                                      highlights: [HighlightDTO(field: .body, ranges: [[4, 3]])], matchedBy: ["ranked"])])
        }
        let ranked = try object(await call(f, .search, query: ["q": "oat", "mode": "ranked"]))
        XCTAssertEqual(ranked["mode"] as? String, "ranked")
        let result = try XCTUnwrap((ranked["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["score"] as? Double, 0.5)
        let highlight = try XCTUnwrap((result["highlights"] as? [[String: Any]])?.first)
        XCTAssertEqual(highlight["field"] as? String, "body")
        XCTAssertEqual(highlight["ranges"] as? [[Int]], [[4, 3]])
    }

    // MARK: Locked notes and readiness

    func testLockedNoteBodyIs423() async {
        let f = makeFixture()
        let id = addNote(f.store, "Secret\nhidden")
        lock(f.store, id)
        for response in [
            await call(f, .noteGet, params: ["id": id.uuidString]),
            await call(f, .notePatch, params: ["id": id.uuidString], body: json(PatchNoteRequest(body: "x"))),
            await call(f, .noteAppend, params: ["id": id.uuidString], body: json(AppendRequest(text: "x"))),
            await call(f, .attachmentsList, params: ["id": id.uuidString]),
            await call(f, .attachmentAdd, params: ["id": id.uuidString], body: pngData()),
        ] {
            XCTAssertEqual(response.status, 423)
            XCTAssertEqual(errorCode(response), "note_locked")
        }
        let pinned = await call(f, .notePatch, params: ["id": id.uuidString], body: json(PatchNoteRequest(pinned: true)))
        XCTAssertEqual(pinned.status, 200)
        XCTAssertNil(try? object(pinned)["body"])
        XCTAssertEqual(f.store.note(with: id)?.isPinned, true)
    }

    func testLockedNoteListedWithLockedTrue() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Secret\nhidden words")
        lock(f.store, id)
        let item = try unwrap(try decode(Page<NoteSummaryDTO>.self, await call(f, .notesList)).items.first)
        XCTAssertEqual(item.id, id)
        XCTAssertTrue(item.locked)
        XCTAssertEqual(item.preview, "")
        XCTAssertEqual(item.title, "Secret")
    }

    func testNotReadyIs503() async {
        let f = makeFixture(loading: true)
        for route in [RouteID.notesList, .notebooksList, .tags] {
            let response = await call(f, route)
            XCTAssertEqual(response.status, 503)
            XCTAssertEqual(errorCode(response), "not_ready")
        }
    }

    func testUrlIsNoteForm() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Linked")
        let item = try unwrap(try decode(Page<NoteSummaryDTO>.self, await call(f, .notesList)).items.first)
        XCTAssertEqual(item.url, "noteit://note/\(id.uuidString)")
    }

    // MARK: Attachments

    func testAttachmentsAddListGet() async throws {
        let f = makeFixture()
        let id = addNote(f.store, "Photos")
        let png = pngData()
        let added = await call(f, .attachmentAdd, params: ["id": id.uuidString],
                               headers: [("Content-Type", "image/png"), ("X-NoteIt-Filename", "shot.png")], body: png)
        XCTAssertEqual(added.status, 200)
        XCTAssertEqual(try decode(NoteDTO.self, added).summary.id, id)
        _ = await call(f, .attachmentAdd, params: ["id": id.uuidString], headers: [("Content-Type", "image/png")], body: png)
        let list = try decode([AttachmentDTO].self, await call(f, .attachmentsList, params: ["id": id.uuidString]))
        XCTAssertEqual(list.map(\.name), ["shot.png", "attachment.png"])
        XCTAssertEqual(list.first?.contentType, "image/png")
        XCTAssertEqual(list.first?.size, png.count)
        let file = await call(f, .attachmentGet, params: ["id": id.uuidString, "name": "shot.png"])
        XCTAssertEqual(file.status, 200)
        XCTAssertEqual(file.headers["Content-Type"], "image/png")
        XCTAssertEqual(file.body, png)
        assertEqual(await call(f, .attachmentGet, params: ["id": id.uuidString, "name": "none.png"]).status, 404)
    }

    func testStagedUploadInMarkdown() async throws {
        let f = makeFixture()
        let response = await call(f, .stagedUpload, headers: [("Content-Type", "image/png")], body: pngData())
        XCTAssertEqual(response.status, 201)
        let staged = try decode(StagedUploadDTO.self, response)
        XCTAssertTrue(staged.id.hasPrefix("att_"))
        let created = try decode(NoteDTO.self, await call(f, .noteCreate, body: json(CreateNoteRequest(
            title: "Pic", body: "![shot](noteit-attachment:\(staged.id))"))))
        let list = try decode([AttachmentDTO].self, await call(f, .attachmentsList, params: ["id": created.summary.id.uuidString]))
        XCTAssertEqual(list.count, 1)
    }

    // MARK: Trash and daily

    func testTrashEmptyNeedsAdmin() async {
        let f = makeFixture()
        let id = addNote(f.store, "Gone")
        f.store.moveToRecentlyDeleted([id])
        assertEqual(await call(f, .trashEmpty).status, 403)
        XCTAssertNotNil(f.store.note(with: id))
        assertEqual(await call(f, .trashEmpty, scopes: [.admin]).status, 204)
        XCTAssertNil(f.store.note(with: id))
    }

    func testDailyNotImplementedWhileGateOff() async {
        let f = makeFixture()
        for (route, body) in [(RouteID.daily, Data()), (.dailyAppend, json(DailyAppendRequest(text: "x")))] {
            let response = await call(f, route, body: body)
            XCTAssertEqual(response.status, 501)
            XCTAssertEqual(errorCode(response), "not_implemented")
        }
    }

    // MARK: Errors

    func testUnknownIdIs404() async {
        let f = makeFixture()
        for route in [RouteID.noteGet, .notePatch, .noteDelete, .noteRestore, .noteOpen, .attachmentsList] {
            let response = await call(f, route, params: ["id": UUID().uuidString], body: json(PatchNoteRequest(pinned: true)))
            XCTAssertEqual(response.status, 404, route.rawValue)
            XCTAssertEqual(errorCode(response), "not_found")
        }
        assertEqual(await call(f, .noteGet, params: ["id": "not-a-uuid"]).status, 404)
        assertEqual(await call(f, .notebookPatch, params: ["id": UUID().uuidString], body: json(NotebookRequest(name: "x"))).status, 404)
    }

    func testMalformedJSONIs400() async {
        let f = makeFixture()
        let id = addNote(f.store, "Plan")
        for (route, params) in [(RouteID.noteCreate, [:]), (.notePatch, ["id": id.uuidString]), (.noteAppend, ["id": id.uuidString]),
                                (.notebookCreate, [:])] {
            let response = await call(f, route, params: params, body: Data("{not json".utf8))
            XCTAssertEqual(response.status, 400, route.rawValue)
            XCTAssertEqual(errorCode(response), "bad_request")
        }
    }
}
