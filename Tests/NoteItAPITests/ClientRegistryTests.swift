import Foundation
import NoteItAPI
import XCTest

final class ClientRegistryTests: XCTestCase {
    func testIssueAuthenticateRevoke() throws {
        let registry = ClientRegistry(store: InMemoryClientStore())
        let revoked = Locked<[UUID]>([])
        registry.onRevoke = { id in revoked.mutate { $0.append(id) } }
        let (record, token) = try registry.issue(name: "CLI", kind: .cli, scopes: [.write, .read, .write], origin: nil)
        XCTAssertEqual(token.count, 47)
        XCTAssertEqual(record.scopes, [.read, .write])
        XCTAssertEqual(record.tokenHash, APIToken.hash(token))
        XCTAssertEqual(record.tokenHint, String(token.prefix(8)))
        XCTAssertFalse(record.tokenHash.contains(token))

        XCTAssertEqual(registry.authenticate(bearer: "Bearer \(token)"), record)
        XCTAssertEqual(registry.authenticate(bearer: "bearer  \(token) "), record)
        XCTAssertEqual(registry.authenticate(bearer: token), record)
        XCTAssertNil(registry.authenticate(bearer: "Bearer nit_wrong"))
        XCTAssertNil(registry.authenticate(bearer: "Bearer "))
        XCTAssertNil(registry.authenticate(bearer: nil))
        XCTAssertFalse(registry.wasRevoked(bearer: "Bearer \(token)"))

        try registry.revoke(record.id)
        XCTAssertNil(registry.authenticate(bearer: "Bearer \(token)"))
        XCTAssertTrue(registry.wasRevoked(bearer: "Bearer \(token)"))
        XCTAssertEqual(revoked.value, [record.id])
        XCTAssertThrowsError(try registry.revoke(record.id)) { XCTAssertEqual($0 as? APIErrorCode, .notFound) }
    }

    func testRevokeAllClearsStore() throws {
        let store = InMemoryClientStore()
        let registry = ClientRegistry(store: store)
        let revoked = Locked<Set<UUID>>([])
        registry.onRevoke = { id in revoked.mutate { $0.insert(id) } }
        let (one, tokenOne) = try registry.issue(name: "One", kind: .cli, scopes: [.read], origin: nil)
        let (two, _) = try registry.issue(name: "Two", kind: .script, scopes: [.admin], origin: nil)
        XCTAssertEqual(store.load().count, 2)
        try registry.revokeAll()
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(registry.clients.isEmpty)
        XCTAssertEqual(revoked.value, [one.id, two.id])
        XCTAssertTrue(registry.wasRevoked(bearer: tokenOne))
    }

    func testRegistryPersistsThroughStore() throws {
        let store = InMemoryClientStore()
        let (record, token) = try ClientRegistry(store: store).issue(name: "Ext", kind: .extension, scopes: [.read],
                                                                     origin: "chrome-extension://abcd")
        XCTAssertEqual(store.load(), [record])
        let reloaded = ClientRegistry(store: store)
        XCTAssertEqual(reloaded.clients, [record])
        XCTAssertEqual(reloaded.authenticate(bearer: "Bearer \(token)"), record)

        let failing = ClientRegistry(store: FailingStore())
        XCTAssertThrowsError(try failing.issue(name: "X", kind: .cli, scopes: [.read], origin: nil))
        XCTAssertTrue(failing.clients.isEmpty)
    }
}

private struct FailingStore: ClientStore {
    struct Failure: Error {}
    func load() -> [ClientRecord] { [] }
    func save(_ records: [ClientRecord]) throws { throw Failure() }
}
