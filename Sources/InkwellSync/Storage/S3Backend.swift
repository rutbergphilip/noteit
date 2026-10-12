import Foundation

public struct S3Config: Codable, Sendable, Equatable {
    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var pathStyle: Bool
    /// Optional sub-folder inside the bucket, prepended to every key.
    public var prefix: String

    public init(endpoint: URL, region: String, bucket: String, pathStyle: Bool, prefix: String = "") {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.pathStyle = pathStyle
        self.prefix = prefix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try c.decode(URL.self, forKey: .endpoint)
        region = try c.decode(String.self, forKey: .region)
        bucket = try c.decode(String.self, forKey: .bucket)
        pathStyle = try c.decode(Bool.self, forKey: .pathStyle)
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
    }
}

public final class S3Backend: StorageBackend, @unchecked Sendable {
    public let config: S3Config
    private let credentials: S3Credentials
    private let session: URLSession
    private let retryDelays: [TimeInterval]
    private let now: @Sendable () -> Date
    private let keyPrefix: String
    private let lock = NSLock()
    private var _conditionalWritesSupported = true

    public var conditionalWritesSupported: Bool {
        lock.withLock { _conditionalWritesSupported }
    }

    private func markConditionalWritesUnsupported() {
        lock.withLock { _conditionalWritesSupported = false }
    }

    public init(
        config: S3Config,
        credentials: S3Credentials,
        session: URLSession = .shared,
        retryDelays: [TimeInterval] = [0.5, 1.5],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.credentials = credentials
        self.session = session
        self.retryDelays = retryDelays
        self.now = now
        let trimmed = config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        keyPrefix = trimmed.isEmpty ? "" : trimmed + "/"
    }

    // MARK: - StorageBackend

    public func list(prefix: String) async throws -> [RemoteObject] {
        var results: [RemoteObject] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", keyPrefix + prefix)]
            if let token { query.append(("continuation-token", token)) }
            let (data, _) = try await send(method: "GET", key: nil, query: query)
            let page = try S3ListParser.parse(data)
            for object in page.objects where object.key.hasPrefix(keyPrefix) {
                results.append(RemoteObject(key: String(object.key.dropFirst(keyPrefix.count)), etag: object.etag, size: object.size))
            }
            guard page.isTruncated else { break }
            guard let next = page.nextContinuationToken else {
                throw StorageError.invalidResponse("Truncated list without continuation token")
            }
            token = next
        } while true
        return results
    }

    public func get(_ key: String) async throws -> (data: Data, etag: String) {
        let (data, response) = try await send(method: "GET", key: key)
        return (data, etag(from: response))
    }

    @discardableResult
    public func put(_ key: String, data: Data, ifMatch: String?, ifNoneMatch: Bool) async throws -> String {
        let conditional = ifMatch != nil || ifNoneMatch
        if conditional, conditionalWritesSupported {
            var headers: [String: String] = [:]
            if ifNoneMatch { headers["If-None-Match"] = "*" }
            if let ifMatch { headers["If-Match"] = "\"\(ifMatch)\"" }
            do {
                return try await upload(key, data: data, headers: headers)
            } catch S3Failure.conditionalNotSupported {
                markConditionalWritesUnsupported()
            }
        }
        guard conditional else { return try await upload(key, data: data, headers: [:]) }
        try await checkPreconditions(key, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
        let tag = try await upload(key, data: data, headers: [:])
        try await verifyUnconditionalWrite(key, expected: tag)
        return tag
    }

    public func delete(_ key: String) async throws {
        _ = try await send(method: "DELETE", key: key)
    }

    public func probe() async throws {
        let query = [("list-type", "2"), ("max-keys", "1"), ("prefix", keyPrefix)]
        let (data, _) = try await send(method: "GET", key: nil, query: query)
        _ = try S3ListParser.parse(data)
    }

    // MARK: - Requests

    private enum S3Failure: Error { case conditionalNotSupported }

    private func upload(_ key: String, data: Data, headers: [String: String]) async throws -> String {
        let (_, response) = try await send(method: "PUT", key: key, body: data, headers: headers, conditional: !headers.isEmpty)
        let tag = etag(from: response)
        if !tag.isEmpty { return tag }
        let (_, head) = try await send(method: "HEAD", key: key)
        return etag(from: head)
    }

    private func checkPreconditions(_ key: String, ifMatch: String?, ifNoneMatch: Bool) async throws {
        var current: String?
        do {
            let (_, head) = try await send(method: "HEAD", key: key)
            current = etag(from: head)
        } catch StorageError.notFound {
            current = nil
        }
        if ifNoneMatch, current != nil { throw StorageError.preconditionFailed(key) }
        if let ifMatch, current != ifMatch { throw StorageError.preconditionFailed(key) }
    }

    /// HEAD+PUT isn't atomic: if another writer landed in between, report a lost race so the caller re-decides.
    private func verifyUnconditionalWrite(_ key: String, expected: String) async throws {
        let current: String
        do {
            current = etag(from: try await send(method: "HEAD", key: key).1)
        } catch StorageError.notFound {
            throw StorageError.preconditionFailed(key)
        }
        if current != expected { throw StorageError.preconditionFailed(key) }
    }

    private func send(
        method: String,
        key: String?,
        query: [(String, String)] = [],
        body: Data? = nil,
        headers: [String: String] = [:],
        conditional: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try makeURL(key: key.map { keyPrefix + $0 }, query: query)
        let payloadHash = body.map(SigV4Signer.sha256Hex) ?? SigV4Signer.emptyPayloadSHA256
        let label = key ?? "/"
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.cachePolicy = .reloadIgnoringLocalCacheData
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.httpBody = body
            SigV4Signer.sign(request: &request, payloadSHA256: payloadHash, credentials: credentials, region: config.region, service: "s3", date: now())

            let outcome: Result<(Data, HTTPURLResponse), StorageError>
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw StorageError.invalidResponse("Non-HTTP response for \(label)")
                }
                outcome = try classify(data: data, response: http, label: label, conditional: conditional)
            } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
                outcome = .failure(.insecureConnectionBlocked(error.localizedDescription))
            } catch let error as URLError {
                outcome = .failure(.network(error.localizedDescription))
            }

            switch outcome {
            case .success(let value):
                return value
            case .failure(let error):
                guard case .network = error, attempt < retryDelays.count else { throw error }
                let delay = retryDelays[attempt]
                attempt += 1
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
        }
    }

    private func classify(data: Data, response: HTTPURLResponse, label: String, conditional: Bool) throws -> Result<(Data, HTTPURLResponse), StorageError> {
        let status = response.statusCode
        if (200..<300).contains(status) { return .success((data, response)) }
        let body = S3ListParser.parseError(data)
        let detail = body.map { "\($0.code): \($0.message)" } ?? "HTTP \(status)"
        if conditional, status == 501 || (status == 400 && body?.code == "NotImplemented") {
            throw S3Failure.conditionalNotSupported
        }
        switch body?.code {
        case "RequestTimeTooSkewed": return .failure(.clockSkew(detail))
        case "InvalidAccessKeyId", "SignatureDoesNotMatch": return .failure(.unauthorized(detail))
        default: break
        }
        switch status {
        case 404: return .failure(.notFound(label))
        case 412: return .failure(.preconditionFailed(label))
        case 409 where conditional: return .failure(.preconditionFailed(label))
        case 401, 403: return .failure(.unauthorized(detail))
        case 500..<600: return .failure(.network(detail))
        default: return .failure(.invalidResponse(detail))
        }
    }

    private func etag(from response: HTTPURLResponse) -> String {
        S3ListParser.stripQuotes(response.value(forHTTPHeaderField: "ETag") ?? "")
    }

    func makeURL(key: String?, query: [(String, String)] = []) throws -> URL {
        guard var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false), components.host != nil else {
            throw StorageError.invalidResponse("Invalid endpoint \(config.endpoint.absoluteString)")
        }
        let encodedKey = key.map { SigV4Signer.uriEncode($0, encodeSlash: false) } ?? ""
        let basePath = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        if config.pathStyle {
            components.percentEncodedPath = basePath + "/" + SigV4Signer.uriEncode(config.bucket) + "/" + encodedKey
        } else {
            components.host = config.bucket + "." + components.host!
            components.percentEncodedPath = basePath + "/" + encodedKey
        }
        components.percentEncodedQuery = query.isEmpty ? nil : query
            .map { "\(SigV4Signer.uriEncode($0.0))=\(SigV4Signer.uriEncode($0.1))" }
            .joined(separator: "&")
        guard let url = components.url else {
            throw StorageError.invalidResponse("Could not build URL for \(key ?? "/")")
        }
        return url
    }
}
