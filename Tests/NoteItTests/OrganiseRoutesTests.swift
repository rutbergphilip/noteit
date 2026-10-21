import AppKit
import XCTest
@testable import NoteIt
import NoteItAPI
import NoteItCore

@MainActor
final class OrganiseRoutesTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private var stores: [NoteStore] = []

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-organiseapi-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        stores.forEach { $0.flush() }
        stores = []
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        stores.append(store)
        return store
    }

    private func add(_ store: NoteStore, _ text: String) -> UUID {
        store.createNote(in: nil, initial: NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])).id
    }

    private func call(_ routeID: String, _ store: NoteStore, params: [String: String] = [:], query: [String: String] = [:],
                      body: Data = Data()) async -> HTTPResponse {
        let spec = OrganiseRoutes.routes.first { $0.id == routeID }!
        let request = HTTPRequest(method: spec.method.rawValue, path: spec.pattern, query: query, body: body)
        let context = LocalAPIContext(request: request, route: RouteMatch(spec: spec, params: params), client: nil, origin: .native)
        return await OrganiseRoutes.respond(routeID, context, store: store)
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

    private func errorCode(_ response: HTTPResponse) -> String? {
        (try? APIJSON.decoder().decode(APIErrorBody.self, from: response.body))?.error.code.rawValue
    }

    func testEveryRouteIsRegisteredOnceWithItsScope() {
        let registry = LocalAPIRouteRegistry()
        OrganiseRoutes.register(in: registry, store: makeStore())
        let expected: [(String, APIScope)] = [
            ("organise.tagRename", .write), ("organise.tagDelete", .write), ("organise.notebookMove", .write),
            ("organise.smartFolderList", .read), ("organise.smartFolderCreate", .write), ("organise.smartFolderGet", .read),
            ("organise.smartFolderUpdate", .write), ("organise.smartFolderDelete", .write), ("organise.taskList", .read),
            ("organise.taskComplete", .write), ("organise.taskDue", .write),
        ]
        XCTAssertEqual(registry.routes.map(\.id), expected.map(\.0))
        XCTAssertEqual(registry.routes.map(\.scope), expected.map(\.1))
        XCTAssertEqual(registry.validate(), [])
        XCTAssertNotNil(registry.tagTreeProvider)
        XCTAssertEqual(registry.notebookExtenders.count, 1)
    }

    func testRenameTagReturnsChangedNotesAndRejectsBadNames() async throws {
        let store = makeStore()
        let a = add(store, "One\nabout #work/clients")
        let b = add(store, "Two\n#work")
        _ = add(store, "Three\n#home")
        let response = await call("organise.tagRename", store, body: json(TagRenameRequest(from: "work", to: "job")))
        let result = try decode(TagEditResponseDTO.self, response)
        XCTAssertEqual(Set(result.changed), [a, b])
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(store.note(with: a)?.tags, ["job/clients"])

        let bad = await call("organise.tagRename", store, body: json(TagRenameRequest(from: "job", to: "a b")))
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(errorCode(bad), "bad_request")
        let unknown = await call("organise.tagDelete", store, body: json(TagDeleteRequest(tag: "nothing")))
        XCTAssertEqual(errorCode(unknown), "not_found")
        let deleted = try decode(TagEditResponseDTO.self, await call("organise.tagDelete", store, body: json(TagDeleteRequest(tag: "home"))))
        XCTAssertEqual(deleted.changed.count, 1)
        XCTAssertTrue(store.notesTagged("home").isEmpty)
    }

    func testTagTreeNests() {
        let store = makeStore()
        _ = add(store, "One\n#work/clients")
        _ = add(store, "Two\n#work")
        let tree = OrganiseRoutes.tagTree(store)
        XCTAssertEqual(tree.map(\.path), ["work"])
        XCTAssertEqual(tree.first?.noteCount, 1)
        XCTAssertEqual(tree.first?.totalCount, 2)
        XCTAssertEqual(tree.first?.children.map(\.path), ["work/clients"])
    }

    func testMoveNotebookFillsPathAndRefusesCycles() async throws {
        let store = makeStore()
        let work = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let clients = store.createNotebook(name: "Clients", symbol: "folder", colorHex: "#0A84FF")
        let moved = try decode(NotebookDTO.self, await call("organise.notebookMove", store, params: ["id": clients.id.uuidString],
                                                             body: json(NotebookMoveRequest(parentID: work.id))))
        XCTAssertEqual(moved.parentID, work.id)
        XCTAssertEqual(moved.path, ["Work", "Clients"])

        let cycle = await call("organise.notebookMove", store, params: ["id": work.id.uuidString],
                               body: json(NotebookMoveRequest(parentID: clients.id)))
        XCTAssertEqual(cycle.status, 400)
        XCTAssertEqual(errorCode(cycle), "bad_request")
        let missing = await call("organise.notebookMove", store, params: ["id": UUID().uuidString],
                                 body: json(NotebookMoveRequest(parentID: nil)))
        XCTAssertEqual(errorCode(missing), "not_found")

        var dto = NotebookDTO(id: clients.id, name: "Clients", symbol: "folder", color: "#0A84FF", sortIndex: 0, noteCount: 0)
        OrganiseRoutes.NotebookExtender(store: store).extend(&dto, notebookID: clients.id)
        XCTAssertEqual(dto.parentID, work.id)
        XCTAssertEqual(dto.path, ["Work", "Clients"])
    }

    func testSmartFolderRoundTrip() async throws {
        let store = makeStore()
        let match = add(store, "Plan\n#work")
        _ = add(store, "Other\n#home")
        let created = await call("organise.smartFolderCreate", store, body: json(SmartFolderRequest(name: "Work", query: "tag:work")))
        XCTAssertEqual(created.status, 201)
        let folder = try decode(SmartFolderDTO.self, created)
        XCTAssertEqual(folder.symbol, SmartFolder.defaultSymbol)

        let listed = try decode(SmartFoldersResponseDTO.self, await call("organise.smartFolderList", store))
        XCTAssertEqual(listed.smartFolders.map(\.id), [folder.id])
        let got = try decode(SmartFolderNotesDTO.self, await call("organise.smartFolderGet", store, params: ["id": folder.id.uuidString]))
        XCTAssertEqual(got.notes.map(\.id), [match])

        let updated = try decode(SmartFolderDTO.self, await call("organise.smartFolderUpdate", store, params: ["id": folder.id.uuidString],
                                                                 body: json(SmartFolderRequest(name: "Job"))))
        XCTAssertEqual(updated.name, "Job")
        XCTAssertEqual(updated.query, "tag:work")
        let empty = await call("organise.smartFolderUpdate", store, params: ["id": folder.id.uuidString],
                               body: json(SmartFolderRequest(query: " ")))
        XCTAssertEqual(errorCode(empty), "bad_request")

        let deleted = await call("organise.smartFolderDelete", store, params: ["id": folder.id.uuidString])
        XCTAssertEqual(deleted.status, 204)
        XCTAssertTrue(store.smartFolders.isEmpty)
        XCTAssertNotNil(store.note(with: match))
        let gone = await call("organise.smartFolderGet", store, params: ["id": folder.id.uuidString])
        XCTAssertEqual(errorCode(gone), "not_found")
    }

    func testTaskListCompleteAndDue() async throws {
        let store = makeStore()
        let id = add(store, "Errands\n☐\tbuy milk\n☑\tpost letter")
        let list = try decode(TasksResponseDTO.self, await call("organise.taskList", store))
        XCTAssertEqual(list.groups.map(\.group), ["noDate"])
        let task = try XCTUnwrap(list.groups.first?.tasks.first)
        XCTAssertEqual(task.text, "buy milk")
        XCTAssertEqual(task.noteID, id)
        let all = try decode(TasksResponseDTO.self, await call("organise.taskList", store, query: ["includeCompleted": "true"]))
        XCTAssertEqual(all.groups.map(\.group), ["noDate", "completed"])

        let due = try decode(TaskDTO.self, await call("organise.taskDue", store, body: json(TaskDueRequest(
            noteID: id, paragraph: task.paragraph, textHash: task.textHash, due: "2026-10-21T14:00"))))
        XCTAssertEqual(due.due, "2026-10-21 14:00")
        XCTAssertEqual(due.text, "buy milk")
        XCTAssertTrue(store.plainText(for: id).contains("buy milk @due(2026-10-21 14:00)"))

        let done = try decode(TaskDTO.self, await call("organise.taskComplete", store, body: json(TaskCompleteRequest(
            noteID: id, paragraph: due.paragraph, textHash: due.textHash, checked: true))))
        XCTAssertTrue(done.checked)

        let stale = await call("organise.taskComplete", store, body: json(TaskCompleteRequest(
            noteID: id, paragraph: task.paragraph, textHash: task.textHash, checked: false)))
        XCTAssertEqual(stale.status, 412)
        XCTAssertEqual(errorCode(stale), "revision_mismatch")
        let badDate = await call("organise.taskDue", store, body: json(TaskDueRequest(
            noteID: id, paragraph: done.paragraph, textHash: done.textHash, due: "tomorrow")))
        XCTAssertEqual(errorCode(badDate), "bad_request")
    }

    func testTaskInLockedNoteIsNoteLocked() async throws {
        let store = makeStore()
        let id = add(store, "Secret\n☐\tthing")
        let list = try decode(TasksResponseDTO.self, await call("organise.taskList", store))
        let task = try XCTUnwrap(list.groups.first?.tasks.first)
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        let response = await call("organise.taskComplete", store, body: json(TaskCompleteRequest(
            noteID: id, paragraph: task.paragraph, textHash: task.textHash, checked: true)))
        XCTAssertEqual(response.status, 423)
        XCTAssertEqual(errorCode(response), "note_locked")
    }
}
