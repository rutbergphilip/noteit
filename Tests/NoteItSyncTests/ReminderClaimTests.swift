import XCTest
@testable import NoteItSync

final class ReminderClaimTests: XCTestCase {
    private var dir: URL!
    private var memory: InMemoryBackend!
    private var cipher: SyncCipher!

    override func setUp() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dir = root.appendingPathComponent(".build/reminder-claim-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory = InMemoryBackend()
        cipher = try await SyncEngine.connect(backend: memory, passphrase: "pw", encryptNew: true, makeCipher: XORTestCipher.factory).1
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func engine(_ name: String, backend: StorageBackend? = nil) -> SyncEngine {
        SyncEngine(backend: backend ?? memory, cipher: cipher, local: FakeLocalStore(),
                   stateURL: dir.appendingPathComponent("\(name).json"), deviceID: "id-\(name)", deviceName: name, now: { Date() })
    }

    func testOneMacClaimsTheOtherSeesItClaimed() async throws {
        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let a = await engine("a").claimReminder(id, at: at)
        let b = await engine("b").claimReminder(id, at: at)
        XCTAssertEqual(a, .claimed)
        XCTAssertEqual(b, .alreadyClaimed)

        let sealed = try await memory.get(RemoteLayout.reminderClaim(id)).data
        let claim = try SyncEngine.decode(ReminderClaim.self, from: try cipher.open(sealed, context: "claims/reminders/\(id.uuidString).json"))
        XCTAssertEqual(claim, ReminderClaim(id: id, deviceID: "id-a", deliveredAt: at))
    }

    func testStorageErrorIsUnavailable() async {
        let faulty = FaultyBackend(memory)
        await faulty.onNextPut(keyContaining: "claims/", .failBefore)
        let outcome = await engine("a", backend: faulty).claimReminder(UUID(), at: Date())
        guard case .unavailable = outcome else { return XCTFail("\(outcome)") }
    }

    func testSweepRemovesOnlyOwnOldClaims() async throws {
        let a = engine("a")
        let b = engine("b")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = UUID(), fresh = UUID(), others = UUID()
        _ = await a.claimReminder(old, at: now.addingTimeInterval(-8 * 86_400))
        _ = await a.claimReminder(fresh, at: now.addingTimeInterval(-86_400))
        _ = await b.claimReminder(others, at: now.addingTimeInterval(-30 * 86_400))
        try await memory.put(RemoteLayout.reminderClaim(UUID()), data: Data("not sealed".utf8), ifMatch: nil, ifNoneMatch: true)

        let deleted = try await a.sweepReminderClaims(olderThan: 7 * 86_400, now: now)
        XCTAssertEqual(deleted, 1)
        let keys = Set(try await memory.list(prefix: RemoteLayout.reminderClaimsPrefix).map(\.key))
        XCTAssertFalse(keys.contains(RemoteLayout.reminderClaim(old)))
        XCTAssertTrue(keys.contains(RemoteLayout.reminderClaim(fresh)))
        XCTAssertTrue(keys.contains(RemoteLayout.reminderClaim(others)))
        XCTAssertEqual(keys.count, 3, "an unreadable claim is left alone")
    }

    func testClaimsAreNotRecords() async throws {
        _ = await engine("a").claimReminder(UUID(), at: Date())
        let index = RemoteIndex(try await memory.list(prefix: RemoteLayout.root))
        XCTAssertTrue(index.metas.isEmpty)
        XCTAssertTrue(index.bodies.isEmpty)
        XCTAssertTrue(index.tombstones.isEmpty)
        XCTAssertTrue(index.sidecars.isEmpty)
    }

    func testSyncPassIgnoresClaims() async throws {
        _ = await engine("a").claimReminder(UUID(), at: Date())
        let store = FakeLocalStore()
        let engine = SyncEngine(backend: memory, cipher: cipher, local: store, stateURL: dir.appendingPathComponent("c.json"),
                                deviceID: "id-c", deviceName: "c", now: { Date() })
        let report = try await engine.sync()
        XCTAssertEqual(report.pulled, 0)
        XCTAssertTrue(report.errors.isEmpty)
        let claims = try await memory.list(prefix: RemoteLayout.reminderClaimsPrefix)
        XCTAssertEqual(claims.count, 1, "a sync pass never deletes claims")
    }
}
