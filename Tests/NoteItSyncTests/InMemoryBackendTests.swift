import XCTest
@testable import NoteItSync

final class InMemoryBackendTests: XCTestCase {
    func testPutGetRoundTrip() async throws {
        let backend = InMemoryBackend()
        let data = Data("hello".utf8)
        let etag = try await backend.put("a/b", data: data, ifMatch: nil, ifNoneMatch: false)
        let got = try await backend.get("a/b")
        XCTAssertEqual(got.data, data)
        XCTAssertEqual(got.etag, etag)

        let etag2 = try await backend.put("a/b", data: Data("bye".utf8), ifMatch: nil, ifNoneMatch: false)
        XCTAssertNotEqual(etag, etag2)
        let putCount = await backend.putCount
        let getCount = await backend.getCount
        XCTAssertEqual(putCount, 2)
        XCTAssertEqual(getCount, 1)
    }

    func testIfNoneMatchFailsWhenExists() async throws {
        let backend = InMemoryBackend()
        try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: true)
        do {
            try await backend.put("k", data: Data([2]), ifMatch: nil, ifNoneMatch: true)
            XCTFail("Expected preconditionFailed")
        } catch let error as StorageError {
            XCTAssertEqual(error, .preconditionFailed("k"))
        }
        let got = try await backend.get("k")
        XCTAssertEqual(got.data, Data([1]))
    }

    func testIfMatchFailsOnStaleETag() async throws {
        let backend = InMemoryBackend()
        let first = try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: false)
        let second = try await backend.put("k", data: Data([2]), ifMatch: first, ifNoneMatch: false)
        do {
            try await backend.put("k", data: Data([3]), ifMatch: first, ifNoneMatch: false)
            XCTFail("Expected preconditionFailed")
        } catch let error as StorageError {
            XCTAssertEqual(error, .preconditionFailed("k"))
        }
        let got = try await backend.get("k")
        XCTAssertEqual(got.data, Data([2]))
        XCTAssertEqual(got.etag, second)
    }

    func testListPrefix() async throws {
        let backend = InMemoryBackend()
        try await backend.put("noteit/v1/notes/1.meta", data: Data([1, 2]), ifMatch: nil, ifNoneMatch: false)
        try await backend.put("noteit/v1/notes/2.meta", data: Data([1]), ifMatch: nil, ifNoneMatch: false)
        try await backend.put("other/x", data: Data(), ifMatch: nil, ifNoneMatch: false)

        let objects = try await backend.list(prefix: "noteit/v1/")
        XCTAssertEqual(objects.map(\.key), ["noteit/v1/notes/1.meta", "noteit/v1/notes/2.meta"])
        XCTAssertEqual(objects.map(\.size), [2, 1])
        let listCount = await backend.listCount
        XCTAssertEqual(listCount, 1)
    }

    func testDeleteMissingThrowsNotFound() async throws {
        let backend = InMemoryBackend()
        do {
            try await backend.delete("missing")
            XCTFail("Expected notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound("missing"))
        }
        do {
            _ = try await backend.get("missing")
            XCTFail("Expected notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound("missing"))
        }
        try await backend.put("k", data: Data(), ifMatch: nil, ifNoneMatch: false)
        try await backend.delete("k")
        let deleteCount = await backend.deleteCount
        XCTAssertEqual(deleteCount, 2)
    }

    func testFailNextPuts() async throws {
        let backend = InMemoryBackend()
        await backend.failNextPuts(1)
        do {
            try await backend.put("k", data: Data(), ifMatch: nil, ifNoneMatch: false)
            XCTFail("Expected network error")
        } catch let error as StorageError {
            guard case .network = error else { return XCTFail("Unexpected \(error)") }
        }
        try await backend.put("k", data: Data(), ifMatch: nil, ifNoneMatch: false)
        _ = try await backend.get("k")
    }

    func testSyncStateRoundTripAndCorruptLoadsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sync-state.json")

        XCTAssertEqual(SyncState.load(from: url), SyncState())

        let id = UUID()
        let state = SyncState(
            bases: [id: .init(revision: UUID(), remoteMetaETag: "etag-1")],
            knownTombstones: [UUID()],
            lastDeviceWrite: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try state.save(to: url)
        XCTAssertEqual(SyncState.load(from: url), state)

        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(SyncState.load(from: url), SyncState())
    }

    func testRemoteLayoutKeys() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertEqual(RemoteLayout.root, "noteit/v1/")
        XCTAssertEqual(RemoteLayout.manifest(), "noteit/v1/manifest.json")
        XCTAssertEqual(RemoteLayout.meta(.notebook, id), "noteit/v1/notebooks/11111111-2222-3333-4444-555555555555.json")
        XCTAssertEqual(RemoteLayout.meta(.note, id), "noteit/v1/notes/11111111-2222-3333-4444-555555555555.meta")
        XCTAssertEqual(RemoteLayout.body(id), "noteit/v1/notes/11111111-2222-3333-4444-555555555555.body")
        XCTAssertEqual(RemoteLayout.tombstone(id), "noteit/v1/tombstones/11111111-2222-3333-4444-555555555555.json")
        XCTAssertEqual(RemoteLayout.device("mac-1"), "noteit/v1/devices/mac-1.json")
    }
}
