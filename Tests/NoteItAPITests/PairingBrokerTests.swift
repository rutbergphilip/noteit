import Foundation
import NoteItAPI
import XCTest

final class PairingBrokerTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSinceReferenceDate: 1_000)
        var now: Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    private let clock = Clock()
    private var store: InMemoryClientStore!
    private var registry: ClientRegistry!
    private var broker: PairingBroker!
    private var events: Locked<[PairingEvent]>!

    override func setUp() {
        store = InMemoryClientStore()
        registry = ClientRegistry(store: store)
        let clock = clock
        broker = PairingBroker(registry: registry, now: { clock.now }, code: { "482913" })
        let events = Locked<[PairingEvent]>([])
        self.events = events
        broker.onEvent = { event in events.mutate { $0.append(event) } }
    }

    private func start(_ name: String = "noteit CLI on Studio", kind: ClientKind = .cli, scopes: [APIScope] = [.read, .write],
                       origin: String? = nil) -> Result<PairStartResponse, APIErrorCode> {
        broker.start(PairStartRequest(clientName: name, kind: kind, scopes: scopes), origin: origin)
    }

    private func complete(_ id: UUID, _ code: String = "482913", origin: String? = nil)
        -> Result<PairCompleteResponse, APIErrorCode> {
        broker.complete(PairCompleteRequest(pairingID: id, code: code), origin: origin)
    }

    func testPairingHappyPath() throws {
        let started = try start().get()
        XCTAssertEqual(started.expiresAt, clock.now.addingTimeInterval(120))
        guard case .started(let request) = events.value.first else { return XCTFail("\(events.value)") }
        XCTAssertEqual(request.id, started.pairingID)
        XCTAssertEqual(request.code, "482913")
        XCTAssertEqual(request.clientName, "noteit CLI on Studio")
        XCTAssertEqual(request.requestedScopes, [.read, .write])
        XCTAssertEqual(broker.current, request)

        let done = try complete(started.pairingID, "482 913").get()
        XCTAssertEqual(done.scopes, [.read, .write])
        XCTAssertEqual(registry.authenticate(bearer: "Bearer \(done.token)")?.id, done.clientID)
        XCTAssertEqual(store.load().first?.name, "noteit CLI on Studio")
        XCTAssertEqual(events.value.last, .finished(started.pairingID, success: true))
        XCTAssertNil(broker.current)
        XCTAssertEqual(complete(started.pairingID), .failure(.pairingFailed))
    }

    func testPairingSecondStartConflicts() throws {
        _ = try start().get()
        XCTAssertEqual(start("Other").map(\.pairingID), .failure(.pairingInProgress))
    }

    func testPairingExpires() throws {
        let started = try start().get()
        clock.advance(119)
        XCTAssertNotNil(broker.current)
        clock.advance(1)
        XCTAssertEqual(complete(started.pairingID), .failure(.pairingFailed))
        XCTAssertEqual(events.value.last, .cancelled(started.pairingID, reason: PairingBroker.expiredReason))
        XCTAssertTrue(registry.clients.isEmpty)
        XCTAssertNoThrow(try start().get())
    }

    func testPairingFiveWrongCodesCancel() throws {
        let started = try start().get()
        for _ in 0..<4 { XCTAssertEqual(complete(started.pairingID, "000000"), .failure(.pairingFailed)) }
        XCTAssertNotNil(broker.current)
        XCTAssertEqual(complete(started.pairingID, "000000"), .failure(.pairingFailed))
        XCTAssertEqual(events.value.last, .cancelled(started.pairingID,
                                                     reason: "Pairing cancelled after too many wrong codes"))
        XCTAssertNil(broker.current)
        XCTAssertEqual(complete(started.pairingID), .failure(.pairingFailed))
        XCTAssertTrue(registry.clients.isEmpty)
    }

    func testPairingDeny() throws {
        let started = try start().get()
        broker.deny(started.pairingID)
        XCTAssertEqual(events.value.last, .cancelled(started.pairingID, reason: PairingBroker.deniedReason))
        XCTAssertEqual(complete(started.pairingID), .failure(.pairingDenied))
        XCTAssertTrue(registry.clients.isEmpty)
        XCTAssertNoThrow(try start().get())
    }

    func testExtensionCannotGetAdmin() throws {
        let origin = "chrome-extension://abcdefghijklmnop"
        let started = try start("Clipper", kind: .extension, scopes: [.read, .admin], origin: origin).get()
        XCTAssertEqual(broker.current?.requestedScopes, [.read, .write])
        XCTAssertEqual(complete(started.pairingID, origin: nil), .failure(.pairingFailed))
        XCTAssertEqual(complete(started.pairingID, origin: "chrome-extension://other"), .failure(.pairingFailed))
        let done = try complete(started.pairingID, origin: origin).get()
        XCTAssertEqual(done.scopes, [.read, .write])
        XCTAssertEqual(registry.clients.first?.origin, origin)
    }

    func testSafariPairingStoresBundleID() throws {
        let stored = try RequestPolicy.storedOrigin(for: .extensionOrigin("safari-web-extension://HOST-1"),
                                                    extensionBundle: "io.github.example.clipper").get()
        let started = try start("Safari Clipper", kind: .extension, scopes: [.write], origin: stored).get()
        XCTAssertEqual(complete(started.pairingID, origin: "safari-web-extension:com.other.clipper"), .failure(.pairingFailed))
        _ = try complete(started.pairingID, origin: stored).get()
        XCTAssertEqual(registry.clients.first?.origin, "safari-web-extension:io.github.example.clipper")
    }

    func testGrantedScopesNarrowing() throws {
        let started = try start(scopes: [.read, .write, .admin]).get()
        broker.setGrantedScopes([.read, .admin], for: UUID())
        broker.setGrantedScopes([.read], for: started.pairingID)
        XCTAssertEqual(try complete(started.pairingID).get().scopes, [.read])

        let second = try start(scopes: [.read]).get()
        broker.setGrantedScopes([.read, .admin], for: second.pairingID)
        XCTAssertEqual(try complete(second.pairingID).get().scopes, [.read])

        let third = try start(scopes: [.read]).get()
        broker.setGrantedScopes([], for: third.pairingID)
        XCTAssertEqual(complete(third.pairingID), .failure(.pairingDenied))
        XCTAssertEqual(registry.clients.count, 2)
    }

    func testPairingNameSanitized() throws {
        let name = "  Evil\u{0007}\nName\u{202E}" + String(repeating: "x", count: 100)
        _ = try start(name).get()
        let shown = try XCTUnwrap(broker.current?.clientName)
        XCTAssertEqual(shown.count, 64)
        XCTAssertTrue(shown.hasPrefix("EvilName"))
        XCTAssertFalse(shown.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        broker.deny(broker.current!.id)
        XCTAssertEqual(start("\u{0001}\t ").map(\.pairingID), .failure(.badRequest))
        XCTAssertEqual(start(scopes: []).map(\.pairingID), .failure(.badRequest))
    }
}
