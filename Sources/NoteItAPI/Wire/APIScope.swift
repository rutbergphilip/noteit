import Foundation

/// Local API token scopes, cumulative: `admin` includes `write`, which includes `read`. Shape owned by the
/// automation plan; built in foundations Task 5.1.
public enum APIScope: String, Codable, Sendable, CaseIterable, Comparable {
    case read, write, admin

    private var rank: Int {
        switch self {
        case .read: return 0
        case .write: return 1
        case .admin: return 2
        }
    }

    public static func < (lhs: APIScope, rhs: APIScope) -> Bool { lhs.rank < rhs.rank }

    public func allows(_ required: APIScope) -> Bool { self >= required }

    /// De-duplicated and sorted.
    public static func normalized(_ scopes: [APIScope]) -> [APIScope] { Array(Set(scopes)).sorted() }
}
