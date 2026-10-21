import NoteItCore
import XCTest

final class NaturalDateParserTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    /// Monday 2026-10-19 10:00 in Stockholm.
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T08:00:00Z")!

    private func parse(_ text: String, defaultHour: Int? = nil) -> String? {
        NaturalDateParser.parse(text, now: now, calendar: calendar, defaultHour: defaultHour)?.value.token
    }

    func testVectorDates() throws {
        let dates = try XCTUnwrap(OrganiseVectors.load()["dates"] as? [String: Any])
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: dates["now"] as! String))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: dates["timeZone"] as! String))
        for vector in try XCTUnwrap(dates["cases"] as? [[String: Any]]) {
            let input = vector["input"] as! String
            XCTAssertEqual(NaturalDateParser.parse(input, now: now, calendar: calendar, defaultHour: nil)?.value.token,
                           vector["due"] as? String, "due: \(input)")
            XCTAssertEqual(NaturalDateParser.parse(input, now: now, calendar: calendar, defaultHour: 9)?.value.token,
                           vector["remind"] as? String, "remind: \(input)")
        }
    }

    func testShortForms() {
        XCTAssertEqual(parse("today"), "2026-10-19")
        XCTAssertEqual(parse("tonight"), "2026-10-19 20:00")
        XCTAssertEqual(parse("tomorrow", defaultHour: 9), "2026-10-20 09:00")
        XCTAssertEqual(parse("next tuesday"), "2026-10-27")
        XCTAssertEqual(parse("wed"), "2026-10-21")
        XCTAssertEqual(parse("+3d"), "2026-10-22")
        XCTAssertEqual(parse("in 2 weeks"), "2026-11-02")
        XCTAssertEqual(parse("in 30 minutes"), "2026-10-19 10:30")
    }

    func testRangeCoversTheDateWords() throws {
        let text = "call the supplier tomorrow 9am please"
        let result = try XCTUnwrap(NaturalDateParser.parse(text, now: now, calendar: calendar, defaultHour: 9))
        XCTAssertEqual(String(text[result.range]), "tomorrow 9am")
    }

    func testWeekdayNeverToday() {
        XCTAssertEqual(parse("monday"), "2026-10-26")
        XCTAssertEqual(parse("mon 08:00"), "2026-10-26 08:00")
    }

    func testDataDetectorFallback() {
        XCTAssertEqual(parse("lunch on October 21, 2027 at 1:30 PM"), "2027-10-21 13:30")
        XCTAssertEqual(parse("October 21, 2027"), "2027-10-21")
        XCTAssertNil(parse("no date in here"))
    }
}
