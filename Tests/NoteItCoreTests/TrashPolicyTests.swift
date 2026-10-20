import NoteItCore
import XCTest

final class TrashPolicyTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func summary(daysAgo: Double) -> String {
        TrashPolicy.deletionSummary(deletedAt: now.addingTimeInterval(-daysAgo * day), now: now)
    }

    func testDeletionSummaryText() {
        XCTAssertEqual(summary(daysAgo: 0), "Deleted today. It will be removed in 30 days.")
        XCTAssertEqual(summary(daysAgo: 1), "Deleted yesterday. It will be removed in 29 days.")
        XCTAssertEqual(summary(daysAgo: 3), "Deleted 3 days ago. It will be removed in 27 days.")
        XCTAssertEqual(summary(daysAgo: 29), "Deleted 29 days ago. It will be removed in 1 day.")
        XCTAssertEqual(summary(daysAgo: 31), "Deleted 31 days ago. It will be removed soon.")
    }

    func testExpiresAtExactlyThirtyDays() {
        let deletedAt = now.addingTimeInterval(-30 * day)
        XCTAssertTrue(TrashPolicy.isExpired(deletedAt: deletedAt, now: now))
        XCTAssertFalse(TrashPolicy.isExpired(deletedAt: deletedAt.addingTimeInterval(1), now: now))
        XCTAssertEqual(TrashPolicy.purgeDate(deletedAt: deletedAt), now)
    }
}
