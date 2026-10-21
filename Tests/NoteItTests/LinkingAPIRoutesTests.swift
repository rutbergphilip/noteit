import AppKit
import XCTest
@testable import NoteIt
import NoteItAPI
import NoteItCore

@MainActor
final class LinkingAPIRoutesTests: XCTestCase {
    private var root: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-linkingapi-\(UUID().uuidString)", isDirectory: true)
        suiteName = "noteit-linkingapi-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        RichTextEditor.pendingCaret.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> NoteStore {
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        store.preferences = defaults
        store.installLinkIndex()
        return store
    }

    private func body(_ title: String, linking links: [(String, NoteLink)] = [], rest: String = "") -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + "\n", attributes: EditorStyle.bodyAttributes)
        for (shown, link) in links {
            text.append(NSAttributedString(string: "see "))
            text.append(NSAttributedString(string: shown, attributes: [.link: link.url]))
            text.append(NSAttributedString(string: ". "))
        }
        text.append(NSAttributedString(string: rest))
        return text
    }

    private func call(_ routeID: String, _ store: NoteStore, params: [String: String] = [:], body: Data = Data()) -> HTTPResponse {
        let spec = LinkingAPIRoutes.routes.first { $0.id == routeID }!
        let request = HTTPRequest(method: spec.method.rawValue, path: spec.pattern, body: body)
        let context = LocalAPIContext(request: request, route: RouteMatch(spec: spec, params: params), client: nil, origin: .native)
        return LinkingAPIRoutes.respond(routeID, context, store: store)
    }

    private func errorCode(_ response: HTTPResponse) -> String? {
        (try? APIJSON.decoder().decode(APIErrorBody.self, from: response.body))?.error.code.rawValue
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testRouteIDsUseLinkingPrefix() {
        let registry = LocalAPIRouteRegistry()
        LinkingAPIRoutes.register(in: registry, store: makeStore())
        XCTAssertEqual(registry.routes.map(\.id), ["linking.backlinks", "linking.links", "linking.outline", "linking.templates",
                                                   "linking.createFromTemplate"])
        XCTAssertEqual(registry.validate(), [])
    }

    func testScopes() {
        let byID = Dictionary(uniqueKeysWithValues: LinkingAPIRoutes.routes.map { ($0.id, $0) })
        for id in ["linking.backlinks", "linking.links", "linking.outline", "linking.templates"] {
            XCTAssertEqual(byID[id]?.scope, .read, id)
            XCTAssertEqual(byID[id]?.bucket, .general, id)
        }
        XCTAssertEqual(byID["linking.createFromTemplate"]?.scope, .write)
        XCTAssertEqual(byID["linking.createFromTemplate"]?.bucket, .write)
    }

    func testBacklinksShape() async throws {
        let store = makeStore()
        let target = store.createNote(in: nil, initial: body("Atlas")).id
        let source = store.createNote(in: nil, initial: body("Plan", linking: [("Atlas", .note(id: target, heading: nil))])).id
        await waitUntil { !store.backlinks(to: target).isEmpty }
        let response = call("linking.backlinks", store, params: ["id": target.uuidString])
        XCTAssertEqual(response.status, 200)
        let items = try APIJSON.decoder().decode(LinkingAPIRoutes.Items<LinkingAPIRoutes.BacklinkDTO>.self, from: response.body).items
        XCTAssertEqual(items.map(\.noteID), [source])
        XCTAssertEqual(items.first?.url, "noteit://note/\(source.uuidString)")
        XCTAssertEqual(items.first?.links.first?.url, "noteit://note/\(target.uuidString)")
        XCTAssertEqual(items.first?.links.first?.text, "Atlas")

        let links = call("linking.links", store, params: ["id": source.uuidString])
        let outgoing = try APIJSON.decoder().decode(LinkingAPIRoutes.Items<LinkingAPIRoutes.LinkDTO>.self, from: links.body).items
        XCTAssertEqual(outgoing.map(\.noteID), [target])

        XCTAssertEqual(errorCode(call("linking.backlinks", store, params: ["id": UUID().uuidString])), "not_found")
        XCTAssertEqual(call("linking.backlinks", store, params: ["id": "nope"]).status, 404)
        _ = store.moveToRecentlyDeleted([target])
        XCTAssertEqual(errorCode(call("linking.backlinks", store, params: ["id": target.uuidString])), "note_deleted")
    }

    func testOutlineShape() throws {
        let store = makeStore()
        let text = NSMutableAttributedString(string: "Trip\n", attributes: EditorStyle.attributes(for: .title))
        text.append(NSAttributedString(string: "Packing\n", attributes: EditorStyle.attributes(for: .heading)))
        text.append(NSAttributedString(string: "Socks\n", attributes: EditorStyle.bodyAttributes))
        let id = store.createNote(in: nil, initial: text).id
        let response = call("linking.outline", store, params: ["id": id.uuidString])
        XCTAssertEqual(response.status, 200)
        let items = try APIJSON.decoder().decode(LinkingAPIRoutes.Items<LinkingAPIRoutes.OutlineItemDTO>.self, from: response.body).items
        XCTAssertEqual(items.map(\.text), ["Trip", "Packing"])
        XCTAssertEqual(items.map(\.level), [0, 1])
        XCTAssertEqual(items.first?.url, "noteit://note/\(id.uuidString)")
        XCTAssertEqual(items.last?.url, NoteLink.note(id: id, heading: "Packing").url.absoluteString)
    }

    func testOutlineURLsForLongHeadingsCanBeFollowed() throws {
        let store = makeStore()
        let long = String(repeating: "Heading words ", count: 12)
        let text = NSMutableAttributedString(string: "Trip\n", attributes: EditorStyle.attributes(for: .title))
        text.append(NSAttributedString(string: long + "\n", attributes: EditorStyle.attributes(for: .heading)))
        let id = store.createNote(in: nil, initial: text).id
        let response = call("linking.outline", store, params: ["id": id.uuidString])
        let items = try APIJSON.decoder().decode(LinkingAPIRoutes.Items<LinkingAPIRoutes.OutlineItemDTO>.self, from: response.body).items
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(items.last?.url)))
        let link = try XCTUnwrap(NoteLink(url: url))
        XCTAssertEqual(link.heading?.count, NoteLink.maxTextLength)
        let heading = try XCTUnwrap(link.heading)
        XCTAssertEqual(URLSchemeHandler.headingLocation(heading, in: store.body(for: id)), 5)
        RichTextEditor.pendingCaret[id] = nil
        defer { RichTextEditor.pendingCaret[id] = nil }
        store.navigate(to: id, heading: heading)
        XCTAssertEqual(RichTextEditor.pendingCaret[id], 5)
        XCTAssertNil(store.headingLocation(String(heading.dropLast(5)), in: id), "only a cut-off heading matches its start")
    }

    func testLockedNoteReturns423() {
        let store = makeStore()
        let id = store.createNote(in: nil, initial: body("Secret", rest: "hidden words")).id
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        store.refreshDerivedIndexes(for: id)
        for route in ["linking.backlinks", "linking.links", "linking.outline"] {
            let response = call(route, store, params: ["id": id.uuidString])
            XCTAssertEqual(response.status, 423, route)
            XCTAssertEqual(errorCode(response), "note_locked", route)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("hidden"), route)
        }
    }

    func testCreateFromTemplateNeedsWrite() async throws {
        let store = makeStore()
        let template = store.createTemplate()
        store.updateBody(template.id, body("{{title}}", rest: "Agenda"))
        let registry = LocalAPIRouteRegistry()
        LinkingAPIRoutes.register(in: registry, store: store)
        let clients = ClientRegistry(store: InMemoryClientStore())
        let server = LocalHTTPServer(registry: clients, pairing: PairingBroker(registry: clients), changes: ChangeHub(),
                                     limiter: RateLimiter(), responder: NotFoundResponder(),
                                     ping: { PingDTO(name: "NoteIt", apiVersion: 1, appVersion: "1", capabilities: []) },
                                     routeRegistry: registry)
        let port = try await server.start(ports: [0])
        defer { server.stop() }
        let (_, readToken) = try clients.issue(name: "Read", kind: .cli, scopes: [.read], origin: nil)
        let (_, writeToken) = try clients.issue(name: "Write", kind: .cli, scopes: [.write], origin: nil)

        func post(_ token: String) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/templates/\(template.id.uuidString)/notes")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"title":"Standup"}"#.utf8)
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        let (readStatus, readBody) = try await post(readToken)
        XCTAssertEqual(readStatus, 403)
        XCTAssertEqual(try APIJSON.decoder().decode(APIErrorBody.self, from: readBody).error.code, .forbiddenScope)
        let count = store.notes.count
        let (status, data) = try await post(writeToken)
        XCTAssertEqual(status, 201)
        let created = try APIJSON.decoder().decode(NoteSummaryDTO.self, from: data)
        XCTAssertEqual(created.title, "Standup")
        XCTAssertEqual(store.notes.count, count + 1)
        XCTAssertEqual(store.body(for: created.id).string, "Standup\nAgenda")
        XCTAssertNotEqual(store.note(with: created.id)?.notebookID, store.templatesNotebookIDIfSet)

        let templates = call("linking.templates", store)
        let listed = try APIJSON.decoder().decode(LinkingAPIRoutes.Items<LinkingAPIRoutes.TemplateDTO>.self, from: templates.body).items
        XCTAssertEqual(listed.map(\.id), [template.id])
    }

    func testUnknownTemplate404() {
        let store = makeStore()
        let plain = store.createNote(in: nil, initial: body("Not a template")).id
        for id in [UUID().uuidString, plain.uuidString, "x"] {
            let response = call("linking.createFromTemplate", store, params: ["id": id])
            XCTAssertEqual(response.status, 404, id)
            XCTAssertEqual(errorCode(response), "not_found", id)
        }
        let template = store.createTemplate()
        let response = call("linking.createFromTemplate", store, params: ["id": template.id.uuidString],
                            body: Data(#"{"notebookID":"\#(UUID().uuidString)"}"#.utf8))
        XCTAssertEqual(errorCode(response), "not_found")
    }
}

private struct NotFoundResponder: LocalAPIResponder {
    func respond(_ context: LocalAPIContext) async -> HTTPResponse { .error(.notFound, "Not found.") }
}
