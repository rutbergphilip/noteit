import Foundation

public struct HTTPParserLimits: Sendable {
    public var maxHeaderBytes = 16_384
    public var maxJSONBody = 2_000_000
    public var maxBinaryBody = 25_000_000

    public init(maxHeaderBytes: Int = 16_384, maxJSONBody: Int = 2_000_000, maxBinaryBody: Int = 25_000_000) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxJSONBody = maxJSONBody
        self.maxBinaryBody = maxBinaryBody
    }
}

public enum HTTPParseResult: Equatable {
    case needMore
    /// `consumed` bytes make up this request; anything after them belongs to the next (pipelined) request.
    case request(HTTPRequest, consumed: Int)
    case failure(status: Int, APIErrorCode)
}

/// An incremental HTTP/1.1 request parser. It doesn't know the route yet, so it applies the larger binary body
/// limit; the server re-checks each route's own limit after matching.
public struct HTTPParser: Sendable {
    public let limits: HTTPParserLimits

    public init(limits: HTTPParserLimits = .init()) {
        self.limits = limits
    }

    public func parse(_ buffer: Data) -> HTTPParseResult {
        // Only the head is copied; a large body arriving in many reads is never re-copied while it's incomplete.
        let scanned = [UInt8](buffer.prefix(limits.maxHeaderBytes + 4))
        guard let headEnd = Self.headEnd(in: scanned) else {
            if Self.hasBareLF(scanned[...]) { return .failure(status: 400, .badRequest) }
            return buffer.count > limits.maxHeaderBytes ? .failure(status: 431, .tooLarge) : .needMore
        }
        let head = scanned[..<headEnd]
        if Self.hasBareLF(head) { return .failure(status: 400, .badRequest) }
        guard let headText = String(bytes: head, encoding: .utf8) else { return .failure(status: 400, .badRequest) }

        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        guard let (method, path, query) = Self.parseRequestLine(requestLine) else {
            return .failure(status: 400, .badRequest)
        }

        var headers = HTTPHeaders()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failure(status: 400, .badRequest) }
            let name = String(line[..<colon])
            guard Self.isToken(name) else { return .failure(status: 400, .badRequest) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.pairs.append((name, value))
        }

        if headers["Transfer-Encoding"] != nil { return .failure(status: 411, .lengthRequired) }
        let bodyStart = headEnd + 4
        let lengths = headers.pairs.filter { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }.map(\.1)
        let contentLength: Int
        if let first = lengths.first {
            guard lengths.allSatisfy({ $0 == first }), !first.isEmpty, first.utf8.count <= 12,
                  first.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(first) else {
                return .failure(status: 400, .badRequest)
            }
            contentLength = value
        } else if (method == "POST" || method == "PATCH") && buffer.count > bodyStart {
            return .failure(status: 411, .lengthRequired)
        } else {
            contentLength = 0
        }
        if contentLength > max(limits.maxBinaryBody, limits.maxJSONBody) {
            return .failure(status: 413, .tooLarge)
        }
        guard buffer.count - bodyStart >= contentLength else { return .needMore }

        let start = buffer.startIndex + bodyStart
        let body = Data(buffer[start..<(start + contentLength)])
        let request = HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
        return .request(request, consumed: bodyStart + contentLength)
    }

    // MARK: - Pieces

    /// Index of the `\r\n\r\n` that ends the head.
    private static func headEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let last = bytes.count - 4
        var index = 0
        while index <= last {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func hasBareLF(_ bytes: ArraySlice<UInt8>) -> Bool {
        var previous: UInt8 = 0
        for byte in bytes {
            if byte == 10 && previous != 13 { return true }
            previous = byte
        }
        return false
    }

    private static func parseRequestLine(_ line: String) -> (String, String, [String: String])? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
        let method = String(parts[0])
        guard !method.isEmpty, method.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        let target = parts[1]
        guard target.hasPrefix("/") else { return nil }
        let rawPath: Substring
        let rawQuery: Substring?
        if let mark = target.firstIndex(of: "?") {
            rawPath = target[..<mark]
            rawQuery = target[target.index(after: mark)...]
        } else {
            rawPath = target
            rawQuery = nil
        }
        guard let path = rawPath.removingPercentEncoding, !path.contains("\0") else { return nil }
        var query: [String: String] = [:]
        for item in (rawQuery ?? "").split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decodeQueryComponent(pair[0]),
                  let value = decodeQueryComponent(pair.count > 1 ? pair[1] : "") else { return nil }
            if query[name] == nil { query[name] = value }
        }
        return (method, path, query)
    }

    private static func decodeQueryComponent(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static let tokenCharacters = Set("!#$%&'*+-.^_`|~".utf8)

    private static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || tokenCharacters.contains(byte)
        }
    }
}
