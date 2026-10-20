import XCTest
import NoteItCore

final class DailyLogLineTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: hour, minute: minute))!
    }

    func testFormatCleansText() {
        XCTAssertEqual(DailyLogLine.format(text: "  Call\tBob\n\nabout   the\r\nplan ", at: date(14, 7), timeZone: utc),
                       "- 14:07 Call Bob about the plan")
        XCTAssertNil(DailyLogLine.format(text: " \n\t ", at: date(14, 7), timeZone: utc))
        XCTAssertNil(DailyLogLine.format(text: "", at: date(14, 7), timeZone: utc, timestamp: false))
    }

    func testTimestampOff() {
        XCTAssertEqual(DailyLogLine.format(text: "Idea", at: date(9, 30), timeZone: utc, timestamp: false), "- Idea")
        XCTAssertEqual(DailyLogLine.prefix(at: date(9, 30), timeZone: utc, timestamp: false), "- ")
        XCTAssertEqual(DailyLogLine.prefix(at: date(9, 30), timeZone: utc), "- 09:30 ")
    }

    func testMidnightAndTimeZone() {
        XCTAssertEqual(DailyLogLine.format(text: "Late", at: date(0, 5), timeZone: utc), "- 00:05 Late")
        let stockholm = TimeZone(identifier: "Europe/Stockholm")!
        XCTAssertEqual(DailyLogLine.prefix(at: date(22, 5), timeZone: stockholm), "- 00:05 ")
    }

    func testLengthCap() {
        let long = String(repeating: "a", count: DailyLogLine.maxTextLength + 50)
        let line = DailyLogLine.format(text: long, at: date(8, 0), timeZone: utc, timestamp: false)
        XCTAssertEqual(line, "- " + String(repeating: "a", count: DailyLogLine.maxTextLength))
    }
}
