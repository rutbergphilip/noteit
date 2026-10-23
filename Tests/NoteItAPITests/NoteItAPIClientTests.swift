import Foundation
@testable import NoteItAPI
import XCTest

private struct FakeResponder: LocalAPIResponder {
    func respond(_ context: LocalAPIContext) async -> HTTPResponse {
        switch context.route.spec.id {
        case RouteID.noteGet.rawValue:
            return .error(.notFound, "No note with that id.")
        case RouteID.noteDelete.rawValue:
            return HTTPResponse(status: 204)
        case RouteID.tags.rawValue:
            return .json([TagDTO(name: "home", noteCount: 2)])
        case RouteID.notePatch.rawValue:
            return HTTPResponse(status: 500, headers: HTTPHeaders(), body: Data("plain failure".utf8))
        default:
            return .json(["query": context.request.query["q"] ?? ""])
        }
    }
}

/// Answers every request with `204` and remembers its Authorization header.
private final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var authorization: [String: String?] = [:]
    private static let lock = NSLock()

    static func header(for host: String) -> String?? { lock.withLock { authorization[host] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.authorization[request.url?.host ?? ""] = .some(request.value(forHTTPHeaderField: "Authorization"))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class NoteItAPIClientTests: XCTestCase {
    func testTokenOnlyGoesToLoopback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        let recording = URLSession(configuration: configuration)
        defer { recording.invalidateAndCancel() }
        for base in ["http://example.com/v1", "http://127.0.0.1:47600/v1"] {
            let client = NoteItAPIClient(baseURL: URL(string: base)!, token: "nit_secret", session: recording)
            _ = try await client.sendRaw(.GET, "/tags", body: nil)
        }
        XCTAssertEqual(RecordingProtocol.header(for: "example.com"), .some(nil))
        XCTAssertEqual(RecordingProtocol.header(for: "127.0.0.1"), .some("Bearer nit_secret"))
        for (text, loopback) in [("http://localhost:1/v1", true), ("http://[::1]:1/v1", true), ("http://LOCALHOST/v1", true),
                                 ("http://127.0.0.2/v1", false), ("http://localhost.example.com/v1", false)] {
            XCTAssertEqual(NoteItAPIClient.isLoopback(URL(string: text)!), loopback, text)
        }
    }

    private var server: LocalHTTPServer?
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        server?.stop()
        server = nil
        session.invalidateAndCancel()
        super.tearDown()
    }

    private func start() async throws -> (ClientRegistry, ChangeHub, URL) {
        let clients = ClientRegistry(store: InMemoryClientStore())
        let hub = ChangeHub()
        let server = LocalHTTPServer(registry: clients, pairing: PairingBroker(registry: clients), changes: hub,
                                     limiter: RateLimiter(), responder: FakeResponder(),
                                     ping: { PingDTO(name: "NoteIt", apiVersion: 1, appVersion: "1.0", capabilities: []) },
                                     routeRegistry: LocalAPIRouteRegistry())
        self.server = server
        let port = try await server.start(ports: [0])
        return (clients, hub, URL(string: "http://127.0.0.1:\(port)/v1")!)
    }

    private func apiError(_ body: () async throws -> Void) async -> NoteItAPIError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? NoteItAPIError
        }
    }

    func testClientMapsErrors() async throws {
        let (clients, _, baseURL) = try await start()
        let anonymous = NoteItAPIClient(baseURL: baseURL, token: nil, session: session)
        let ping = try await anonymous.send(.GET, "/ping", as: PingDTO.self)
        XCTAssertEqual(ping.name, "NoteIt")

        let unauthorized = await apiError { _ = try await anonymous.send(.GET, "/tags", as: [TagDTO].self) }
        XCTAssertEqual(unauthorized?.status, 401)
        XCTAssertEqual(unauthorized?.code, .unauthorized)

        let (_, token) = try clients.issue(name: "Test", kind: .cli, scopes: [.write], origin: nil)
        let client = NoteItAPIClient(baseURL: baseURL, token: token, session: session)
        let tags = try await client.send(.GET, "/tags", as: [TagDTO].self)
        XCTAssertEqual(tags, [TagDTO(name: "home", noteCount: 2)])

        let id = UUID().uuidString
        let missing = await apiError { _ = try await client.send(.GET, "/notes/\(id)", as: NoteDTO.self) }
        XCTAssertEqual(missing, NoteItAPIError(status: 404, code: .notFound, message: "No note with that id."))

        let scope = await apiError { _ = try await client.send(.DELETE, "/trash", as: APINoContent.self) }
        XCTAssertEqual(scope?.status, 403)
        XCTAssertEqual(scope?.code, .forbiddenScope)

        let plain = await apiError {
            _ = try await client.send(.PATCH, "/notes/\(id)", json: PatchNoteRequest(title: "x"), as: NoteDTO.self)
        }
        XCTAssertEqual(plain, NoteItAPIError(status: 500, code: nil, message: "plain failure"))

        let deleted = try await client.send(.DELETE, "/notes/\(id)", as: APINoContent.self)
        XCTAssertEqual(deleted, APINoContent())

        let (status, data) = try await client.sendRaw(.GET, "/notes", query: ["q": "a+b c&d"], body: nil)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["query": "a+b c&d"])
    }

    func testEventsStreamParsing() async throws {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(": ping"))
        XCTAssertNil(parser.feed(""))
        XCTAssertNil(parser.feed("id: B:1"))
        XCTAssertNil(parser.feed("event: change"))
        XCTAssertNil(parser.feed("data: {\"a\":"))
        XCTAssertNil(parser.feed("data:1}"))
        XCTAssertEqual(parser.feed(""), SSEEvent(id: "B:1", type: "change", data: "{\"a\":\n1}"))
        XCTAssertNil(parser.feed("event: revoked"))
        XCTAssertEqual(parser.feed(""), SSEEvent(id: nil, type: "revoked", data: ""))

        let (clients, hub, baseURL) = try await start()
        let (record, token) = try clients.issue(name: "Test", kind: .cli, scopes: [.read], origin: nil)
        let client = NoteItAPIClient(baseURL: baseURL, token: token, session: session)
        let start = hub.currentCursor
        let first = UUID()
        hub.publish(kind: .note, id: first, op: .created, at: Date(timeIntervalSince1970: 1_000))
        var iterator = client.events(since: start).makeAsyncIterator()
        let change = try await iterator.next()
        XCTAssertEqual(change?.id, first)
        XCTAssertEqual(change?.op, .created)

        let second = UUID()
        hub.publish(kind: .notebook, id: second, op: .deleted, at: Date())
        let next = try await iterator.next()
        XCTAssertEqual(next?.id, second)
        XCTAssertEqual(next?.kind, .notebook)

        try clients.revoke(record.id)
        do {
            _ = try await iterator.next()
            XCTFail("expected the stream to end with token_revoked")
        } catch {
            XCTAssertEqual((error as? NoteItAPIError)?.code, .tokenRevoked)
        }
    }

    func testEventsReconnectOnceWithLastEventID() async throws {
        let change = ChangeDTO(cursor: "B:7", kind: .note, id: UUID(), op: .updated, at: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try APIJSON.encoder().encode(change), as: UTF8.self)
        let cursors = Locked<[String?]>([])
        let events = NoteItAPIClient.events(since: "B:5") { cursor in
            cursors.mutate { $0.append(cursor) }
            return AsyncThrowingStream { continuation in
                if cursors.value.count == 1 {
                    for line in ["id: B:7", "event: change", "data: \(json)", ""] { continuation.yield(line) }
                }
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
        }
        var received: [ChangeDTO] = []
        do {
            for try await change in events { received.append(change) }
            XCTFail("expected the second drop to end the stream")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(received, [change])
        XCTAssertEqual(cursors.value, ["B:5", "B:7"])
    }
}
