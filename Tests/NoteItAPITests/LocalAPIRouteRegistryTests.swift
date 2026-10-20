import Foundation
@testable import NoteItAPI
import XCTest

final class LocalAPIRouteRegistryTests: XCTestCase {
    private func spec(_ id: String, _ method: HTTPMethod = .GET, _ pattern: String,
                      scope: APIScope? = .read) -> RouteSpec {
        RouteSpec(id: id, method: method, pattern: pattern, scope: scope, body: .none, bucket: .general,
                  maxBodyBytes: nil, summary: "Test")
    }

    private func response(_ status: Int) -> LocalAPIHandler {
        { _ in HTTPResponse(status: status) }
    }

    private func context() -> LocalAPIContext {
        let match = RouteMatch(spec: APIRoutes.all[0], params: [:])
        return LocalAPIContext(request: HTTPRequest(method: "GET", path: "/v1/ping"), route: match, client: nil,
                               origin: .native)
    }

    func testFreshRegistryIsEmptyAndValid() {
        let registry = LocalAPIRouteRegistry()
        XCTAssertTrue(registry.routes.isEmpty)
        XCTAssertTrue(registry.searchModes.isEmpty)
        XCTAssertTrue(registry.capabilities.isEmpty)
        XCTAssertTrue(registry.validate().isEmpty)
    }

    func testValidRouteRegisters() async {
        let registry = LocalAPIRouteRegistry()
        registry.register(spec("tasks.list", .GET, "/v1/tasks"), handler: response(200))
        registry.register(spec("tasks.get", .GET, "/v1/tasks/{id}"), handler: response(201))
        XCTAssertEqual(registry.routes.map(\.id), ["tasks.list", "tasks.get"])
        XCTAssertTrue(registry.validate().isEmpty)
        let status = await registry.handler(for: "tasks.get")?(context()).status
        XCTAssertEqual(status, 201)
        XCTAssertNil(registry.handler(for: "tasks.missing"))
    }

    func testConflictWithBuiltInPath() {
        let registry = LocalAPIRouteRegistry(trapsOnProblems: false)
        registry.register(spec("tasks.note", .GET, "/v1/notes/{noteID}"), handler: response(200))
        XCTAssertEqual(registry.validate().count, 1)
        XCTAssertTrue(registry.validate()[0].contains("built-in route noteGet"), registry.validate()[0])
    }

    func testSamePathDifferentMethodIsFine() {
        let registry = LocalAPIRouteRegistry()
        registry.register(spec("tasks.ping", .POST, "/v1/ping"), handler: response(200))
        XCTAssertTrue(registry.validate().isEmpty)
    }

    func testConflictWithRegisteredPath() {
        let registry = LocalAPIRouteRegistry(trapsOnProblems: false)
        registry.register(spec("tasks.list", .GET, "/v1/tasks"), handler: response(200))
        registry.register(spec("todo.list", .GET, "/v1/tasks"), handler: response(200))
        XCTAssertEqual(registry.validate().count, 1)
        XCTAssertTrue(registry.validate()[0].contains("registered route tasks.list"))
    }

    func testDuplicateID() {
        let registry = LocalAPIRouteRegistry(trapsOnProblems: false)
        registry.register(spec("tasks.list", .GET, "/v1/tasks"), handler: response(200))
        registry.register(spec("tasks.list", .GET, "/v1/tasks/all"), handler: response(200))
        XCTAssertEqual(registry.validate(), ["Route tasks.list: duplicate id"])
    }

    func testIDWithoutSlug() {
        let registry = LocalAPIRouteRegistry(trapsOnProblems: false)
        registry.register(spec("list", .GET, "/v1/tasks"), handler: response(200))
        registry.register(spec("Tasks.list", .GET, "/v1/tasks/a"), handler: response(200))
        XCTAssertEqual(registry.validate().count, 2)
        XCTAssertTrue(registry.validate().allSatisfy { $0.contains("<slug>.<name>") })
    }

    func testBuiltInIDIsDuplicate() {
        let registry = LocalAPIRouteRegistry(trapsOnProblems: false)
        registry.register(spec("ping", .GET, "/v1/other"), handler: response(200))
        XCTAssertTrue(registry.validate().contains("Route ping: duplicate id"))
    }

    func testNilScope() {
        let registry = LocalAPIRouteRegistry(trapsOnProblems: false)
        registry.register(spec("tasks.list", .GET, "/v1/tasks", scope: nil), handler: response(200))
        XCTAssertEqual(registry.validate(), ["Route tasks.list: registered routes need a scope"])
    }

    func testSearchModes() async {
        let registry = LocalAPIRouteRegistry(trapsOnProblems: false)
        let handler: SearchModeHandler = { _, _ in .failure(.notAvailable) }
        registry.registerSearchMode("semantic", handler: handler)
        registry.registerSearchMode("hybrid", handler: handler)
        XCTAssertTrue(registry.validate().isEmpty)
        XCTAssertEqual(registry.searchModes, ["hybrid", "semantic"])
        let result = await registry.searchMode("semantic")?(SearchQuery(q: "x", limit: 5), context())
        XCTAssertEqual(result, .failure(.notAvailable))
        XCTAssertNil(registry.searchMode("keyword"))

        registry.registerSearchMode("keyword", handler: handler)
        registry.registerSearchMode("semantic", handler: handler)
        registry.registerSearchMode("Not_Kebab", handler: handler)
        XCTAssertEqual(registry.validate(), [
            "Search mode keyword is built in",
            "Search mode semantic: already registered",
            "Search mode Not_Kebab: not kebab-case",
        ])
    }

    func testCapabilitiesSortedAndDeduplicated() {
        let registry = LocalAPIRouteRegistry()
        registry.addCapability("tag-tree")
        registry.addCapability("ai-search")
        registry.addCapability("tag-tree")
        XCTAssertEqual(registry.capabilities, ["ai-search", "tag-tree"])
        XCTAssertTrue(registry.validate().isEmpty)
    }

    func testCapabilityNotKebab() {
        let registry = LocalAPIRouteRegistry(trapsOnProblems: false)
        registry.addCapability("Tag_Tree")
        XCTAssertEqual(registry.validate(), ["Capability Tag_Tree: not kebab-case"])
    }

    func testRemoveCapabilityIsIdempotent() {
        let registry = LocalAPIRouteRegistry()
        registry.addCapability("tag-tree")
        registry.addCapability("ai-search")
        registry.removeCapability("tag-tree")
        XCTAssertEqual(registry.capabilities, ["ai-search"])
        registry.removeCapability("tag-tree")
        registry.removeCapability("never-added")
        XCTAssertEqual(registry.capabilities, ["ai-search"])
    }

    func testSharedStartsEmpty() {
        XCTAssertTrue(LocalAPIRouteRegistry.shared.routes.isEmpty)
        XCTAssertTrue(LocalAPIRouteRegistry.shared.capabilities.isEmpty)
    }
}
