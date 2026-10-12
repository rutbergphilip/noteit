import XCTest
@testable import InkwellSync

final class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }

    struct Recorded {
        var request: URLRequest
        var body: Data
    }

    private static let lock = NSLock()
    private static var responder: ((URLRequest) throws -> Response)?
    private static var recorded: [Recorded] = []

    static func reset(_ handler: @escaping (URLRequest) throws -> Response) {
        lock.lock(); defer { lock.unlock() }
        responder = handler
        recorded = []
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.recorded.append(Recorded(request: request, body: body))
        let handler = Self.responder
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unknown) }
            let response = try handler(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class S3BackendTests: XCTestCase {
    private let credentials = S3Credentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret/key")

    private func makeBackend(pathStyle: Bool = true, prefix: String = "", endpoint: String = "http://localhost:9000") -> S3Backend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let config = S3Config(endpoint: URL(string: endpoint)!, region: "eu-north-1", bucket: "notes", pathStyle: pathStyle, prefix: prefix)
        return S3Backend(
            config: config,
            credentials: credentials,
            session: URLSession(configuration: configuration),
            retryDelays: [0, 0],
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private func listXML(_ keys: [String], truncated: Bool, token: String? = nil) -> Data {
        let contents = keys.map { "<Contents><Key>\($0)</Key><ETag>&quot;e-\($0)&quot;</ETag><Size>3</Size></Contents>" }.joined()
        let tokenXML = token.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
        return Data("<ListBucketResult><IsTruncated>\(truncated)</IsTruncated>\(tokenXML)\(contents)</ListBucketResult>".utf8)
    }

    private func errorXML(_ code: String, _ message: String) -> Data {
        Data("<Error><Code>\(code)</Code><Message>\(message)</Message></Error>".utf8)
    }

    func testListPaginatesTwoPages() async throws {
        StubURLProtocol.reset { request in
            let q = self.query(request)
            if q["continuation-token"] == nil {
                return .init(status: 200, body: self.listXML(["inkwell/v1/a", "inkwell/v1/b"], truncated: true, token: "tok+/="))
            }
            XCTAssertEqual(q["continuation-token"], "tok+/=")
            return .init(status: 200, body: self.listXML(["inkwell/v1/c"], truncated: false))
        }
        let objects = try await makeBackend().list(prefix: "inkwell/v1/")
        XCTAssertEqual(objects.map(\.key), ["inkwell/v1/a", "inkwell/v1/b", "inkwell/v1/c"])
        XCTAssertEqual(objects.first?.etag, "e-inkwell/v1/a")
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(query(requests[0].request)["list-type"], "2")
        XCTAssertEqual(query(requests[0].request)["prefix"], "inkwell/v1/")
        XCTAssertTrue(requests[0].request.url!.absoluteString.hasPrefix("http://localhost:9000/notes/?"))
    }

    func testPrefixIsPrependedAndStripped() async throws {
        StubURLProtocol.reset { request in
            if request.httpMethod == "GET" {
                return .init(status: 200, body: self.listXML(["sub/dir/inkwell/v1/x"], truncated: false))
            }
            return .init(status: 200, headers: ["ETag": "\"new\""])
        }
        let backend = makeBackend(prefix: "/sub/dir/")
        let objects = try await backend.list(prefix: "inkwell/v1/")
        XCTAssertEqual(objects.map(\.key), ["inkwell/v1/x"])
        let etag = try await backend.put("inkwell/v1/y", data: Data("hi".utf8), ifMatch: nil, ifNoneMatch: false)
        XCTAssertEqual(etag, "new")
        let requests = StubURLProtocol.requests
        XCTAssertEqual(query(requests[0].request)["prefix"], "sub/dir/inkwell/v1/")
        XCTAssertEqual(requests[1].request.url?.absoluteString, "http://localhost:9000/notes/sub/dir/inkwell/v1/y")
        XCTAssertEqual(requests[1].body, Data("hi".utf8))
        XCTAssertEqual(requests[1].request.value(forHTTPHeaderField: "x-amz-content-sha256"), SigV4Signer.sha256Hex(Data("hi".utf8)))
    }

    func testPathStyleAndVirtualHostURLs() throws {
        let path = try makeBackend(pathStyle: true, endpoint: "https://s3.example.com").makeURL(key: "inkwell/v1/a b.meta")
        XCTAssertEqual(path.absoluteString, "https://s3.example.com/notes/inkwell/v1/a%20b.meta")
        let virtual = try makeBackend(pathStyle: false, endpoint: "https://s3.example.com:8443").makeURL(key: "inkwell/v1/a")
        XCTAssertEqual(virtual.absoluteString, "https://notes.s3.example.com:8443/inkwell/v1/a")
    }

    func testGetReturnsDataAndUnquotedETag() async throws {
        StubURLProtocol.reset { _ in .init(status: 200, headers: ["ETag": "\"abc\""], body: Data([1, 2, 3])) }
        let got = try await makeBackend(pathStyle: false).get("inkwell/v1/k")
        XCTAssertEqual(got.data, Data([1, 2, 3]))
        XCTAssertEqual(got.etag, "abc")
        XCTAssertEqual(StubURLProtocol.requests[0].request.url?.host, "notes.localhost")
    }

    func testAuthorizationHeaderFormat() async throws {
        StubURLProtocol.reset { _ in .init(status: 200, headers: ["ETag": "\"x\""]) }
        try await makeBackend().put("k", data: Data("a".utf8), ifMatch: "old", ifNoneMatch: false)
        let request = StubURLProtocol.requests[0].request
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        let pattern = #"^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20231114/eu-north-1/s3/aws4_request, SignedHeaders=host;if-match;x-amz-content-sha256;x-amz-date, Signature=[0-9a-f]{64}$"#
        XCTAssertNotNil(auth.range(of: pattern, options: .regularExpression), auth)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"old\"")
        XCTAssertFalse(auth.contains("secret"))
    }

    func testIfNoneMatchHeaderAnd412Mapping() async throws {
        StubURLProtocol.reset { _ in .init(status: 412, body: self.errorXML("PreconditionFailed", "At least one of the pre-conditions you specified did not hold")) }
        do {
            try await makeBackend().put("k", data: Data(), ifMatch: nil, ifNoneMatch: true)
            XCTFail("Expected preconditionFailed")
        } catch let error as StorageError {
            XCTAssertEqual(error, .preconditionFailed("k"))
        }
        XCTAssertEqual(StubURLProtocol.requests[0].request.value(forHTTPHeaderField: "If-None-Match"), "*")
    }

    func testForbiddenMapsToUnauthorizedWithMessage() async throws {
        StubURLProtocol.reset { _ in .init(status: 403, body: self.errorXML("SignatureDoesNotMatch", "The request signature we calculated does not match")) }
        do {
            try await makeBackend().probe()
            XCTFail("Expected unauthorized")
        } catch let error as StorageError {
            XCTAssertEqual(error, .unauthorized("SignatureDoesNotMatch: The request signature we calculated does not match"))
        }
        XCTAssertEqual(query(StubURLProtocol.requests[0].request)["max-keys"], "1")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testNotFound() async throws {
        StubURLProtocol.reset { _ in .init(status: 404, body: self.errorXML("NoSuchKey", "nope")) }
        do {
            _ = try await makeBackend().get("missing")
            XCTFail("Expected notFound")
        } catch let error as StorageError {
            XCTAssertEqual(error, .notFound("missing"))
        }
    }

    func testServerErrorsRetriedTwiceThenNetwork() async throws {
        StubURLProtocol.reset { _ in .init(status: 503, body: self.errorXML("SlowDown", "Reduce your request rate")) }
        do {
            try await makeBackend().delete("k")
            XCTFail("Expected network")
        } catch let error as StorageError {
            XCTAssertEqual(error, .network("SlowDown: Reduce your request rate"))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
    }

    func testTransportErrorRetriedThenSucceeds() async throws {
        var calls = 0
        let lock = NSLock()
        StubURLProtocol.reset { _ in
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if calls == 1 { throw URLError(.networkConnectionLost) }
            return .init(status: 204)
        }
        try await makeBackend().delete("k")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(StubURLProtocol.requests[1].request.httpMethod, "DELETE")
    }

    func testOtherStatusIsInvalidResponse() async throws {
        StubURLProtocol.reset { _ in .init(status: 301, body: self.errorXML("PermanentRedirect", "Use the right endpoint")) }
        do {
            _ = try await makeBackend().get("k")
            XCTFail("Expected invalidResponse")
        } catch let error as StorageError {
            XCTAssertEqual(error, .invalidResponse("PermanentRedirect: Use the right endpoint"))
        }
    }

    func testConditionalNotImplementedFallsBackToHeadThenPut() async throws {
        StubURLProtocol.reset { request in
            switch request.httpMethod {
            case "PUT" where request.value(forHTTPHeaderField: "If-None-Match") != nil:
                return .init(status: 501, body: self.errorXML("NotImplemented", "A header you provided implies functionality that is not implemented"))
            case "HEAD":
                return .init(status: 404)
            default:
                return .init(status: 200, headers: ["ETag": "\"v1\""])
            }
        }
        let backend = makeBackend()
        let etag = try await backend.put("k", data: Data([1]), ifMatch: nil, ifNoneMatch: true)
        XCTAssertEqual(etag, "v1")
        XCTAssertFalse(backend.conditionalWritesSupported)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.request.httpMethod }, ["PUT", "HEAD", "PUT"])
        XCTAssertNil(StubURLProtocol.requests[2].request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testFallbackHeadDetectsStaleETag() async throws {
        StubURLProtocol.reset { request in
            switch request.httpMethod {
            case "PUT" where request.value(forHTTPHeaderField: "If-Match") != nil:
                return .init(status: 400, body: self.errorXML("NotImplemented", "nope"))
            case "HEAD": return .init(status: 200, headers: ["ETag": "\"current\""])
            default: return .init(status: 200, headers: ["ETag": "\"next\""])
            }
        }
        let backend = makeBackend()
        do {
            try await backend.put("k", data: Data([1]), ifMatch: "stale", ifNoneMatch: false)
            XCTFail("Expected preconditionFailed")
        } catch let error as StorageError {
            XCTAssertEqual(error, .preconditionFailed("k"))
        }
        XCTAssertEqual(StubURLProtocol.requests.map { $0.request.httpMethod }, ["PUT", "HEAD"])

        try await backend.put("k", data: Data([2]), ifMatch: "current", ifNoneMatch: false)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.request.httpMethod }, ["PUT", "HEAD", "HEAD", "PUT"])
        XCTAssertNil(StubURLProtocol.requests[3].request.value(forHTTPHeaderField: "If-Match"))
    }
}
