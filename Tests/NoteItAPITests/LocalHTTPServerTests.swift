import Darwin
import Foundation
@testable import NoteItAPI
import XCTest

private struct EchoResponder: LocalAPIResponder {
    func respond(_ context: LocalAPIContext) async -> HTTPResponse {
        .json(["route": context.route.spec.id])
    }
}

final class LocalHTTPServerTests: XCTestCase {
    private struct Harness {
        let clients: ClientRegistry
        let pairing: PairingBroker
        let hub: ChangeHub
        let server: LocalHTTPServer
        let port: UInt16

        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

        func token(_ scopes: [APIScope], origin: String? = nil) throws -> (ClientRecord, String) {
            let (record, token) = try clients.issue(name: "Test", kind: .script, scopes: scopes, origin: origin)
            return (record, token)
        }
    }

    private struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data

        var errorCode: String? {
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            return (object?["error"] as? [String: Any])?["code"] as? String
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    private var servers: [LocalHTTPServer] = []
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        session.invalidateAndCancel()
        super.tearDown()
    }

    private func start(rules: [RouteBucket: RateLimiter.Rule] = RateLimiter.defaults,
                       routes: LocalAPIRouteRegistry = LocalAPIRouteRegistry(),
                       ports: [UInt16] = [0]) async throws -> Harness {
        let clients = ClientRegistry(store: InMemoryClientStore())
        let pairing = PairingBroker(registry: clients)
        let hub = ChangeHub()
        let server = LocalHTTPServer(registry: clients, pairing: pairing, changes: hub, limiter: RateLimiter(rules: rules),
                                     responder: EchoResponder(),
                                     ping: { PingDTO(name: "NoteIt", apiVersion: 1, appVersion: "1.0", capabilities: ["keyword-search"]) },
                                     routeRegistry: routes)
        servers.append(server)
        let port = try await server.start(ports: ports)
        return Harness(clients: clients, pairing: pairing, hub: hub, server: server, port: port)
    }

    private func send(_ harness: Harness, _ method: String, _ path: String, token: String? = nil,
                      headers: [String: String] = [:], json: Any? = nil, body: Data? = nil) async throws -> Reply {
        var request = URLRequest(url: harness.url(path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let body { request.httpBody = body }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let fields = Dictionary(uniqueKeysWithValues: http.allHeaderFields.map { ("\($0.key)", "\($0.value)") })
        return Reply(status: http.statusCode, headers: fields, body: data)
    }

    private func ping(_ harness: Harness) async throws -> [String: Any] {
        let reply = try await send(harness, "GET", "/v1/ping")
        XCTAssertEqual(reply.status, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
    }

    // MARK: - Pipeline

    func testPingWithoutToken() async throws {
        let harness = try await start()
        let reply = try await send(harness, "GET", "/v1/ping")
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.header("Cache-Control"), "no-store")
        let ping = try APIJSON.decoder().decode(PingDTO.self, from: reply.body)
        XCTAssertEqual(ping.name, "NoteIt")
        XCTAssertEqual(ping.capabilities, ["keyword-search"])
        XCTAssertNil(reply.header("Access-Control-Allow-Origin"))
    }

    func testUnauthorizedWithoutToken() async throws {
        let harness = try await start()
        let missing = try await send(harness, "GET", "/v1/notes")
        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(missing.errorCode, "unauthorized")
        let wrong = try await send(harness, "GET", "/v1/notes", token: "nit_wrong")
        XCTAssertEqual(wrong.errorCode, "unauthorized")

        let (record, token) = try harness.token([.read])
        try harness.clients.revoke(record.id)
        let revoked = try await send(harness, "GET", "/v1/notes", token: token)
        XCTAssertEqual(revoked.status, 401)
        XCTAssertEqual(revoked.errorCode, "token_revoked")
    }

    func testScopeEnforced() async throws {
        let harness = try await start()
        let (_, token) = try harness.token([.read])
        let list = try await send(harness, "GET", "/v1/notes", token: token)
        XCTAssertEqual(list.status, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: list.body) as? [String: String], ["route": "notesList"])

        let create = try await send(harness, "POST", "/v1/notes", token: token, json: ["title": "x"])
        XCTAssertEqual(create.status, 403)
        XCTAssertEqual(create.errorCode, "forbidden_scope")
        let clients = try await send(harness, "GET", "/v1/clients", token: token)
        XCTAssertEqual(clients.errorCode, "forbidden_scope")

        let (_, admin) = try harness.token([.admin])
        let allowed = try await send(harness, "GET", "/v1/clients", token: admin)
        XCTAssertEqual(allowed.status, 200)
        XCTAssertEqual(try APIJSON.decoder().decode([ClientDTO].self, from: allowed.body).count, 2)

        let missingType = try await send(harness, "POST", "/v1/notes", token: admin, body: Data("{}".utf8))
        XCTAssertEqual(missingType.status, 415)
        let wrongMethod = try await send(harness, "PUT", "/v1/notes", token: admin)
        XCTAssertEqual(wrongMethod.status, 405)
        XCTAssertEqual(wrongMethod.header("Allow"), "GET, POST")
        let unknown = try await send(harness, "GET", "/v1/nothing", token: admin)
        XCTAssertEqual(unknown.status, 404)
    }

    func testWebOriginRejected() async throws {
        let harness = try await start()
        for origin in ["https://example.com", "null", "http://127.0.0.1:\(harness.port)"] {
            let reply = try await send(harness, "GET", "/v1/ping", headers: ["Origin": origin])
            XCTAssertEqual(reply.status, 403, origin)
            XCTAssertEqual(reply.errorCode, "origin_not_allowed", origin)
            XCTAssertNil(reply.header("Access-Control-Allow-Origin"), origin)
        }
    }

    func testExtensionPreflightAndCORS() async throws {
        let harness = try await start()
        let origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
        let preflight = try await send(harness, "OPTIONS", "/v1/notes",
                                       headers: ["Origin": origin, "Access-Control-Request-Method": "POST"])
        XCTAssertEqual(preflight.status, 204)
        XCTAssertEqual(preflight.header("Access-Control-Allow-Origin"), origin)
        XCTAssertNotNil(preflight.header("Access-Control-Allow-Methods"))

        let (_, token) = try harness.token([.read], origin: origin)
        let list = try await send(harness, "GET", "/v1/notes", token: token, headers: ["Origin": origin])
        XCTAssertEqual(list.status, 200)
        XCTAssertEqual(list.header("Access-Control-Allow-Origin"), origin)
        XCTAssertEqual(list.header("Vary"), "Origin")

        let denied = try await send(harness, "GET", "/v1/notes", token: token)
        XCTAssertEqual(denied.status, 401, "an extension token can't be used without its origin")
        XCTAssertNil(denied.header("Access-Control-Allow-Origin"))
        let other = try await send(harness, "GET", "/v1/notes", token: token,
                                   headers: ["Origin": "chrome-extension://ponmlkjihgfedcbaponmlkjihgfedcba"])
        XCTAssertEqual(other.status, 401)
        XCTAssertNotNil(other.header("Access-Control-Allow-Origin"), "errors carry CORS headers so the extension can read them")
    }

    func testHostHeaderRebindingRejected() async throws {
        let harness = try await start()
        let client = try XCTUnwrap(RawHTTPClient(port: harness.port))
        client.send("GET /v1/ping HTTP/1.1\r\nHost: evil.example\r\n\r\n")
        let response = client.readResponse()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 421"), response)
        XCTAssertTrue(response.contains("\"misdirected\""), response)
        XCTAssertTrue(client.isClosedByPeer())

        let good = try XCTUnwrap(RawHTTPClient(port: harness.port))
        good.send("GET /v1/ping HTTP/1.1\r\nHost: localhost:\(harness.port)\r\n\r\n")
        XCTAssertTrue(good.readResponse().hasPrefix("HTTP/1.1 200"))
    }

    /// Only the head is sent: each request must be refused from its head alone, without waiting for the body.
    func testHeadIsCheckedBeforeBodyIsRead() async throws {
        let harness = try await start()
        let host = "Host: 127.0.0.1:\(harness.port)"
        let json = "Content-Type: application/json"
        let cases: [(String, String, String)] = [
            ("POST /v1/notes HTTP/1.1\r\nHost: evil.example\r\n\(json)\r\nContent-Length: 50000000\r\n\r\n", "421", "misdirected"),
            ("POST /v1/notes HTTP/1.1\r\n\(host)\r\nOrigin: https://example.com\r\n\(json)\r\nContent-Length: 50000000\r\n\r\n",
             "403", "origin_not_allowed"),
            ("POST /v1/notes HTTP/1.1\r\n\(host)\r\n\(json)\r\nContent-Length: 3000000\r\n\r\n", "413", "too_large"),
            ("POST /v1/nothing HTTP/1.1\r\n\(host)\r\n\(json)\r\nContent-Length: 50000000\r\n\r\n", "404", "not_found"),
            ("PUT /v1/notes HTTP/1.1\r\n\(host)\r\n\(json)\r\nContent-Length: 50000000\r\n\r\n", "405", "bad_request"),
            ("POST /v1/notes HTTP/1.1\r\n\(host)\r\n\(json)\r\nContent-Length: 1000000\r\n\r\n", "401", "unauthorized"),
        ]
        for (head, status, code) in cases {
            let client = try XCTUnwrap(RawHTTPClient(port: harness.port))
            client.send(head)
            let response = client.readResponse()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 \(status)"), response)
            XCTAssertTrue(response.contains("\"\(code)\""), response)
            XCTAssertTrue(response.lowercased().contains("connection: close"), response)
            XCTAssertTrue(client.isClosedByPeer(), status)
        }
    }

    /// A client that writes its whole body before reading (like Python's urllib) must still get the early 4xx:
    /// the server drains the body instead of resetting the upload.
    func testEarlyRejectLingersWhileTheBodyArrives() async throws {
        let routes = LocalAPIRouteRegistry()
        routes.register(RouteSpec(id: "tasks.upload", method: .POST, pattern: "/v1/tasks/upload", scope: .write,
                                  body: .binary, bucket: .write, maxBodyBytes: 20_000_000, summary: "Upload")) { _ in
            HTTPResponse(status: 201)
        }
        let harness = try await start(routes: routes)
        let host = "Host: 127.0.0.1:\(harness.port)"
        let length = 8_000_000
        let body = Data(repeating: 0x61, count: length)
        let cases = [
            ("POST /v1/tasks/upload HTTP/1.1\r\n\(host)\r\nContent-Type: application/octet-stream\r\n", "401"),
            ("POST /v1/notes HTTP/1.1\r\n\(host)\r\nContent-Type: application/json\r\n", "413"),
        ]
        for (head, status) in cases {
            let client = try XCTUnwrap(RawHTTPClient(port: harness.port))
            client.send(head + "Content-Length: \(length)\r\n\r\n")
            XCTAssertNil(client.sendAll(body), "the upload was reset before the \(status) could be read")
            let response = client.readResponse()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 \(status)"), response)
            XCTAssertTrue(response.lowercased().contains("connection: close"), response)
            XCTAssertTrue(client.isClosedByPeer(), status)
        }
    }

    /// The client reads the early reject but neither sends its body nor closes: the linger must still end and free
    /// the slot (the FIN the client sees comes from the half-close, so EOF alone doesn't prove that).
    func testLingerTimeoutReleasesTheSlot() async throws {
        let harness = try await start()
        harness.server.lingerTimeout = 0.2
        let client = try XCTUnwrap(RawHTTPClient(port: harness.port))
        client.send("POST /v1/notes HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\nContent-Type: application/json\r\n"
                    + "Content-Length: 1000000\r\n\r\n")
        XCTAssertTrue(client.readResponse().hasPrefix("HTTP/1.1 401"))
        try await waitFor("the lingering connection is released") { harness.server.connectionCounts == (0, 0) }
        XCTAssertTrue(client.isResetOnWrite(), "the connection was torn down")
    }

    func testOverCapacityConnectionGets503ThenSlotsAreReleased() async throws {
        var rules = RateLimiter.defaults
        rules[.unauthenticated] = RateLimiter.Rule(perSecond: 1, burst: 100)
        let harness = try await start(rules: rules)
        harness.server.lingerTimeout = 0.2
        var open = try (0..<LocalHTTPServer.maxConnections).map { _ in try XCTUnwrap(RawHTTPClient(port: harness.port)) }
        try await waitFor("every slot is taken") { harness.server.connectionCounts.open == LocalHTTPServer.maxConnections }

        let extra = try XCTUnwrap(RawHTTPClient(port: harness.port))
        let response = extra.readResponse()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 503"), response)
        XCTAssertTrue(response.contains("\"rate_limited\""), response)
        XCTAssertTrue(response.contains("Retry-After: 1\r\n"), response)
        XCTAssertTrue(response.lowercased().contains("connection: close"), response)
        try await waitFor("the rejected connection's linger ends") { harness.server.connectionCounts.rejected == 0 }

        open.removeAll()
        try await waitFor("closed clients free their slots") { harness.server.connectionCounts == (0, 0) }
        let fresh = try (0..<LocalHTTPServer.maxConnections).map { _ in try XCTUnwrap(RawHTTPClient(port: harness.port)) }
        for client in fresh {
            client.send("GET /v1/ping HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\n\r\n")
            let reply = client.readResponse()
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), reply)
        }
    }

    /// `stop()` must tear down lingering early rejects and over-capacity `503`s at once, not after `lingerTimeout`.
    func testStopClosesLingeringAndRejectedConnections() async throws {
        let harness = try await start()
        harness.server.lingerTimeout = 60
        let open = try (0..<LocalHTTPServer.maxConnections).map { _ in try XCTUnwrap(RawHTTPClient(port: harness.port)) }
        try await waitFor("every slot is taken") { harness.server.connectionCounts.open == LocalHTTPServer.maxConnections }

        let lingering = open[0]
        lingering.send("POST /v1/notes HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\nContent-Type: application/json\r\n"
                       + "Content-Length: 1000000\r\n\r\n")
        XCTAssertTrue(lingering.readResponse().hasPrefix("HTTP/1.1 401"))
        XCTAssertTrue(lingering.isClosedByPeer(), "the write side is shut down")
        let rejected = try XCTUnwrap(RawHTTPClient(port: harness.port))
        XCTAssertTrue(rejected.readResponse().hasPrefix("HTTP/1.1 503"))
        XCTAssertTrue(rejected.isClosedByPeer(), "the write side is shut down")
        XCTAssertFalse(lingering.isResetOnWrite(timeout: 0.2), "still lingering before stop")
        XCTAssertTrue(harness.server.connectionCounts == (LocalHTTPServer.maxConnections, 1))

        harness.server.stop()
        XCTAssertTrue(harness.server.connectionCounts == (0, 0))
        XCTAssertTrue(lingering.isResetOnWrite(), "the lingering connection was torn down")
        XCTAssertTrue(rejected.isResetOnWrite(), "the rejected connection was torn down")
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting: \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testAdmittedHeadThenBodyIsHandledOnce() async throws {
        let harness = try await start(rules: [.general: .init(perSecond: 0.001, burst: 1),
                                              .write: .init(perSecond: 0.001, burst: 1)])
        let (_, token) = try harness.token([.write])
        let body = #"{"title":"x"}"#
        let client = try XCTUnwrap(RawHTTPClient(port: harness.port))
        client.send("POST /v1/notes HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\nAuthorization: Bearer \(token)\r\n"
                    + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n")
        try await Task.sleep(nanoseconds: 100_000_000)
        client.send(body)
        let response = client.readResponse()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
        XCTAssertTrue(response.contains("noteCreate"), response)
    }

    func testRateLimited429WithRetryAfter() async throws {
        var rules = RateLimiter.defaults
        rules[.unauthenticated] = RateLimiter.Rule(perSecond: 0.01, burst: 2)
        let harness = try await start(rules: rules)
        _ = try await ping(harness)
        _ = try await ping(harness)
        let limited = try await send(harness, "GET", "/v1/ping")
        XCTAssertEqual(limited.status, 429)
        XCTAssertEqual(limited.errorCode, "rate_limited")
        XCTAssertGreaterThanOrEqual(Int(limited.header("Retry-After") ?? "") ?? 0, 1)

        // Authenticated clients use their own buckets.
        let (_, token) = try harness.token([.read])
        let list = try await send(harness, "GET", "/v1/notes", token: token)
        XCTAssertEqual(list.status, 200)
    }

    func testKeepAliveTwoRequestsOneConnection() async throws {
        let harness = try await start()
        let client = try XCTUnwrap(RawHTTPClient(port: harness.port))
        let request = "GET /v1/ping HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\n\r\n"
        client.send(request)
        let first = client.readResponse()
        XCTAssertTrue(first.hasPrefix("HTTP/1.1 200"), first)
        XCTAssertTrue(first.lowercased().contains("connection: keep-alive"), first)
        client.send(request + request)
        XCTAssertTrue(client.readResponse().hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(client.readResponse().hasPrefix("HTTP/1.1 200"), "pipelined requests are answered in order")

        client.send("GET /v1/ping HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(client.readResponse().hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(client.isClosedByPeer())
    }

    func testPairingEndToEnd() async throws {
        let harness = try await start()
        let events = Locked<[PairingEvent]>([])
        harness.pairing.onEvent = { event in events.mutate { $0.append(event) } }

        let start = try await send(harness, "POST", "/v1/pair/start",
                                   json: ["clientName": "My Script", "kind": "script", "scopes": ["read", "write"]])
        XCTAssertEqual(start.status, 200)
        let started = try APIJSON.decoder().decode(PairStartResponse.self, from: start.body)
        let code = try XCTUnwrap(harness.pairing.current?.code)
        XCTAssertEqual(harness.pairing.current?.clientName, "My Script")

        let busy = try await send(harness, "POST", "/v1/pair/start",
                                  json: ["clientName": "Other", "kind": "cli", "scopes": ["read"]])
        XCTAssertEqual(busy.errorCode, "pairing_in_progress")
        let malformed = try await send(harness, "POST", "/v1/pair/complete", json: ["pairingID": "nope"])
        XCTAssertEqual(malformed.status, 400)

        let complete = try await send(harness, "POST", "/v1/pair/complete",
                                      json: ["pairingID": started.pairingID.uuidString, "code": code])
        XCTAssertEqual(complete.status, 200)
        let paired = try APIJSON.decoder().decode(PairCompleteResponse.self, from: complete.body)
        XCTAssertEqual(paired.scopes, [.read, .write])

        let me = try await send(harness, "GET", "/v1/me", token: paired.token)
        XCTAssertEqual(me.status, 200)
        let client = try APIJSON.decoder().decode(ClientDTO.self, from: me.body)
        XCTAssertEqual(client.id, paired.clientID)
        XCTAssertEqual(client.name, "My Script")
        XCTAssertEqual(events.value.last, .finished(started.pairingID, success: true))

        let delete = try await send(harness, "DELETE", "/v1/me", token: paired.token)
        XCTAssertEqual(delete.status, 204)
        let after = try await send(harness, "GET", "/v1/me", token: paired.token)
        XCTAssertEqual(after.errorCode, "token_revoked")
    }

    func testEventsStreamDeliversAndRevokes() async throws {
        let harness = try await start()
        let (record, token) = try harness.token([.read])
        let first = UUID(), second = UUID(), third = UUID()
        let start = harness.hub.currentCursor
        harness.hub.publish(kind: .note, id: first, op: .created, at: Date())
        harness.hub.publish(kind: .note, id: second, op: .updated, at: Date())
        guard case .success(let page) = harness.hub.changes(since: start, limit: 10), page.changes.count == 2 else {
            return XCTFail("changes")
        }
        let afterFirst = page.changes[0].cursor

        let polled = try await send(harness, "GET", "/v1/changes?since=\(afterFirst)", token: token)
        XCTAssertEqual(try APIJSON.decoder().decode(ChangesPage.self, from: polled.body).changes.map(\.id), [second])

        let client = try XCTUnwrap(RawHTTPClient(port: harness.port))
        client.send("GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\nAuthorization: Bearer \(token)\r\n"
            + "Last-Event-ID: \(afterFirst)\r\n\r\n")
        let backlog = client.read(containing: second.uuidString)
        XCTAssertTrue(backlog.hasPrefix("HTTP/1.1 200"), backlog)
        XCTAssertTrue(backlog.contains("Content-Type: text/event-stream"), backlog)
        XCTAssertTrue(backlog.contains("Cache-Control: no-store"), backlog)
        XCTAssertFalse(backlog.lowercased().contains("content-length"), backlog)
        XCTAssertTrue(backlog.contains("id: \(page.changes[1].cursor)\nevent: change\ndata: {"), backlog)
        XCTAssertFalse(backlog.contains(first.uuidString), backlog)

        harness.hub.publish(kind: .notebook, id: third, op: .deleted, at: Date())
        let live = client.read(containing: third.uuidString)
        XCTAssertTrue(live.contains("event: change"), live)

        try harness.clients.revoke(record.id)
        XCTAssertTrue(client.read(containing: "event: revoked").contains("event: revoked\ndata: {}\n\n"))
        XCTAssertTrue(client.isClosedByPeer())
    }

    func testStopClosesConnections() async throws {
        let harness = try await start()
        let client = try XCTUnwrap(RawHTTPClient(port: harness.port))
        client.send("GET /v1/ping HTTP/1.1\r\nHost: 127.0.0.1:\(harness.port)\r\n\r\n")
        XCTAssertTrue(client.readResponse().hasPrefix("HTTP/1.1 200"))

        harness.server.stop()
        XCTAssertTrue(client.isClosedByPeer())
        XCTAssertNil(RawHTTPClient(port: harness.port), "nothing listens after stop")
    }

    func testStopDuringStartLeavesNothingListening() async throws {
        let probe = try await start()
        let port = probe.port
        probe.server.stop()

        let clients = ClientRegistry(store: InMemoryClientStore())
        let server = LocalHTTPServer(registry: clients, pairing: PairingBroker(registry: clients), changes: ChangeHub(),
                                     limiter: RateLimiter(), responder: EchoResponder(),
                                     ping: { PingDTO(name: "NoteIt", apiVersion: 1, appVersion: "1", capabilities: []) },
                                     routeRegistry: LocalAPIRouteRegistry())
        servers.append(server)
        server.listenerStarted = { [unowned server] in server.stop() }
        do {
            _ = try await server.start(ports: [port])
            XCTFail("stop() should cancel the pending start")
        } catch {
            XCTAssertEqual(error as? LocalHTTPServerError, .stopped)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(RawHTTPClient(port: port, timeout: 1), "nothing listens after stop")

        server.listenerStarted = nil
        let restarted = try await server.start(ports: [port])
        XCTAssertEqual(restarted, port)
    }

    func testConcurrentStartIsRejected() async throws {
        let clients = ClientRegistry(store: InMemoryClientStore())
        let server = LocalHTTPServer(registry: clients, pairing: PairingBroker(registry: clients), changes: ChangeHub(),
                                     limiter: RateLimiter(), responder: EchoResponder(),
                                     ping: { PingDTO(name: "NoteIt", apiVersion: 1, appVersion: "1", capabilities: []) },
                                     routeRegistry: LocalAPIRouteRegistry())
        servers.append(server)
        let second = Locked<Task<UInt16, Error>?>(nil)
        server.listenerStarted = { [unowned server] in
            server.listenerStarted = nil
            second.mutate { $0 = Task { try await server.start(ports: [0]) } }
        }
        let port = try await server.start(ports: [0])
        XCTAssertNotEqual(port, 0)
        do {
            _ = try await XCTUnwrap(second.value).value
            XCTFail("the second start should fail")
        } catch {
            XCTAssertEqual(error as? LocalHTTPServerError, .alreadyRunning)
        }
        await assertSecondStartFails(server)
        XCTAssertNotNil(RawHTTPClient(port: port))
    }

    private func assertSecondStartFails(_ server: LocalHTTPServer) async {
        do {
            _ = try await server.start(ports: [0])
            XCTFail("already running")
        } catch {
            XCTAssertEqual(error as? LocalHTTPServerError, .alreadyRunning)
        }
    }

    func testPortFallbackSkipsBusyPort() async throws {
        let busy = try await start()
        let second = try await start(ports: [busy.port, 0])
        XCTAssertNotEqual(second.port, busy.port)
        XCTAssertNotEqual(second.port, 0)
        _ = try await ping(second)

        let clients = ClientRegistry(store: InMemoryClientStore())
        let pinned = LocalHTTPServer(registry: clients, pairing: PairingBroker(registry: clients), changes: ChangeHub(),
                                     limiter: RateLimiter(), responder: EchoResponder(),
                                     ping: { PingDTO(name: "NoteIt", apiVersion: 1, appVersion: "1", capabilities: []) },
                                     routeRegistry: LocalAPIRouteRegistry())
        servers.append(pinned)
        do {
            _ = try await pinned.start(ports: [busy.port])
            XCTFail("the port is taken")
        } catch {
            XCTAssertEqual(error as? LocalHTTPServerError, .portInUse(busy.port))
        }
    }

    func testBindsOnlyLoopback() async throws {
        let harness = try await start()
        guard let address = Self.nonLoopbackIPv4() else { throw XCTSkip("This Mac has no non-loopback IPv4 address.") }
        XCTAssertNil(RawHTTPClient(host: address, port: harness.port, timeout: 2), "reachable on \(address)")
        XCTAssertNotNil(RawHTTPClient(port: harness.port))
    }

    // MARK: - Registered routes

    func testRegisteredRouteUsesPipelineAndBodyLimit() async throws {
        let routes = LocalAPIRouteRegistry()
        routes.register(RouteSpec(id: "tasks.add", method: .POST, pattern: "/v1/tasks/{list}", scope: .write, body: .json,
                                  bucket: .write, maxBodyBytes: 100, summary: "Add a task")) { context in
            var response = HTTPResponse.json(["list": context.route.params["list"] ?? "", "client": context.client?.name ?? ""])
            response.status = 201
            return response
        }
        let harness = try await start(routes: routes)
        let anonymous = try await send(harness, "POST", "/v1/tasks/home", json: ["t": "x"])
        XCTAssertEqual(anonymous.status, 401)
        let (_, reader) = try harness.token([.read])
        let read = try await send(harness, "POST", "/v1/tasks/home", token: reader, json: ["t": "x"])
        XCTAssertEqual(read.errorCode, "forbidden_scope")

        let (_, writer) = try harness.token([.write])
        let created = try await send(harness, "POST", "/v1/tasks/home", token: writer, json: ["t": "x"])
        XCTAssertEqual(created.status, 201)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: created.body) as? [String: String],
                       ["list": "home", "client": "Test"])
        let large = try await send(harness, "POST", "/v1/tasks/home", token: writer, json: ["t": String(repeating: "x", count: 200)])
        XCTAssertEqual(large.status, 413)
        XCTAssertEqual(large.errorCode, "too_large")
        let plain = try await send(harness, "POST", "/v1/tasks/home", token: writer, body: Data("{}".utf8))
        XCTAssertEqual(plain.status, 415)
    }

    func testRegisteringConflictingRouteTraps() {
        let routes = nonTrappingRegistry()
        routes.register(RouteSpec(id: "tasks.notes", method: .GET, pattern: "/v1/notes", scope: .read, body: .none,
                                  bucket: .general, maxBodyBytes: nil, summary: "Clash")) { _ in HTTPResponse(status: 200) }
        XCTAssertEqual(routes.validate().count, 1)
        XCTAssertTrue(routes.validate()[0].contains("notesList"), routes.validate()[0])
    }

    func testRouteIdMustBeSlugDotName() {
        let routes = nonTrappingRegistry()
        for id in ["tasks", "Tasks.list", "tasks.", ".list"] {
            routes.register(RouteSpec(id: id, method: .GET, pattern: "/v1/tasks-\(routes.routes.count)", scope: .read,
                                      body: .none, bucket: .general, maxBodyBytes: nil, summary: "Bad")) { _ in HTTPResponse(status: 200) }
        }
        XCTAssertEqual(routes.validate().count, 4, routes.validate().joined(separator: "\n"))
    }

    func testRegisteredSearchModeAndCapability() async throws {
        let routes = LocalAPIRouteRegistry()
        routes.registerSearchMode("meaning") { _, _ in .success([]) }
        routes.addCapability("semantic-search")
        let harness = try await start(routes: routes)

        let before = try await ping(harness)
        XCTAssertEqual(before["capabilities"] as? [String], ["keyword-search", "semantic-search"])
        let openapi = try await send(harness, "GET", "/v1/openapi.json")
        XCTAssertEqual(openapi.status, 200)
        XCTAssertTrue(String(decoding: openapi.body, as: UTF8.self).contains("\"meaning\""))

        routes.removeCapability("semantic-search")
        let after = try await ping(harness)
        XCTAssertEqual(after["capabilities"] as? [String], ["keyword-search"])
    }

    func testPingHasCapabilitiesNotFeatures() async throws {
        let harness = try await start()
        let ping = try await ping(harness)
        XCTAssertNotNil(ping["capabilities"])
        XCTAssertNil(ping["features"])
        XCTAssertEqual(Set(ping.keys), ["name", "apiVersion", "appVersion", "capabilities"])
    }

    func testSafariWithoutBundleHeaderIs400OnPairing() async throws {
        let harness = try await start()
        let origin = "safari-web-extension://3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let body: [String: Any] = ["clientName": "Clipper", "kind": "extension", "scopes": ["read", "write", "admin"]]
        let missing = try await send(harness, "POST", "/v1/pair/start", headers: ["Origin": origin], json: body)
        XCTAssertEqual(missing.status, 400)
        XCTAssertEqual(missing.errorCode, "bad_request")
        XCTAssertEqual(missing.header("Access-Control-Allow-Origin"), origin)

        let started = try await send(harness, "POST", "/v1/pair/start",
                                     headers: ["Origin": origin, "X-NoteIt-Extension-Bundle": "com.example.Clipper.Extension"],
                                     json: body)
        XCTAssertEqual(started.status, 200)
        XCTAssertEqual(harness.pairing.current?.origin, "safari-web-extension:com.example.Clipper.Extension")
        XCTAssertEqual(harness.pairing.current?.requestedScopes, [.read, .write], "extensions are capped at write")
    }

    // MARK: - Helpers

    private static func nonLoopbackIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }
}
