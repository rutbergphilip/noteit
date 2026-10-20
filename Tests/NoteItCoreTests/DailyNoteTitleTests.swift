import XCTest
import NoteItCore

final class DailyNoteTitleTests: XCTestCase {
    private let day = DayKey(year: 2026, month: 10, day: 19)
    private let en = Locale(identifier: "en_US")
    private let sv = Locale(identifier: "sv_SE")

    func testTitlesInEveryFormat() {
        XCTAssertEqual(DailyNoteTitle.title(for: day, format: .iso, locale: en), "2026-10-19")
        XCTAssertEqual(DailyNoteTitle.title(for: day, format: .long, locale: en), "19 October 2026")
        XCTAssertEqual(DailyNoteTitle.title(for: day, format: .weekdayLong, locale: en), "Monday, 19 October 2026")
        XCTAssertEqual(DailyNoteTitle.title(for: day, format: .iso, locale: sv), "2026-10-19")
        XCTAssertEqual(DailyNoteTitle.title(for: day, format: .long, locale: sv), "19 oktober 2026")
        XCTAssertEqual(DailyNoteTitle.title(for: day, format: .weekdayLong, locale: sv), "måndag, 19 oktober 2026")
    }

    func testParseRoundTripsEveryFormat() {
        let days = [day, DayKey(year: 2024, month: 2, day: 29), DayKey(year: 2027, month: 1, day: 1)]
        for locale in [en, sv] {
            for format in DailyTitleFormat.allCases {
                for day in days {
                    let title = DailyNoteTitle.title(for: day, format: format, locale: locale)
                    XCTAssertEqual(DailyNoteTitle.parse(title, locale: locale), day, "\(format) \(title)")
                }
            }
        }
    }

    func testParseIgnoresChosenFormat() {
        for format in DailyTitleFormat.allCases {
            let title = DailyNoteTitle.title(for: day, format: format, locale: en)
            XCTAssertEqual(DailyNoteTitle.parse(title, locale: en), day)
            XCTAssertEqual(DailyNoteTitle.parse("  \(title.lowercased())  ", locale: en), day)
        }
    }

    func testParseRejectsOtherTitles() {
        for title in ["", "Meeting notes", "2026-10-19 standup", "2026-13-01", "2026-02-30", "Tuesday, 19 October 2026",
                      "19 October", "2026-1-5"] {
            XCTAssertNil(DailyNoteTitle.parse(title, locale: en), title)
        }
    }

    func testDayKey() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 30))!
        XCTAssertEqual(DayKey(date, calendar: calendar), day)
        XCTAssertEqual(day.date(calendar: calendar, hour: 9).map { calendar.component(.hour, from: $0) }, 9)
        XCTAssertLessThan(day, DayKey(year: 2026, month: 10, day: 20))
        XCTAssertLessThan(DayKey(year: 2025, month: 12, day: 31), day)
    }

    func testGateIsClosed() {
        XCTAssertFalse(DailyNotes.isAvailable)
    }
}
