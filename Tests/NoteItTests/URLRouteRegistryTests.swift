import Foundation
@testable import NoteIt
import NoteItCore
import XCTest

@MainActor
final class URLRouteRegistryTests: XCTestCase {
    func testReservedHostsAreRefused() {
        let registry = URLRouteRegistry()
        for host in URLCommand.reservedHosts {
            XCTAssertFalse(registry.canRegister(host: host), host)
        }
    }

    func testUppercaseAndOtherCharactersAreRefused() {
        let registry = URLRouteRegistry()
        XCTAssertFalse(registry.canRegister(host: "Tasks"))
        XCTAssertFalse(registry.canRegister(host: "my_tasks"))
        XCTAssertFalse(registry.canRegister(host: "tasks.list"))
        XCTAssertFalse(registry.canRegister(host: ""))
    }

    func testRegisterAndLookUp() {
        let registry = URLRouteRegistry()
        XCTAssertTrue(registry.canRegister(host: "tasks"))
        var received: URL?
        registry.register(host: "tasks") { received = $0 }
        let url = URL(string: "noteit://tasks/today#top")!
        registry.handler(for: "tasks")?(url)
        XCTAssertEqual(received, url)
        XCTAssertNil(registry.handler(for: "other"))
    }

    func testDuplicateIsRefused() {
        let registry = URLRouteRegistry()
        registry.register(host: "tasks") { _ in }
        XCTAssertFalse(registry.canRegister(host: "tasks"))
    }

    func testHostsAreSorted() {
        let registry = URLRouteRegistry()
        for host in ["zeta", "alpha", "mid-way"] {
            registry.register(host: host) { _ in }
        }
        XCTAssertEqual(registry.hosts, ["alpha", "mid-way", "zeta"])
    }

    func testSharedStartsEmpty() {
        XCTAssertTrue(URLRouteRegistry.shared.hosts.isEmpty)
    }
}
