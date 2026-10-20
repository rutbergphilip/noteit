import Foundation
import NoteItAPI
import XCTest

final class ChangeHubTests: XCTestCase {
    private func publish(_ hub: ChangeHub, _ count: Int) -> [UUID] {
        (0..<count).map { _ in
            let id = UUID()
            hub.publish(kind: .note, id: id, op: .updated, at: Date(timeIntervalSince1970: 0))
            return id
        }
    }

    func testChangesSinceCursor() throws {
        let hub = ChangeHub(bootID: "BOOT")
        let start = hub.currentCursor
        XCTAssertEqual(start, "BOOT:0")
        let ids = publish(hub, 5)
        let first = try hub.changes(since: start, limit: 3).get()
        XCTAssertEqual(first.changes.map(\.id), Array(ids[0..<3]))
        XCTAssertEqual(first.changes.map(\.cursor), ["BOOT:1", "BOOT:2", "BOOT:3"])
        XCTAssertEqual(first.cursor, "BOOT:3")
        XCTAssertTrue(first.hasMore)
        let rest = try hub.changes(since: first.cursor, limit: 3).get()
        XCTAssertEqual(rest.changes.map(\.id), Array(ids[3...]))
        XCTAssertFalse(rest.hasMore)
        let none = try hub.changes(since: rest.cursor, limit: 3).get()
        XCTAssertEqual(none, ChangesPage(changes: [], cursor: "BOOT:5", hasMore: false))
        XCTAssertEqual(hub.changes(since: "garbage", limit: 3).map(\.cursor), .failure(.badRequest))
        XCTAssertEqual(hub.changes(since: "BOOT:99", limit: 3).map(\.cursor), .failure(.badRequest))
    }

    func testCursorFromOtherBootExpires() {
        let hub = ChangeHub(bootID: "BOOT")
        _ = publish(hub, 2)
        XCTAssertEqual(hub.changes(since: "OTHER:1", limit: 10).map(\.cursor), .failure(.cursorExpired))
        XCTAssertEqual(hub.subscribe(client: UUID(), after: "OTHER:1") { _ in }.map { _ in true }, .failure(.cursorExpired))
    }

    func testCursorOlderThanBufferExpires() throws {
        let hub = ChangeHub(bootID: "B", capacity: 3)
        let ids = publish(hub, 5)
        XCTAssertEqual(hub.changes(since: "B:0", limit: 10).map(\.cursor), .failure(.cursorExpired))
        XCTAssertEqual(hub.changes(since: "B:1", limit: 10).map(\.cursor), .failure(.cursorExpired))
        XCTAssertEqual(try hub.changes(since: "B:2", limit: 10).get().changes.map(\.id), Array(ids[2...]))
        // Long runs keep the window right after the buffer compacts.
        let more = publish(hub, 20)
        XCTAssertEqual(try hub.changes(since: "B:22", limit: 10).get().changes.map(\.id), Array(more[17...]))
        XCTAssertEqual(hub.changes(since: "B:21", limit: 10).map(\.cursor), .failure(.cursorExpired))
    }

    func testNoSinceReturnsCurrentCursorOnly() throws {
        let hub = ChangeHub(bootID: "BOOT")
        _ = publish(hub, 3)
        XCTAssertEqual(try hub.changes(since: nil, limit: 50).get(), ChangesPage(changes: [], cursor: "BOOT:3", hasMore: false))
    }

    func testSubscriberLimits() throws {
        let hub = ChangeHub(bootID: "BOOT")
        let received = Locked<[UUID]>([])
        let clients = (0..<5).map { _ in UUID() }
        var subscriptions: [UUID] = []
        for _ in 0..<4 {
            subscriptions.append(try hub.subscribe(client: clients[0], after: nil) { change in
                received.mutate { $0.append(change.id) }
            }.get())
        }
        XCTAssertEqual(hub.subscribe(client: clients[0], after: nil) { _ in }.map { _ in true }, .failure(.rateLimited))
        for client in clients[1...3] {
            for _ in 0..<4 { _ = try hub.subscribe(client: client, after: nil) { _ in }.get() }
        }
        XCTAssertEqual(hub.subscriberCount, 16)
        XCTAssertEqual(hub.subscribe(client: clients[4], after: nil) { _ in }.map { _ in true }, .failure(.rateLimited))
        hub.unsubscribe(subscriptions.removeLast())
        XCTAssertNoThrow(try hub.subscribe(client: clients[4], after: nil) { _ in }.get())

        let ids = publish(hub, 2)
        XCTAssertEqual(received.value, [ids[0], ids[0], ids[0], ids[1], ids[1], ids[1]])

        // A subscriber with a cursor gets the backlog first, then new changes.
        let late = Locked<[UUID]>([])
        hub.unsubscribe(subscriptions.removeLast())
        _ = try hub.subscribe(client: clients[0], after: "BOOT:1") { change in late.mutate { $0.append(change.id) } }.get()
        let next = publish(hub, 1)
        XCTAssertEqual(late.value, [ids[1]] + next)
    }

    func testCloseAllRemovesClientSubscribers() throws {
        let hub = ChangeHub(bootID: "BOOT")
        let revoked = UUID(), other = UUID()
        let closed = Locked(0)
        let received = Locked(0)
        for _ in 0..<2 {
            _ = try hub.subscribe(client: revoked, after: nil, onClose: { closed.mutate { $0 += 1 } }) { _ in
                received.mutate { $0 += 1 }
            }.get()
        }
        _ = try hub.subscribe(client: other, after: nil) { _ in received.mutate { $0 += 100 } }.get()
        hub.closeAll(client: revoked)
        XCTAssertEqual(closed.value, 2)
        XCTAssertEqual(hub.subscriberCount, 1)
        _ = publish(hub, 1)
        XCTAssertEqual(received.value, 100)
    }
}
