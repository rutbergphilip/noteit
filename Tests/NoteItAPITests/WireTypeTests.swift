import Foundation
import NoteItAPI
import NoteItCore
import XCTest

final class WireTypeTests: XCTestCase {
    func testEveryErrorCodeHasSnakeCaseRawValueAndStatus() {
        let snakeCase = try! NSRegularExpression(pattern: "^[a-z]+(_[a-z]+)*$")
        for code in APIErrorCode.allCases {
            let raw = code.rawValue
            XCTAssertNotNil(snakeCase.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), raw)
            XCTAssertTrue((400...599).contains(code.httpStatus), raw)
        }
    }

    func testProgramErrorTableStatuses() {
        let table: [String: Int] = [
            "bad_request": 400, "unauthorized": 401, "read_only": 403, "not_found": 404, "editor_required": 409,
            "revision_mismatch": 412, "note_locked": 423, "internal": 500, "not_implemented": 501,
            "not_available": 501, "not_ready": 503,
        ]
        for (raw, status) in table {
            guard let code = APIErrorCode(rawValue: raw) else { return XCTFail("missing \(raw)") }
            XCTAssertEqual(code.httpStatus, status, raw)
        }
        XCTAssertNotEqual(APIErrorCode.notImplemented, APIErrorCode.notAvailable)
    }

    func testErrorBodyShape() throws {
        let data = try APIJSON.encoder().encode(APIErrorBody(code: .notFound, message: "Gone"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"error":{"code":"not_found","message":"Gone"}}"#)
    }

    func testNullableKeysEncodeExplicitNull() throws {
        let page = String(decoding: try APIJSON.encoder().encode(Page<String>(items: ["a"], nextCursor: nil)), as: UTF8.self)
        XCTAssertTrue(page.contains(#""nextCursor":null"#), page)
        let notebooks = String(decoding: try APIJSON.encoder().encode(NotebooksResponseDTO(notebooks: [], defaultNotebookID: nil)),
                               as: UTF8.self)
        XCTAssertTrue(notebooks.contains(#""defaultNotebookID":null"#), notebooks)

        let decoder = APIJSON.decoder()
        XCTAssertEqual(try decoder.decode(Page<String>.self, from: Data(#"{"items":[]}"#.utf8)), Page(items: [], nextCursor: nil))
        XCTAssertEqual(try decoder.decode(NotebooksResponseDTO.self, from: Data(#"{"notebooks":[]}"#.utf8)),
                       NotebooksResponseDTO(notebooks: [], defaultNotebookID: nil))
        XCTAssertEqual(try decoder.decode(Page<String>.self, from: Data(#"{"items":["a"],"nextCursor":"c"}"#.utf8)),
                       Page(items: ["a"], nextCursor: "c"))
    }

    func testHighlightEncodesRangesAsPairs() throws {
        let highlight = HighlightDTO(field: .body, ranges: [[0, 3], [7, 2]])
        let object = try jsonObject(highlight)
        XCTAssertEqual(object["field"] as? String, "body")
        XCTAssertEqual(object["ranges"] as? [[Int]], [[0, 3], [7, 2]])
    }

    func testTagNodeEncodesTotalCount() throws {
        let leaf = TagNodeDTO(name: "b", path: "a/b", noteCount: 2, totalCount: 2, children: [])
        let node = TagNodeDTO(name: "a", path: "a", noteCount: 1, totalCount: 3, children: [leaf])
        let object = try jsonObject(node)
        XCTAssertEqual(object["totalCount"] as? Int, 3)
        XCTAssertEqual((object["children"] as? [[String: Any]])?.first?["path"] as? String, "a/b")
    }

    func testPingEncodesCapabilitiesNotPlugins() throws {
        let ping = PingDTO(name: "NoteIt", apiVersion: 1, appVersion: "1.0", capabilities: ["tag-tree"])
        let object = try jsonObject(ping)
        XCTAssertEqual(object["capabilities"] as? [String], ["tag-tree"])
        XCTAssertNil(object["plugins"])
        XCTAssertNil(object["features"])
    }

    func testClientKindHasNoPlugin() {
        XCTAssertFalse(ClientKind.allCases.map(\.rawValue).contains("plugin"))
        XCTAssertNil(ClientKind(rawValue: "plugin"))
    }

    /// Built-in ids are `RouteID.rawValue` (automation's frozen `RouteSpec.id`); `<slug>.<name>` is for registered
    /// routes, which `LocalAPIRouteRegistry` checks.
    func testBuiltInRouteIDsAreRouteIDsAndPathsAreUnique() {
        XCTAssertEqual(APIRoutes.all.map(\.id), RouteID.allCases.map(\.rawValue))
        XCTAssertEqual(Set(APIRoutes.all.map(\.id)).count, APIRoutes.all.count)
        let keys = APIRoutes.all.map { "\($0.method.rawValue) \($0.pattern)" }
        XCTAssertEqual(Set(keys).count, keys.count)
        for route in APIRoutes.all {
            XCTAssertFalse(route.id.contains("."), route.id)
            XCTAssertTrue(route.pattern.hasPrefix(APIRoutes.basePath + "/"), route.pattern)
        }
    }

    func testOnlyPublicRoutesHaveNoScope() {
        let unscoped = Set(APIRoutes.all.filter { $0.scope == nil }.map(\.id))
        XCTAssertEqual(unscoped, ["ping", "openapi", "pairStart", "pairComplete"])
        for route in APIRoutes.all where route.scope == nil {
            XCTAssertEqual(route.bucket, .unauthenticated, route.id)
        }
    }

    func testNoteSummaryRoundTripsWithISO8601Dates() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000.25)
        let summary = makeSummary(createdAt: created)
        let data = try APIJSON.encoder().encode(summary)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let createdText = try XCTUnwrap(object["createdAt"] as? String)
        XCTAssertTrue(createdText.hasPrefix("2023-11-14T22:13:20.25"), createdText)
        XCTAssertTrue(createdText.hasSuffix("Z"), createdText)
        let decoded = try APIJSON.decoder().decode(NoteSummaryDTO.self, from: data)
        XCTAssertEqual(decoded, summary)
    }

    func testDecoderAcceptsDatesWithoutFractions() throws {
        let json = #"{"cursor":"c","kind":"note","id":"00000000-0000-0000-0000-000000000001","op":"created","at":"2023-11-14T22:13:20Z"}"#
        let change = try APIJSON.decoder().decode(ChangeDTO.self, from: Data(json.utf8))
        XCTAssertEqual(change.at, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testNoteDTOEncodesFlat() throws {
        let note = NoteDTO(summary: makeSummary(createdAt: Date(timeIntervalSince1970: 0)), format: .markdown, body: "# Hi")
        let data = try APIJSON.encoder().encode(note)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Title")
        XCTAssertEqual(object["format"] as? String, "markdown")
        XCTAssertEqual(object["body"] as? String, "# Hi")
        XCTAssertNil(object["summary"])
        XCTAssertEqual(try APIJSON.decoder().decode(NoteDTO.self, from: data), note)
    }

    func testAppendPositionIsCoreType() throws {
        let request = AppendRequest(text: "x", position: NoteItCore.AppendPosition.start)
        let object = try jsonObject(request)
        XCTAssertEqual(object["position"] as? String, "start")
    }

    func testTokenShapeAndMatching() {
        let token = APIToken.generate()
        XCTAssertTrue(token.hasPrefix(APIToken.prefix))
        XCTAssertEqual(token.count, 47)
        XCTAssertFalse(token.contains("+") || token.contains("/") || token.contains("="))
        XCTAssertNotEqual(token, APIToken.generate())
        let hash = APIToken.hash(token)
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertTrue(APIToken.matches(token, hash: hash))
        XCTAssertFalse(APIToken.matches(token + "x", hash: hash))
        XCTAssertFalse(APIToken.matches(token, hash: String(hash.dropLast())))
        XCTAssertEqual(APIToken.hint(token), String(token.prefix(8)))
        XCTAssertEqual(APIToken.hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPairingCodeIsSixDigits() {
        for _ in 0..<50 {
            let code = APIToken.pairingCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isASCII) && code.allSatisfy(\.isNumber), code)
        }
    }

    func testDiscoveryFileWriteReadAndStale() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DiscoveryFile(pid: getpid(), appVersion: "1.0", apiEnabled: true, port: 52_000,
                                 baseURL: URL(string: "http://127.0.0.1:52000"), startedAt: Date(timeIntervalSince1970: 5))
        try file.write(to: directory)
        let path = directory.appendingPathComponent(DiscoveryFile.fileName).path
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(DiscoveryFile.read(from: directory), file)
        XCTAssertNil(DiscoveryFile.read(from: directory, isProcessAlive: { _ in false }))
        try Data("{".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(DiscoveryFile.read(from: directory))
        DiscoveryFile.remove(from: directory)
        XCTAssertNil(DiscoveryFile.read(from: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testDiscoveryDirectory() {
        let home = URL(fileURLWithPath: "/fake-home", isDirectory: true)
        XCTAssertEqual(DiscoveryFile.directory(environment: [:], home: home).path,
                       "/fake-home/Library/Application Support/NoteIt")
        XCTAssertEqual(DiscoveryFile.directory(environment: ["NOTEIT_DATA_DIR": "/data/x"], home: home).path, "/data/x")
    }

    func testProcessIsAlive() {
        XCTAssertTrue(DiscoveryFile.processIsAlive(getpid()))
    }

    func testHeadersAreCaseInsensitive() {
        var headers = HTTPHeaders([("Content-Type", "text/plain")])
        XCTAssertEqual(headers["content-type"], "text/plain")
        headers["CONTENT-TYPE"] = "application/json"
        XCTAssertEqual(headers.pairs.count, 1)
        XCTAssertEqual(headers["Content-Type"], "application/json")
        headers["content-type"] = nil
        XCTAssertTrue(headers.pairs.isEmpty)
    }

    func testErrorResponseAndSerialization() {
        let response = HTTPResponse.error(.revisionMismatch, "Changed")
        XCTAssertEqual(response.status, 412)
        let text = String(decoding: response.serialized(keepAlive: false), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 412 Precondition Failed\r\n"), text)
        XCTAssertTrue(text.contains("Content-Length: \(response.body.count)\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.contains("X-Content-Type-Options: nosniff\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n" + String(decoding: response.body, as: UTF8.self)))
        XCTAssertTrue(String(decoding: HTTPResponse(status: 204).serialized(keepAlive: true), as: UTF8.self)
            .contains("Connection: keep-alive\r\n"))
    }

    private func makeSummary(createdAt: Date) -> NoteSummaryDTO {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        return NoteSummaryDTO(id: id, title: "Title", notebookID: nil, notebookName: nil, tags: ["a"], pinned: false,
                              createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(60), revision: UUID(),
                              deletedAt: nil, preview: "Preview", conflict: false, locked: false,
                              url: "noteit://note/\(id.uuidString)")
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try APIJSON.encoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
