import Foundation

/// The browser rules checked before routing (automation spec §6.6) and the origin binding of tokens (§6.4).
public struct RequestPolicy: Sendable {
    /// Sent by Safari extensions on every request.
    public static let extensionBundleHeader = "X-NoteIt-Extension-Bundle"

    static let extensionSchemes = ["chrome-extension", "moz-extension", "safari-web-extension"]
    static let safariScheme = "safari-web-extension"
    private static let safariStoredPrefix = safariScheme + ":"

    public let port: UInt16

    public init(port: UInt16) {
        self.port = port
    }

    /// `Host` must be `127.0.0.1:<port>` or `localhost:<port>` (DNS rebinding protection).
    public func checkHost(_ request: HTTPRequest) -> Bool {
        guard let host = request.headers["Host"]?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// No `Origin` is a native client; a browser extension origin with a host is allowed; anything else, `null`
    /// included, is refused.
    public func classifyOrigin(_ request: HTTPRequest) -> OriginDecision {
        guard let origin = request.headers["Origin"] else { return .native }
        guard let (scheme, host) = Self.split(origin), Self.extensionSchemes.contains(scheme), !host.isEmpty,
              host.unicodeScalars.allSatisfy(Self.hostCharacters.contains) else {
            return .rejected
        }
        return .extensionOrigin(origin)
    }

    /// 204 for an `OPTIONS` request from an allowed extension origin; nil otherwise.
    public func preflight(_ request: HTTPRequest) -> HTTPResponse? {
        guard request.method == "OPTIONS", case .extensionOrigin = classifyOrigin(request) else { return nil }
        var headers = corsHeaders(for: classifyOrigin(request))
        headers["Access-Control-Allow-Methods"] = "GET, POST, PATCH, DELETE"
        headers["Access-Control-Allow-Headers"] =
            "Authorization, Content-Type, If-Match, X-NoteIt-Filename, \(Self.extensionBundleHeader)"
        headers["Access-Control-Max-Age"] = "600"
        return HTTPResponse(status: 204, headers: headers)
    }

    /// The echoed origin and `Vary: Origin` for extension origins; nothing otherwise.
    public func corsHeaders(for decision: OriginDecision) -> HTTPHeaders {
        guard case .extensionOrigin(let origin) = decision else { return HTTPHeaders() }
        return HTTPHeaders([("Access-Control-Allow-Origin", origin), ("Vary", "Origin")])
    }

    /// JSON routes need `Content-Type: application/json` (parameters such as `charset` are fine).
    public func checkContentType(_ request: HTTPRequest, route: RouteSpec) -> APIErrorCode? {
        guard route.body == .json else { return nil }
        let mediaType = request.headers["Content-Type"]?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        return mediaType == "application/json" ? nil : .unsupportedMediaType
    }

    /// The origin stored on a new client: nil for `.native`, the full origin for Chrome and Firefox,
    /// `safari-web-extension:<bundle id>` for Safari (a missing or malformed bundle id is `.badRequest`).
    public static func storedOrigin(for decision: OriginDecision, extensionBundle: String?)
        -> Result<String?, APIErrorCode> {
        switch decision {
        case .native:
            return .success(nil)
        case .rejected:
            return .failure(.originNotAllowed)
        case .extensionOrigin(let origin):
            guard split(origin)?.scheme == safariScheme else { return .success(origin) }
            guard let bundle = extensionBundle, isBundleID(bundle) else { return .failure(.badRequest) }
            return .success(safariStoredPrefix + bundle)
        }
    }

    /// Unbound tokens work only without an `Origin`. A Safari-bound token works from any `safari-web-extension`
    /// host (Safari changes it between launches) when the bundle header equals the stored bundle id; every other
    /// bound token needs its exact origin and ignores the header.
    public static func originBindingAllows(record: ClientRecord, decision: OriginDecision,
                                           extensionBundle: String?) -> Bool {
        guard let stored = record.origin else { return decision == .native }
        guard case .extensionOrigin(let origin) = decision else { return false }
        if stored.hasPrefix(safariStoredPrefix), !stored.hasPrefix(safariStoredPrefix + "//") {
            let bundle = String(stored.dropFirst(safariStoredPrefix.count))
            return split(origin)?.scheme == safariScheme && extensionBundle == bundle
        }
        return origin == stored
    }

    /// Reverse-DNS, at most 255 characters.
    static func isBundleID(_ text: String) -> Bool {
        text.utf8.count <= 255 && text.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    }

    private static let hostCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")

    private static func split(_ origin: String) -> (scheme: String, host: String)? {
        guard let range = origin.range(of: "://") else { return nil }
        return (String(origin[..<range.lowerBound]), String(origin[range.upperBound...]))
    }
}
