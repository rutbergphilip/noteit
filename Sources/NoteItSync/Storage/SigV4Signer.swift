import CryptoKit
import Foundation

public struct S3Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }

    public var description: String { "S3Credentials(accessKeyID: \(accessKeyID), secretAccessKey: <redacted>)" }
    public var debugDescription: String { description }
}

/// AWS Signature Version 4 for the `Authorization` header.
public enum SigV4Signer {
    public static let emptyPayloadSHA256 = sha256Hex(Data())

    public static func sign(
        request: inout URLRequest,
        payloadSHA256: String,
        credentials: S3Credentials,
        region: String,
        service: String = "s3",
        date: Date
    ) {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let (amzDate, dateStamp) = timestamps(date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadSHA256, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(nil, forHTTPHeaderField: "Authorization")

        var headers: [String: String] = ["host": hostHeader(components)]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            guard lower.hasPrefix("x-amz-") || ["range", "if-match", "if-none-match"].contains(lower) else { continue }
            headers[lower] = normalizeHeaderValue(value)
        }
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(components.percentEncodedPath),
            canonicalQuery(components.percentEncodedQuery),
            canonicalHeaders,
            signedHeaders,
            payloadSHA256,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: hmac(key, part))
        }
        let signature = hex(hmac(key, stringToSign))

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    /// RFC 3986 encoding: everything except unreserved characters is percent-encoded.
    public static func uriEncode(_ string: String, encodeSlash: Bool = true) -> String {
        var out = ""
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: "/") where !encodeSlash:
                out.append("/")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: - Internals

    private static func timestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let dateStamp = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (dateStamp + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!), dateStamp)
    }

    private static func hostHeader(_ components: URLComponents) -> String {
        let host = (components.host ?? "").lowercased()
        guard let port = components.port else { return host }
        let scheme = components.scheme?.lowercased()
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) { return host }
        return "\(host):\(port)"
    }

    private static func normalizeHeaderValue(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func canonicalURI(_ percentEncodedPath: String) -> String {
        guard !percentEncodedPath.isEmpty else { return "/" }
        return percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0).removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
    }

    private static func canonicalQuery(_ percentEncodedQuery: String?) -> String {
        guard let query = percentEncodedQuery, !query.isEmpty else { return "" }
        return query
            .split(separator: "&", omittingEmptySubsequences: true)
            .map(canonicalQueryPair)
            .sorted { (a: (String, String), b: (String, String)) -> Bool in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
            .map { (pair: (String, String)) -> String in pair.0 + "=" + pair.1 }
            .joined(separator: "&")
    }

    private static func canonicalQueryPair(_ pair: Substring) -> (String, String) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let rawName = String(parts[0])
        let rawValue = parts.count > 1 ? String(parts[1]) : ""
        return (uriEncode(rawName.removingPercentEncoding ?? rawName), uriEncode(rawValue.removingPercentEncoding ?? rawValue))
    }

    private static func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
