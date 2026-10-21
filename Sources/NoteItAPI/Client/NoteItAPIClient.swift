import Foundation

/// A non-2xx response. `code` is nil when the body isn't an `APIErrorBody`.
public struct NoteItAPIError: Error, Sendable, Equatable, LocalizedError {
    public var status: Int
    public var code: APIErrorCode?
    public var message: String

    public init(status: Int, code: APIErrorCode?, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    /// From a non-2xx response body: its `APIErrorBody`, or else the start of the body as the message.
    public init(status: Int, body: Data) {
        if let decoded = try? APIJSON.decoder().decode(APIErrorBody.self, from: body) {
            self.init(status: status, code: decoded.error.code, message: decoded.error.message)
            return
        }
        let text = String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(status: status, code: nil,
                  message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text)
    }
}

/// The response type for routes that answer `204 No Content`.
public struct APINoContent: Codable, Sendable, Equatable {
    public init() {}
}

/// A Local API client. `baseURL` is the API root including `/v1` (as in `DiscoveryFile.baseURL`); paths such as
/// `/notes` are appended to it.
public struct NoteItAPIClient: Sendable {
    public let baseURL: URL
    public let token: String?
    public let session: URLSession

    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func send<T: Decodable>(_ method: HTTPMethod, _ path: String, query: [String: String] = [:],
                                   json: (any Encodable)? = nil, headers: [String: String] = [:],
                                   as type: T.Type) async throws -> T {
        var body: Data?
        var allHeaders = headers
        if let json {
            body = try APIJSON.encoder().encode(json)
            allHeaders["Content-Type"] = "application/json"
        }
        let (status, data) = try await sendRaw(method, path, query: query, body: body, headers: allHeaders)
        guard (200..<300).contains(status) else { throw NoteItAPIError(status: status, body: data) }
        if T.self == APINoContent.self, let empty = APINoContent() as? T { return empty }
        return try APIJSON.decoder().decode(T.self, from: data)
    }

    /// Any status; throws only for transport errors.
    public func sendRaw(_ method: HTTPMethod, _ path: String, query: [String: String] = [:], body: Data?,
                        headers: [String: String] = [:]) async throws -> (Int, Data) {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method.rawValue
        request.httpBody = body
        authorize(&request)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }

    /// `GET /events` as a stream of changes. When the connection drops it reconnects once, sending the last
    /// cursor in `Last-Event-ID`. A `revoked` event ends the stream with `token_revoked`.
    public func events(since cursor: String?) -> AsyncThrowingStream<ChangeDTO, Error> {
        let client = self
        return Self.events(since: cursor) { lastEventID in try await client.openEventStream(lastEventID: lastEventID) }
    }

    /// The reconnecting SSE loop over any source of lines; `connect` gets the cursor to resume after.
    static func events(since cursor: String?,
                       connect: @escaping @Sendable (String?) async throws -> AsyncThrowingStream<String, Error>)
        -> AsyncThrowingStream<ChangeDTO, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastEventID = cursor
                var reconnected = false
                while true {
                    var parser = SSEParser()
                    var dropError: Error?
                    do {
                        let lines = try await connect(lastEventID)
                        for try await line in lines {
                            guard let event = parser.feed(line) else { continue }
                            if let id = event.id { lastEventID = id }
                            switch event.type {
                            case "change":
                                continuation.yield(try APIJSON.decoder().decode(ChangeDTO.self, from: Data(event.data.utf8)))
                            case "revoked":
                                continuation.finish(throwing: NoteItAPIError(status: 401, code: .tokenRevoked,
                                                                             message: "This token was revoked."))
                                return
                            default:
                                continue
                            }
                        }
                    } catch let error as NoteItAPIError {
                        continuation.finish(throwing: error)
                        return
                    } catch is DecodingError {
                        continuation.finish(throwing: NoteItAPIError(status: 200, code: nil,
                                                                     message: "The event stream sent a change that couldn't be read."))
                        return
                    } catch {
                        dropError = error
                    }
                    if Task.isCancelled || reconnected {
                        continuation.finish(throwing: Task.isCancelled ? nil : dropError)
                        return
                    }
                    reconnected = true
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openEventStream(lastEventID: String?) async throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: url("/events", query: [:]))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        authorize(&request)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 65_536 { break }
            }
            throw NoteItAPIError(status: http.statusCode, body: data)
        }
        // AsyncBytes.lines skips empty lines, and an empty line is what ends an SSE event.
        return AsyncThrowingStream { continuation in
            let task = Task {
                var line = [UInt8]()
                do {
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if line.last == UInt8(ascii: "\r") { line.removeLast() }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The token only ever goes to this Mac.
    private func authorize(_ request: inout URLRequest) {
        guard let token, let url = request.url, Self.isLoopback(url) else { return }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }

    /// `127.0.0.1`, `localhost` or `[::1]`.
    public static func isLoopback(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    func url(_ path: String, query: [String: String]) -> URL {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        text += path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            text += "?" + query.sorted { $0.key < $1.key }
                .map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }
                .joined(separator: "&")
        }
        return URL(string: text) ?? baseURL
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything outside the unreserved set, `+` included (the server reads `+` as a space).
    public static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }
}

/// One Server-Sent Event.
struct SSEEvent: Equatable, Sendable {
    var id: String?
    var type: String
    var data: String
}

/// Takes SSE lines without their line endings; an empty line dispatches the event built so far.
struct SSEParser {
    private var id: String?
    private var type: String?
    private var data: [String] = []

    mutating func feed(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { id = nil; type = nil; data = [] }
            guard type != nil || !data.isEmpty else { return nil }
            return SSEEvent(id: id, type: type ?? "message", data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "id": id = String(value)
        case "event": type = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}
