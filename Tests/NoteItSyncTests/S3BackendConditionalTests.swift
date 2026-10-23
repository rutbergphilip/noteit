import XCTest
@testable import NoteItSync

/// sync-security Task 3.0: conditional requests are sent once, the fallback's verify is in doubt, and the extended
/// canary decides `atomicConditionalWrites()` and `atomicConditionalDelete()` separately.
final class S3BackendConditionalTests: XCTestCase {
    private let credentials = S3Credentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret")

    private func makeBackend(verifyConditionals: Bool = true) -> S3Backend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let config = S3Config(endpoint: URL(string: "http://localhost:9000")!, region: "us-east-1", bucket: "notes", pathStyle: true)
        return S3Backend(config: config, credentials: credentials, session: URLSession(configuration: configuration),
                         retryDelays: [0, 0], now: { Date(timeIntervalSince1970: 1_700_000_000) }, verifyConditionals: verifyConditionals)
    }

    /// How a stub provider departs from S3's conditional semantics.
    struct Quirks {
        var ignoresNoneMatch = false
        var ignoresMatch = false
        var conditionalPut501 = false
        /// Every write gets the same ETag, whatever the bytes.
        var reissuesETag = false
        /// After an overwrite the old ETag still matches.
        var acceptsOldETag = false
        var bogusDeleteRemoves = false
        var conditionalDelete501 = false
        var rejectsCorrectDelete = false
    }

    /// A small object store behind the stub. `dropResponse` applies a matching request, then fails the transport.
    final class Server: @unchecked Sendable {
        let quirks: Quirks
        private let lock = NSLock()
        private var objects: [String: [String]] = [:]   // path → ETags, newest last
        private var version = 0
        var dropResponse: ((URLRequest) -> Bool)?

        init(_ quirks: Quirks = Quirks()) { self.quirks = quirks }

        func handle(_ request: URLRequest) throws -> StubURLProtocol.Response {
            let response = lock.withLock { respond(request) }
            if let dropResponse, dropResponse(request) { throw URLError(.networkConnectionLost) }
            return response
        }

        private func respond(_ request: URLRequest) -> StubURLProtocol.Response {
            let path = request.url!.path
            let history = objects[path]
            let current = history?.last
            let ifMatch = request.value(forHTTPHeaderField: "If-Match").map(S3ListParser.stripQuotes)
            let ifNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")
            switch request.httpMethod {
            case "PUT":
                if quirks.conditionalPut501, ifMatch != nil || ifNoneMatch != nil { return .init(status: 501) }
                if ifNoneMatch != nil, current != nil, !quirks.ignoresNoneMatch { return .init(status: 412) }
                if let ifMatch, !quirks.ignoresMatch {
                    let accepted = quirks.acceptsOldETag ? (history ?? []).contains(ifMatch) : ifMatch == current
                    if !accepted { return .init(status: 412) }
                }
                version += 1
                let etag = quirks.reissuesETag ? "same" : "v\(version)"
                objects[path, default: []].append(etag)
                return .init(status: 200, headers: ["ETag": "\"\(etag)\""])
            case "HEAD", "GET":
                return current.map { .init(status: 200, headers: ["ETag": "\"\($0)\""]) } ?? .init(status: 404)
            case "DELETE":
                if let ifMatch {
                    if quirks.conditionalDelete501 { return .init(status: 501) }
                    if ifMatch == current, quirks.rejectsCorrectDelete { return .init(status: 412) }
                    if ifMatch != current, !quirks.bogusDeleteRemoves { return .init(status: 412) }
                }
                objects[path] = nil
                return .init(status: 204)
            default:
                return .init(status: 400)
            }
        }
    }

    private func serve(_ server: Server) {
        StubURLProtocol.reset { try server.handle($0) }
    }

    private func methods(_ path: String) -> [String] {
        StubURLProtocol.requests.filter { $0.request.url!.path.hasSuffix(path) }.map { $0.request.httpMethod! }
    }

    // MARK: - Sent once

    func testConditionalPutWithDroppedResponseIsSentOnceAndInDoubt() async throws {
        let server = Server()
        server.dropResponse = { $0.httpMethod == "PUT" && $0.url!.path.hasSuffix("/k") }
        serve(server)
        let backend = makeBackend(verifyConditionals: false)
        do {
            try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: true)
            XCTFail("expected .network")
        } catch StorageError.network {}
        XCTAssertEqual(methods("/k"), ["PUT"])

        do {
            try await backend.put("k", data: Data([2]), ifMatch: "v1", ifNoneMatch: false)
            XCTFail("expected .network")
        } catch StorageError.network {}
        XCTAssertEqual(methods("/k"), ["PUT", "PUT"])
    }

    func testConditionalDeleteWithDroppedResponseIsSentOnce() async throws {
        let server = Server()
        serve(server)
        let backend = makeBackend(verifyConditionals: false)
        let etag = try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: false)
        server.dropResponse = { $0.httpMethod == "DELETE" }
        do {
            try await backend.delete("k", ifMatch: etag)
            XCTFail("expected .network")
        } catch StorageError.network {}
        XCTAssertEqual(methods("/k"), ["PUT", "DELETE"])
    }

    func testUnconditionalRequestsWithDroppedResponseAreRetried() async throws {
        let server = Server()
        let lock = NSLock()
        var dropped = 0
        server.dropResponse = { _ in lock.withLock { dropped += 1; return dropped == 1 || dropped == 3 } }
        serve(server)
        let backend = makeBackend(verifyConditionals: false)
        try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: false)
        _ = try await backend.get("k")
        XCTAssertEqual(methods("/k"), ["PUT", "PUT", "GET", "GET"])
    }

    // MARK: - Fallback

    func testFallbackPreWriteMismatchIsDefiniteWithNoPut() async throws {
        let server = Server(Quirks(conditionalPut501: true))
        serve(server)
        let backend = makeBackend(verifyConditionals: false)
        try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: false)
        do {
            try await backend.put("k", data: Data([2]), ifMatch: "stale", ifNoneMatch: false)
            XCTFail("expected preconditionFailed")
        } catch StorageError.preconditionFailed {}
        XCTAssertEqual(methods("/k"), ["PUT", "PUT", "HEAD"], "the 501, then the check; no write")
    }

    func testFallbackVerifyMismatchAfterPutIsInDoubt() async throws {
        let lock = NSLock()
        var puts = 0
        StubURLProtocol.reset { request in
            lock.lock(); defer { lock.unlock() }
            switch request.httpMethod {
            case "PUT" where request.value(forHTTPHeaderField: "If-None-Match") != nil:
                return .init(status: 501)
            case "HEAD":
                return puts == 0 ? .init(status: 404) : .init(status: 200, headers: ["ETag": "\"theirs\""])
            default:
                puts += 1
                return .init(status: 200, headers: ["ETag": "\"mine\""])
            }
        }
        do {
            try await makeBackend(verifyConditionals: false).put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: true)
            XCTFail("expected .network")
        } catch StorageError.network(let message) {
            XCTAssertEqual(message, "unverified conditional write")
        }
    }

    // MARK: - Canary

    private func capabilities(_ quirks: Quirks) async throws -> (writes: Bool, deletes: Bool, backend: S3Backend) {
        serve(Server(quirks))
        let backend = makeBackend()
        let writes = await backend.atomicConditionalWrites()
        let deletes = await backend.atomicConditionalDelete()
        return (writes, deletes, backend)
    }

    func testCompliantProviderPassesBothParts() async throws {
        let result = try await capabilities(Quirks())
        XCTAssertTrue(result.writes)
        XCTAssertTrue(result.deletes)
        XCTAssertTrue(result.backend.conditionalWritesSupported)
        let canary = StubURLProtocol.requests.filter { $0.request.url!.path.contains("noteit/.canary/") }
        XCTAssertEqual(canary.map { $0.request.httpMethod! },
                       ["PUT", "PUT", "PUT", "PUT", "PUT", "DELETE", "HEAD", "DELETE", "HEAD"], "the canary runs once")
        _ = await result.backend.atomicConditionalWrites()
        XCTAssertEqual(StubURLProtocol.requests.count, canary.count, "cached for the session")
    }

    func testWriteStepFailuresEachClearAtomicWrites() async throws {
        let cases: [(String, Quirks)] = [
            ("ignores If-None-Match", Quirks(ignoresNoneMatch: true)),
            ("ignores If-Match", Quirks(ignoresMatch: true)),
            ("501", Quirks(conditionalPut501: true)),
            ("reissues the first ETag", Quirks(reissuesETag: true)),
            ("accepts the old ETag", Quirks(acceptsOldETag: true)),
        ]
        for (name, quirks) in cases {
            let result = try await capabilities(quirks)
            XCTAssertFalse(result.writes, name)
            XCTAssertFalse(result.backend.conditionalWritesSupported, name)
            XCTAssertTrue(result.deletes, "\(name): the delete steps decide deletes")
        }
    }

    func testDeleteStepFailuresEachClearAtomicDelete() async throws {
        let cases: [(String, Quirks)] = [
            ("bogus If-Match removes", Quirks(bogusDeleteRemoves: true)),
            ("501", Quirks(conditionalDelete501: true)),
            ("rejects the right ETag", Quirks(rejectsCorrectDelete: true)),
        ]
        for (name, quirks) in cases {
            let result = try await capabilities(quirks)
            XCTAssertFalse(result.deletes, name)
            XCTAssertTrue(result.writes, "\(name): the write steps decide writes")
            XCTAssertFalse(result.backend.conditionalDeletesSupported, name)

            let before = StubURLProtocol.requests.count
            do {
                try await result.backend.delete("k", ifMatch: "any")
                XCTFail("\(name): expected conditionalDeleteUnsupported")
            } catch StorageError.conditionalDeleteUnsupported(let key) {
                XCTAssertEqual(key, "k")
            }
            XCTAssertEqual(StubURLProtocol.requests.count, before, "\(name): no HEAD and no DELETE")
        }
    }

    func testCanaryNetworkFailureLeavesBothFalseAndRunsAgain() async throws {
        let lock = NSLock()
        var failing = true
        let server = Server()
        StubURLProtocol.reset { request in
            if lock.withLock({ failing }) { return .init(status: 503) }
            return try server.handle(request)
        }
        let backend = makeBackend()
        let writes = await backend.atomicConditionalWrites()
        let deletes = await backend.atomicConditionalDelete()
        XCTAssertFalse(writes)
        XCTAssertFalse(deletes)
        lock.withLock { failing = false }
        let writesNow = await backend.atomicConditionalWrites()
        XCTAssertTrue(writesNow, "the canary ran again")
    }

    func testMidSession501OnConditionalDeleteStopsSendingThem() async throws {
        let lock = NSLock()
        var refuse = false
        let server = Server()
        StubURLProtocol.reset { request in
            if request.httpMethod == "DELETE", request.value(forHTTPHeaderField: "If-Match") != nil, lock.withLock({ refuse }) {
                return .init(status: 501)
            }
            return try server.handle(request)
        }
        let backend = makeBackend()
        let deletes = await backend.atomicConditionalDelete()
        XCTAssertTrue(deletes)
        let etag = try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: true)
        lock.withLock { refuse = true }
        do {
            try await backend.delete("k", ifMatch: etag)
            XCTFail("expected conditionalDeleteUnsupported")
        } catch StorageError.conditionalDeleteUnsupported {}
        let deletesNow = await backend.atomicConditionalDelete()
        XCTAssertFalse(deletesNow)
        let before = StubURLProtocol.requests.count
        do {
            try await backend.delete("k", ifMatch: etag)
            XCTFail("expected conditionalDeleteUnsupported")
        } catch StorageError.conditionalDeleteUnsupported {}
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }

    func testWithoutVerificationNothingIsAtomic() async {
        serve(Server())
        let backend = makeBackend(verifyConditionals: false)
        let writes = await backend.atomicConditionalWrites()
        let deletes = await backend.atomicConditionalDelete()
        XCTAssertFalse(writes)
        XCTAssertFalse(deletes)
    }

    func testListReadsLastModified() async throws {
        StubURLProtocol.reset { _ in
            .init(status: 200, body: Data("""
            <ListBucketResult><IsTruncated>false</IsTruncated>\
            <Contents><Key>a</Key><ETag>"1"</ETag><Size>1</Size><LastModified>2026-10-01T12:00:00.000Z</LastModified></Contents>\
            <Contents><Key>b</Key><ETag>"2"</ETag><Size>1</Size></Contents></ListBucketResult>
            """.utf8))
        }
        let objects = try await makeBackend(verifyConditionals: false).list(prefix: "")
        XCTAssertEqual(objects.first?.lastModified, ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))
        XCTAssertNil(objects.last?.lastModified)
    }

    func testRemoteObjectDecodesWithoutLastModified() throws {
        let object = try JSONDecoder().decode(RemoteObject.self, from: Data(#"{"key":"k","etag":"e","size":3}"#.utf8))
        XCTAssertNil(object.lastModified)
    }
}
