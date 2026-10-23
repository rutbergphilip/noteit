import XCTest
@testable import NoteItSync

/// Runs against a real S3-compatible endpoint (Floci, MinIO, …). Skipped unless `NOTEIT_LIVE_S3_ENDPOINT` is set.
/// See `scripts/live_s3_tests.sh`.
final class LiveS3EmulatorTests: XCTestCase {
    private var config: S3Config!
    private var credentials: S3Credentials!
    private var dir: URL!

    override func setUp() async throws {
        guard let endpoint = AppEnvironment.value("LIVE_S3_ENDPOINT").flatMap(URL.init(string:)) else {
            throw XCTSkip("NOTEIT_LIVE_S3_ENDPOINT not set")
        }
        let region = AppEnvironment.value("LIVE_S3_REGION") ?? "us-east-1"
        let bucket = AppEnvironment.value("LIVE_S3_BUCKET") ?? "noteit-live"
        credentials = S3Credentials(accessKeyID: AppEnvironment.value("LIVE_S3_ACCESS_KEY") ?? "test",
                                    secretAccessKey: AppEnvironment.value("LIVE_S3_SECRET") ?? "test")
        // A NoteIt server only accepts keys in the store layout, so it runs without a per-run prefix.
        let prefix = AppEnvironment.value("LIVE_S3_NO_PREFIX") == nil ? "run-\(UUID().uuidString.prefix(8))" : ""
        config = S3Config(endpoint: endpoint, region: region, bucket: bucket,
                          pathStyle: AppEnvironment.value("LIVE_S3_VIRTUAL_HOST") == nil, prefix: prefix)
        if AppEnvironment.value("LIVE_S3_CREATE_BUCKET") != nil { try await createBucketIfNeeded() }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-s3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        guard config != nil else { return }
        let backend = makeBackend()
        for object in (try? await backend.list(prefix: "")) ?? [] { try? await backend.delete(object.key) }
    }

    private func makeBackend() -> S3Backend {
        S3Backend(config: config, credentials: credentials, session: URLSession(configuration: .ephemeral))
    }

    private func createBucketIfNeeded() async throws {
        var url = config.endpoint
        url.appendPathComponent(config.bucket)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        SigV4Signer.sign(request: &request, payloadSHA256: SigV4Signer.emptyPayloadSHA256,
                         credentials: credentials, region: config.region, date: Date())
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssert([200, 409].contains(status), "create bucket returned \(status)")
    }

    func testBackendContract() async throws {
        let backend = makeBackend()
        try await backend.probe()

        let etag = try await backend.put("notes/a.meta", data: Data("one".utf8), ifMatch: nil, ifNoneMatch: true)
        let fetched = try await backend.get("notes/a.meta")
        XCTAssertEqual(fetched.data, Data("one".utf8))
        XCTAssertEqual(fetched.etag, etag)

        do {
            try await backend.put("notes/a.meta", data: Data("dup".utf8), ifMatch: nil, ifNoneMatch: true)
            XCTFail("If-None-Match on existing key must fail")
        } catch StorageError.preconditionFailed {}

        let etag2 = try await backend.put("notes/a.meta", data: Data("two".utf8), ifMatch: etag, ifNoneMatch: false)
        XCTAssertNotEqual(etag, etag2)
        do {
            try await backend.put("notes/a.meta", data: Data("stale".utf8), ifMatch: etag, ifNoneMatch: false)
            XCTFail("stale If-Match must fail")
        } catch StorageError.preconditionFailed {}
        let afterStale = try await backend.get("notes/a.meta")
        XCTAssertEqual(afterStale.data, Data("two".utf8))

        try await backend.put("notes/b.body", data: Data(repeating: 7, count: 300_000), ifMatch: nil, ifNoneMatch: false)
        try await backend.put("tombstones/c.json", data: Data("{}".utf8), ifMatch: nil, ifNoneMatch: false)
        let notes = try await backend.list(prefix: "notes/").map(\.key).sorted()
        XCTAssertEqual(notes, ["notes/a.meta", "notes/b.body"])
        let all = try await backend.list(prefix: "")
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first { $0.key == "notes/b.body" }?.size, 300_000)

        do {
            try await backend.delete("notes/a.meta", ifMatch: etag)
            XCTFail("stale conditional delete must fail")
        } catch StorageError.preconditionFailed {
        } catch StorageError.invalidResponse {
            // Providers without conditional DELETE are reported through the HEAD fallback or as unsupported.
        }
        try await backend.delete("notes/a.meta", ifMatch: etag2)
        do {
            _ = try await backend.get("notes/a.meta")
            XCTFail("deleted key must be gone")
        } catch StorageError.notFound {}
        print("LIVE-S3 conditionalWritesSupported=\(backend.conditionalWritesSupported)")
    }

    func testListPaginatesPastOneThousandKeys() async throws {
        let backend = makeBackend()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for chunk in stride(from: 0, to: 1_005, by: 67) {
                group.addTask {
                    for i in chunk..<min(chunk + 67, 1_005) {
                        try await backend.put(String(format: "notes/%04d.meta", i), data: Data([1]), ifMatch: nil, ifNoneMatch: false)
                    }
                }
            }
            try await group.waitForAll()
        }
        let keys = try await backend.list(prefix: "notes/")
        XCTAssertEqual(keys.count, 1_005)
    }

    func testTwoDevicesConvergeWithEncryption() async throws {
        let backend = makeBackend()
        let (_, cipherA) = try await SyncEngine.connect(backend: backend, passphrase: "live pass", encryptNew: true)
        let (_, cipherB) = try await SyncEngine.connect(backend: backend, passphrase: "live pass", encryptNew: false)
        let storeA = FakeLocalStore(), storeB = FakeLocalStore()
        let a = SyncEngine(backend: backend, cipher: cipherA, local: storeA, stateURL: dir.appendingPathComponent("a.json"),
                           deviceID: "a", deviceName: "Mac A")
        let b = SyncEngine(backend: backend, cipher: cipherB, local: storeB, stateURL: dir.appendingPathComponent("b.json"),
                           deviceID: "b", deviceName: "Mac B")

        let shortcuts = await storeA.create(title: "Ghostty shortcuts")
        await storeA.create(kind: .notebook, title: "Work")
        let doomed = await storeA.create(title: "Scratch")
        _ = try await a.sync()
        _ = try await b.sync()
        var titlesB = await storeB.titles()
        XCTAssertEqual(titlesB, ["Ghostty shortcuts", "Work", "Scratch"])

        await storeB.edit(shortcuts, title: "Ghostty shortcuts v2")
        await storeA.delete(doomed)
        _ = try await b.sync()
        _ = try await a.sync()
        _ = try await b.sync()
        let titlesA = await storeA.titles()
        titlesB = await storeB.titles()
        XCTAssertEqual(titlesA, ["Ghostty shortcuts v2", "Work"])
        XCTAssertEqual(titlesA, titlesB)

        await storeA.edit(shortcuts, title: "A wins?")
        await storeB.edit(shortcuts, title: "B wins?")
        _ = try await a.sync()
        _ = try await b.sync()
        _ = try await a.sync()
        let finalA = await storeA.titles(), finalB = await storeB.titles()
        XCTAssertEqual(finalA, finalB)
        XCTAssertTrue(finalA.contains("B wins?"), "\(finalA)")
        XCTAssertTrue(finalA.contains { $0.hasPrefix("A wins?") && $0.contains("conflict") }, "losing edit kept as conflict copy: \(finalA)")

        for object in try await backend.list(prefix: "") where !object.key.hasSuffix("manifest.json") {
            let data = try await backend.get(object.key).data
            XCTAssertNil(data.range(of: Data("Ghostty".utf8)), "plaintext leaked in \(object.key)")
        }
    }
}
