import Foundation
import NoteItAPI
import XCTest

final class OpenAPIDocumentTests: XCTestCase {
    private func document(_ registry: LocalAPIRouteRegistry = LocalAPIRouteRegistry()) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: OpenAPIDocument.data(registry: registry))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func operation(_ document: [String: Any], _ pattern: String, _ method: String) -> [String: Any]? {
        ((document["paths"] as? [String: Any])?[pattern] as? [String: Any])?[method] as? [String: Any]
    }

    func testEveryRouteIsDocumented() throws {
        let document = try document()
        for spec in APIRoutes.all {
            let operation = try XCTUnwrap(self.operation(document, spec.pattern, spec.method.rawValue.lowercased()), spec.id)
            XCTAssertEqual(operation["x-noteit-route-id"] as? String, spec.id)
            XCTAssertEqual(operation["operationId"] as? String, spec.id)
            XCTAssertEqual(operation["x-noteit-scope"] as? String, spec.scope?.rawValue, spec.id)
            if spec.scope == nil {
                XCTAssertEqual((operation["security"] as? [Any])?.count, 0, spec.id)
            }
            XCTAssertNotNil(operation["responses"] as? [String: Any], spec.id)
        }
        let paths = try XCTUnwrap(document["paths"] as? [String: [String: Any]])
        XCTAssertEqual(paths.values.map(\.count).reduce(0, +), APIRoutes.all.count)

        // Every $ref points at a schema that exists.
        let schemas = try XCTUnwrap((document["components"] as? [String: Any])?["schemas"] as? [String: Any])
        let text = String(decoding: OpenAPIDocument.data(registry: LocalAPIRouteRegistry()), as: UTF8.self)
        let refs = try NSRegularExpression(pattern: "#/components/schemas/([A-Za-z]+)")
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range(at: 1), in: text)!]) }
        XCTAssertFalse(refs.isEmpty)
        for name in Set(refs) { XCTAssertNotNil(schemas[name], name) }
    }

    func testRegisteredRoutesAndModesAreDocumented() throws {
        let registry = LocalAPIRouteRegistry()
        registry.register(RouteSpec(id: "web-clipper.clip", method: .POST, pattern: "/v1/clips", scope: .write, body: .json,
                                    bucket: .write, maxBodyBytes: 60_000_000, summary: "Clip a page"),
                          handler: { _ in HTTPResponse(status: 201) })
        registry.registerSearchMode("meaning") { _, _ in .success([]) }
        registry.registerSearchMode("hybrid") { _, _ in .success([]) }

        let document = try document(registry)
        let clip = try XCTUnwrap(operation(document, "/v1/clips", "post"))
        XCTAssertEqual(clip["x-noteit-route-id"] as? String, "web-clipper.clip")
        XCTAssertEqual(clip["x-noteit-scope"] as? String, "write")
        XCTAssertEqual(clip["summary"] as? String, "Clip a page")

        let search = try XCTUnwrap(operation(document, "/v1/search", "get"))
        let parameters = try XCTUnwrap(search["parameters"] as? [[String: Any]])
        let mode = try XCTUnwrap(parameters.first { $0["name"] as? String == "mode" })
        XCTAssertEqual((mode["schema"] as? [String: Any])?["enum"] as? [String], ["keyword", "hybrid", "meaning"])

        let plain = try XCTUnwrap(operation(try self.document(), "/v1/search", "get"))
        let plainMode = (plain["parameters"] as? [[String: Any]])?.first { $0["name"] as? String == "mode" }
        XCTAssertEqual((plainMode?["schema"] as? [String: Any])?["enum"] as? [String], ["keyword"])
    }

    func testSearchResultDocumentsWhereTheNoteMatched() throws {
        let schemas = (try document()["components"] as? [String: Any])?["schemas"] as? [String: Any]
        let result = try XCTUnwrap(schemas?["SearchResult"] as? [String: Any])
        let matchedIn = try XCTUnwrap((result["properties"] as? [String: Any])?["matchedIn"] as? [String: Any])
        XCTAssertEqual(matchedIn["enum"] as? [String], ["image"])
        XCTAssertFalse((result["required"] as? [String] ?? []).contains("matchedIn"))
    }

    func testDocumentIsValidJSONWithVersion() throws {
        let document = try document()
        XCTAssertEqual(document["openapi"] as? String, "3.1.0")
        XCTAssertNotNil((document["info"] as? [String: Any])?["title"])
        let schemes = (document["components"] as? [String: Any])?["securitySchemes"] as? [String: Any]
        XCTAssertEqual((schemes?["bearer"] as? [String: Any])?["scheme"] as? String, "bearer")
        XCTAssertEqual((document["security"] as? [[String: Any]])?.first?.keys.first, "bearer")
        XCTAssertEqual(OpenAPIDocument.data(registry: LocalAPIRouteRegistry()),
                       OpenAPIDocument.data(registry: LocalAPIRouteRegistry()), "stable output")
    }
}
