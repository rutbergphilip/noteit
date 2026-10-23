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
    private var _conditionalDeletesSupported = true
    /// Set only when the canary's write steps (or delete steps) passed in this session (sync-security Task 3.0).
    private var writePassed = false
    private var deletePassed = false
    private let verifiesConditionals: Bool
    private var conditionalCheck: Task<Void, Never>?

    public var conditionalWritesSupported: Bool {
        lock.withLock { _conditionalWritesSupported }
    }

    public var conditionalDeletesSupported: Bool {
        lock.withLock { _conditionalDeletesSupported }
    }

    private func markConditionalWritesUnsupported() {
        lock.withLock { _conditionalWritesSupported = false }
    }

    private func markConditionalDeletesUnsupported() {
        lock.withLock { _conditionalDeletesSupported = false }
    }

    public init(
        config: S3Config,
        credentials: S3Credentials,
        session: URLSession = .shared,
        retryDelays: [TimeInterval] = [0.5, 1.5],
        now: @escaping @Sendable () -> Date = { Date() },
        verifyConditionals: Bool = true
    ) {
        verifiesConditionals = verifyConditionals
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
                results.append(RemoteObject(key: String(object.key.dropFirst(keyPrefix.count)), etag: object.etag, size: object.size,
                                            lastModified: object.lastModified))
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
        if conditional { await ensureConditionalsVerified() }
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

    /// No HEAD-then-DELETE fallback: a check followed by a plain DELETE removes whatever landed in between, so a
    /// store without conditional deletes gets nothing sent and `conditionalDeleteUnsupported` (web-app spec §3.4.9).
    public func delete(_ key: String, ifMatch: String?) async throws {
        guard let ifMatch else { return try await delete(key) }
        await ensureConditionalsVerified()
        guard conditionalDeletesSupported else { throw StorageError.conditionalDeleteUnsupported(key) }
        do {
            _ = try await send(method: "DELETE", key: key, headers: ["If-Match": "\"\(ifMatch)\""], conditional: true)
        } catch S3Failure.conditionalNotSupported {
            // Some providers support conditional PUT but not DELETE.
            markConditionalDeletesUnsupported()
            throw StorageError.conditionalDeleteUnsupported(key)
        }
    }

    public func atomicConditionalWrites() async -> Bool {
        await ensureConditionalsVerified()
        return lock.withLock { writePassed && _conditionalWritesSupported }
    }

    public func atomicConditionalDelete() async -> Bool {
        await ensureConditionalsVerified()
        return lock.withLock { deletePassed && _conditionalDeletesSupported }
    }

    public func probe() async throws {
        let query = [("list-type", "2"), ("max-keys", "1"), ("prefix", keyPrefix)]
        let (data, _) = try await send(method: "GET", key: nil, query: query)
        _ = try S3ListParser.parse(data)
    }

    // MARK: - Conditional request verification

    /// Some S3-compatible servers (e.g. the GCS XML API) accept If-Match/If-None-Match but silently ignore them,
    /// which would turn every conflict into a lost update. Probe once with a throwaway object before trusting them.
    private func ensureConditionalsVerified() async {
        guard verifiesConditionals else { return }
        let check: Task<Void, Never> = lock.withLock {
            if let conditionalCheck { return conditionalCheck }
            let task = Task { await self.runConditionalCanary() }
            conditionalCheck = task
            return task
        }
        await check.value
    }

    /// Write steps: create with `If-None-Match`, then it and a bogus `If-Match` must get 412; an `If-Match` overwrite
    /// with the first ETag must succeed with a different ETag, after which that ETag must get 412. Delete steps: a
    /// bogus `If-Match` DELETE must get 412 and leave the object; a DELETE with the current ETag must remove it.
    private func runConditionalCanary() async {
        let key = RemoteLayout.canaryPrefix + UUID().uuidString
        let bogus = ["If-Match": "\"\(RemoteLayout.canaryMismatchETag)\""]
        do {
            var writesHold = true
            do {
                let first = try await upload(key, data: Data("canary".utf8), headers: ["If-None-Match": "*"])
                let ignoresNoneMatch = try await accepts { _ = try await self.upload(key, data: Data("again".utf8), headers: ["If-None-Match": "*"]) }
                let ignoresMatch = try await accepts { _ = try await self.upload(key, data: Data("again".utf8), headers: bogus) }
                if ignoresNoneMatch || ignoresMatch {
                    writesHold = false
                } else {
                    writesHold = try await overwriteRetiresETag(key, first: first)
                }
            } catch S3Failure.conditionalNotSupported {
                writesHold = false
                _ = try await upload(key, data: Data("canary".utf8), headers: [:])
            }
            let deletesHold = try await conditionalDeleteHolds(key, bogus: bogus)
            if !writesHold { markConditionalWritesUnsupported() }
            if !deletesHold { markConditionalDeletesUnsupported() }
            lock.withLock {
                writePassed = writesHold
                deletePassed = deletesHold
            }
            // Passing delete steps removed the canary already.
            if !deletesHold { try? await delete(key) }
            if !conditionalWritesSupported || !conditionalDeletesSupported {
                NSLog("NoteItSync: %@ ignores conditional requests (writes=%d deletes=%d); using verified fallback",
                      config.endpoint.host ?? "endpoint", conditionalWritesSupported ? 1 : 0, conditionalDeletesSupported ? 1 : 0)
            }
        } catch {
            // Unreachable or unauthorized: real requests will surface the error; check again next time.
            try? await delete(key)
            lock.withLock { conditionalCheck = nil }
        }
    }

    /// An `If-Match` overwrite with `first` succeeds with a new ETag, and `first` stops matching afterwards.
    private func overwriteRetiresETag(_ key: String, first: String) async throws -> Bool {
        let second: String
        do {
            second = try await upload(key, data: Data("canary-2".utf8), headers: ["If-Match": "\"\(first)\""])
        } catch StorageError.preconditionFailed {
            return false
        } catch S3Failure.conditionalNotSupported {
            return false
        }
        guard second != first else { return false }
        return !(try await accepts { _ = try await self.upload(key, data: Data("canary-3".utf8), headers: ["If-Match": "\"\(first)\""]) })
    }

    /// The canary's delete steps; on success the canary is gone.
    private func conditionalDeleteHolds(_ key: String, bogus: [String: String]) async throws -> Bool {
        if try await accepts({ _ = try await self.send(method: "DELETE", key: key, headers: bogus, conditional: true) }) { return false }
        guard let current = try await headETag(key) else { return false }
        do {
            _ = try await send(method: "DELETE", key: key, headers: ["If-Match": "\"\(current)\""], conditional: true)
        } catch StorageError.preconditionFailed {
            return false
        } catch S3Failure.conditionalNotSupported {
            return false
        }
        return try await headETag(key) == nil
    }

    private func headETag(_ key: String) async throws -> String? {
        do {
            return etag(from: try await send(method: "HEAD", key: key).1)
        } catch StorageError.notFound {
            return nil
        }
    }

    /// True when the server performed a request whose precondition should have failed.
    private func accepts(_ request: () async throws -> Void) async throws -> Bool {
        do {
            try await request()
            return true
        } catch StorageError.preconditionFailed {
            return false
        } catch S3Failure.conditionalNotSupported {
            return true
        }
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

    /// HEAD+PUT isn't atomic: if another writer landed in between, the outcome is unknown. Our PUT was sent, so this
    /// is in doubt (`.network`), never a definite 412; only `checkPreconditions` gives one (web-app spec §3.4.9).
    private func verifyUnconditionalWrite(_ key: String, expected: String) async throws {
        guard try await headETag(key) == expected else { throw StorageError.network("unverified conditional write") }
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
                // A conditional request is sent once: a replay could land after a later decision (spec §3.4.9).
                guard case .network = error, !conditional, attempt < retryDelays.count else { throw error }
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
