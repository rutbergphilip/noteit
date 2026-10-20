import Foundation

// HTTP/1.1 message values for the Local API server. Shapes owned by the automation plan; built in foundations
// Task 5.1.

/// Header fields in order. Lookup is case-insensitive; setting replaces every field with that name, and setting
/// nil removes them.
public struct HTTPHeaders: Sendable, Equatable {
    public var pairs: [(String, String)]

    public init(_ pairs: [(String, String)] = []) {
        self.pairs = pairs
    }

    public subscript(_ name: String) -> String? {
        get { pairs.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }
        set {
            let index = pairs.firstIndex { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            pairs.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            guard let newValue else { return }
            pairs.insert((name, newValue), at: min(index ?? pairs.count, pairs.count))
        }
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.pairs.count == rhs.pairs.count && zip(lhs.pairs, rhs.pairs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: HTTPHeaders
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: HTTPHeaders = HTTPHeaders(),
                body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: Data

    public init(status: Int, headers: HTTPHeaders = HTTPHeaders(), body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        guard let body = try? APIJSON.encoder().encode(value) else {
            return error(.internal, "The response couldn't be encoded.")
        }
        return HTTPResponse(status: status, headers: HTTPHeaders([("Content-Type", jsonContentType)]), body: body)
    }

    public static func error(_ code: APIErrorCode, _ message: String) -> HTTPResponse {
        let body = (try? APIJSON.encoder().encode(APIErrorBody(code: code, message: message))) ?? Data()
        return HTTPResponse(status: code.httpStatus, headers: HTTPHeaders([("Content-Type", jsonContentType)]),
                            body: body)
    }

    /// `HTTP/1.1 <status> <reason>`, then the headers with `Content-Length`, `Cache-Control: no-store`,
    /// `X-Content-Type-Options: nosniff` and `Connection` set, then the body.
    public func serialized(keepAlive: Bool) -> Data {
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Cache-Control"] = "no-store"
        fields["X-Content-Type-Options"] = "nosniff"
        fields["Connection"] = keepAlive ? "keep-alive" : "close"
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        for (name, value) in fields.pairs {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static let jsonContentType = "application/json; charset=utf-8"

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 423: "Locked"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}
