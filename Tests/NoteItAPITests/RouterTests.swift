import Foundation
import NoteItAPI
import XCTest

final class RouterTests: XCTestCase {
    private let router = Router()

    private func spec(_ id: String, _ method: HTTPMethod, _ pattern: String) -> RouteSpec {
        RouteSpec(id: id, method: method, pattern: pattern, scope: .read, body: .none, bucket: .general,
                  maxBodyBytes: nil, summary: "Test")
    }

    func testRouterParams() throws {
        let get = try router.match(method: "GET", path: "/v1/notes/ABC").get()
        XCTAssertEqual(get.spec.id, RouteID.noteGet.rawValue)
        XCTAssertEqual(get.params, ["id": "ABC"])

        let append = try router.match(method: "POST", path: "/v1/notes/ABC/append").get()
        XCTAssertEqual(append.spec.id, RouteID.noteAppend.rawValue)
        XCTAssertEqual(append.params, ["id": "ABC"])

        let attachment = try router.match(method: "GET", path: "/v1/notes/ABC/attachments/photo 1.jpg").get()
        XCTAssertEqual(attachment.spec.id, RouteID.attachmentGet.rawValue)
        XCTAssertEqual(attachment.params, ["id": "ABC", "name": "photo 1.jpg"])

        XCTAssertEqual(try router.match(method: "GET", path: "/v1/notes").get().spec.id, RouteID.notesList.rawValue)
        XCTAssertEqual(router.match(method: "GET", path: "/v1/notes/").map(\.spec.id), .failure(.notFound))
        XCTAssertEqual(router.match(method: "GET", path: "/v1/notes/ABC/append/x").map(\.spec.id), .failure(.notFound))
    }

    func testRouterLiteralBeatsParam() throws {
        let routes = APIRoutes.all + [spec("tasks.recent", .GET, "/v1/notes/recent"),
                                      spec("tasks.sub", .GET, "/v1/{kind}/recent")]
        let router = Router(routes: routes)
        XCTAssertEqual(try router.match(method: "GET", path: "/v1/notes/recent").get().spec.id, "tasks.recent")
        XCTAssertEqual(try router.match(method: "GET", path: "/v1/notes/other").get().spec.id, RouteID.noteGet.rawValue)
        XCTAssertEqual(try router.match(method: "GET", path: "/v1/tasks/recent").get().params, ["kind": "tasks"])
        // The same path with another method falls back to the parameter route that has the method.
        XCTAssertEqual(try router.match(method: "DELETE", path: "/v1/notes/recent").get().spec.id,
                       RouteID.noteDelete.rawValue)
    }

    func testRouter405() {
        XCTAssertEqual(router.match(method: "PUT", path: "/v1/notes/ABC").map(\.spec.id), .failure(.badRequest))
        XCTAssertEqual(router.match(method: "POST", path: "/v1/ping").map(\.spec.id), .failure(.badRequest))
        XCTAssertEqual(router.allowedMethods(path: "/v1/notes/ABC"), ["GET", "PATCH", "DELETE"])
        XCTAssertEqual(router.allowedMethods(path: "/v1/me"), ["GET", "DELETE"])
    }

    func testRouter404() {
        for path in ["/", "/v1", "/v2/ping", "/v1/pings", "/v1/ping/", "/v1/unknown/thing"] {
            XCTAssertEqual(router.match(method: "GET", path: path).map(\.spec.id), .failure(.notFound), path)
            XCTAssertEqual(router.allowedMethods(path: path), [], path)
        }
    }
}
