import Foundation
import NoteItAPI
import XCTest

final class RequestPolicyTests: XCTestCase {
    private let policy = RequestPolicy(port: 47600)

    private func request(_ method: String = "GET", headers: [(String, String)]) -> HTTPRequest {
        HTTPRequest(method: method, path: "/v1/notes", headers: HTTPHeaders(headers))
    }

    private func record(origin: String?) -> ClientRecord {
        ClientRecord(id: UUID(), name: "Client", kind: origin == nil ? .cli : .extension, scopes: [.read],
                     origin: origin, tokenHash: "", tokenHint: "", createdAt: Date())
    }

    private func route(_ id: RouteID) -> RouteSpec { APIRoutes.all.first { $0.id == id.rawValue }! }

    func testHostAcceptsLoopbackForms() {
        for host in ["127.0.0.1:47600", "localhost:47600", "LocalHost:47600"] {
            XCTAssertTrue(policy.checkHost(request(headers: [("Host", host)])), host)
        }
    }

    func testHostRejectsOthers() {
        for host in ["evil.com:47600", "127.0.0.1:1", "127.0.0.1", "localhost", "[::1]:47600", "127.0.0.1:47600.evil.com", ""] {
            XCTAssertFalse(policy.checkHost(request(headers: [("Host", host)])), host)
        }
        XCTAssertFalse(policy.checkHost(request(headers: [])))
    }

    func testOriginClassification() {
        let table: [(String?, OriginDecision)] = [
            (nil, .native),
            ("chrome-extension://abcdefghijklmnop", .extensionOrigin("chrome-extension://abcdefghijklmnop")),
            ("moz-extension://1b2c3d4e-0000-4000-8000-123456789abc",
             .extensionOrigin("moz-extension://1b2c3d4e-0000-4000-8000-123456789abc")),
            ("safari-web-extension://ABCD-1234", .extensionOrigin("safari-web-extension://ABCD-1234")),
            ("chrome-extension://", .rejected),
            ("null", .rejected),
            ("https://example.com", .rejected),
            ("http://127.0.0.1:47600", .rejected),
            ("file://", .rejected),
            ("chrome-extension://abc/path", .rejected),
        ]
        XCTAssertEqual(table.count, 10)
        for (origin, expected) in table {
            let headers = origin.map { [("Origin", $0)] } ?? []
            XCTAssertEqual(policy.classifyOrigin(request(headers: headers)), expected, origin ?? "nil")
        }
    }

    func testPreflightEchoesOriginAndVary() throws {
        let origin = "chrome-extension://abcdefghijklmnop"
        let response = try XCTUnwrap(policy.preflight(request("OPTIONS", headers: [("Origin", origin)])))
        XCTAssertEqual(response.status, 204)
        XCTAssertEqual(response.headers["Access-Control-Allow-Origin"], origin)
        XCTAssertEqual(response.headers["Vary"], "Origin")
        XCTAssertEqual(response.headers["Access-Control-Allow-Methods"], "GET, POST, PATCH, DELETE")
        XCTAssertEqual(response.headers["Access-Control-Allow-Headers"],
                       "Authorization, Content-Type, If-Match, X-NoteIt-Filename, X-NoteIt-Extension-Bundle")
        XCTAssertEqual(response.headers["Access-Control-Max-Age"], "600")
        XCTAssertNil(response.headers["Access-Control-Allow-Credentials"])
        XCTAssertNil(policy.preflight(request("GET", headers: [("Origin", origin)])))
        XCTAssertEqual(policy.corsHeaders(for: .extensionOrigin(origin)),
                       HTTPHeaders([("Access-Control-Allow-Origin", origin), ("Vary", "Origin")]))
    }

    func testPreflightRejectedForWebOrigin() {
        XCTAssertNil(policy.preflight(request("OPTIONS", headers: [("Origin", "https://example.com")])))
        XCTAssertNil(policy.preflight(request("OPTIONS", headers: [("Origin", "null")])))
        XCTAssertNil(policy.preflight(request("OPTIONS", headers: [])))
        XCTAssertTrue(policy.corsHeaders(for: .rejected).pairs.isEmpty)
        XCTAssertTrue(policy.corsHeaders(for: .native).pairs.isEmpty)
    }

    func testJSONRouteNeedsJSONContentType() {
        let create = route(.noteCreate)
        XCTAssertNil(policy.checkContentType(request("POST", headers: [("Content-Type", "application/json")]), route: create))
        XCTAssertNil(policy.checkContentType(request("POST", headers: [("Content-Type", "Application/JSON; charset=utf-8")]),
                                             route: create))
        XCTAssertEqual(policy.checkContentType(request("POST", headers: [("Content-Type", "text/plain")]), route: create),
                       .unsupportedMediaType)
        XCTAssertEqual(policy.checkContentType(request("POST", headers: []), route: create), .unsupportedMediaType)
        XCTAssertNil(policy.checkContentType(request("POST", headers: [("Content-Type", "image/png")]),
                                             route: route(.attachmentAdd)))
        XCTAssertNil(policy.checkContentType(request(headers: []), route: route(.notesList)))
    }

    func testOriginBinding() {
        let origin = "chrome-extension://abcdefghijklmnop"
        let bound = record(origin: origin)
        XCTAssertTrue(RequestPolicy.originBindingAllows(record: bound, decision: .extensionOrigin(origin), extensionBundle: nil))
        XCTAssertTrue(RequestPolicy.originBindingAllows(record: bound, decision: .extensionOrigin(origin),
                                                        extensionBundle: "com.example.ignored"))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: bound, decision: .extensionOrigin("chrome-extension://other"),
                                                         extensionBundle: nil))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: bound, decision: .native, extensionBundle: nil))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: bound, decision: .rejected, extensionBundle: nil))

        let native = record(origin: nil)
        XCTAssertTrue(RequestPolicy.originBindingAllows(record: native, decision: .native, extensionBundle: nil))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: native, decision: .extensionOrigin(origin), extensionBundle: nil))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: native, decision: .rejected, extensionBundle: nil))
    }

    func testSafariBindingIsSchemePlusBundleID() {
        let safari = record(origin: "safari-web-extension:io.github.rutbergphilip.noteit.clipper")
        let newHost = OriginDecision.extensionOrigin("safari-web-extension://NEW-HOST-5678")
        XCTAssertTrue(RequestPolicy.originBindingAllows(record: safari, decision: newHost,
                                                        extensionBundle: "io.github.rutbergphilip.noteit.clipper"))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: safari, decision: newHost, extensionBundle: "com.evil.clipper"))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: safari, decision: newHost, extensionBundle: nil))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: safari, decision: .extensionOrigin("chrome-extension://abcd"),
                                                         extensionBundle: "io.github.rutbergphilip.noteit.clipper"))
        XCTAssertFalse(RequestPolicy.originBindingAllows(record: safari, decision: .native,
                                                         extensionBundle: "io.github.rutbergphilip.noteit.clipper"))
    }

    func testStoredOriginForSafariNeedsBundle() {
        let safari = OriginDecision.extensionOrigin("safari-web-extension://ABCD")
        XCTAssertEqual(RequestPolicy.storedOrigin(for: safari, extensionBundle: "io.github.example.clipper"),
                       .success("safari-web-extension:io.github.example.clipper"))
        XCTAssertEqual(RequestPolicy.storedOrigin(for: safari, extensionBundle: nil), .failure(.badRequest))
        XCTAssertEqual(RequestPolicy.storedOrigin(for: safari, extensionBundle: "not a bundle"), .failure(.badRequest))
        XCTAssertEqual(RequestPolicy.storedOrigin(for: safari, extensionBundle: "nodots"), .failure(.badRequest))
        XCTAssertEqual(RequestPolicy.storedOrigin(for: safari, extensionBundle: "a." + String(repeating: "b", count: 254)),
                       .failure(.badRequest))
        XCTAssertEqual(RequestPolicy.storedOrigin(for: .extensionOrigin("chrome-extension://abcd"), extensionBundle: nil),
                       .success("chrome-extension://abcd"))
        XCTAssertEqual(RequestPolicy.storedOrigin(for: .extensionOrigin("moz-extension://abcd"), extensionBundle: "x.y"),
                       .success("moz-extension://abcd"))
        XCTAssertEqual(RequestPolicy.storedOrigin(for: .native, extensionBundle: "x.y"), .success(nil))
    }
}
