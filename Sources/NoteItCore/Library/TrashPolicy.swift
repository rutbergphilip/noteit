import Foundation

/// How long notes stay in Recently Deleted and how that is described. Moved out of `NoteStore` in
/// foundations Task 1.3.
public enum TrashPolicy {
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public static func purgeDate(deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(retention)
    }

    public static func isExpired(deletedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(deletedAt) >= retention
    }

    /// "Deleted 3 days ago. It will be removed in 27 days."
    public static func deletionSummary(deletedAt: Date, now: Date) -> String {
        let day: TimeInterval = 24 * 60 * 60
        let elapsed = max(0, Int(now.timeIntervalSince(deletedAt) / day))
        let remaining = max(0, Int(ceil((retention - now.timeIntervalSince(deletedAt)) / day)))
        let deleted = switch elapsed {
        case 0: "Deleted today."
        case 1: "Deleted yesterday."
        default: "Deleted \(elapsed) days ago."
        }
        let removed = switch remaining {
        case 0: "It will be removed soon."
        case 1: "It will be removed in 1 day."
        default: "It will be removed in \(remaining) days."
        }
        return "\(deleted) \(removed)"
    }
}
