import Foundation

/// Matches a method and a percent-decoded path against route patterns with `{param}` segments. A literal segment
/// beats a parameter at the same position, and a parameter matches exactly one non-empty segment, so
/// `/v1/notes/{id}` never matches `/v1/notes/{id}/append`.
public struct Router: Sendable {
    private struct Compiled: Sendable {
        let spec: RouteSpec
        let segments: [Segment]
    }

    private enum Segment: Sendable {
        case literal(String)
        case param(String)
    }

    private let routes: [Compiled]

    public init(routes: [RouteSpec] = APIRoutes.all) {
        self.routes = routes.map { spec in
            Compiled(spec: spec, segments: Self.split(spec.pattern).map { segment in
                segment.hasPrefix("{") && segment.hasSuffix("}") && segment.count > 2
                    ? .param(String(segment.dropFirst().dropLast())) : .literal(segment)
            })
        }
    }

    /// `.notFound` when no route has this path; `.badRequest` when routes have the path but not the method (405;
    /// `allowedMethods(path:)` gives the `Allow` header).
    public func match(method: String, path: String) -> Result<RouteMatch, APIErrorCode> {
        let candidates = matches(path: path)
        guard !candidates.isEmpty else { return .failure(.notFound) }
        guard let best = candidates.filter({ $0.route.spec.method.rawValue == method })
            .max(by: { Self.isLessSpecific($0.route, than: $1.route) }) else {
            return .failure(.badRequest)
        }
        return .success(RouteMatch(spec: best.route.spec, params: best.params))
    }

    /// Methods of the routes that have this path, in a stable order.
    public func allowedMethods(path: String) -> [String] {
        let methods = Set(matches(path: path).map(\.route.spec.method.rawValue))
        return ["GET", "POST", "PATCH", "DELETE"].filter(methods.contains)
    }

    private func matches(path: String) -> [(route: Compiled, params: [String: String])] {
        let parts = Self.split(path)
        return routes.compactMap { route in
            guard route.segments.count == parts.count else { return nil }
            var params: [String: String] = [:]
            for (segment, part) in zip(route.segments, parts) {
                switch segment {
                case .literal(let text):
                    guard text == part else { return nil }
                case .param(let name):
                    guard !part.isEmpty else { return nil }
                    params[name] = part
                }
            }
            return (route, params)
        }
    }

    /// Compares segment by segment; the first position where one has a literal and the other a parameter decides.
    private static func isLessSpecific(_ lhs: Compiled, than rhs: Compiled) -> Bool {
        for (left, right) in zip(lhs.segments, rhs.segments) {
            switch (left, right) {
            case (.param, .literal): return true
            case (.literal, .param): return false
            default: continue
            }
        }
        return false
    }

    private static func split(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }
}
