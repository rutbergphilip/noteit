import Foundation

/// How a new daily note is titled. Owned by the linking plan; built in foundations Task 4.6.
public enum DailyTitleFormat: String, CaseIterable, Codable, Sendable {
    case iso, long, weekdayLong

    var pattern: String {
        switch self {
        case .iso: "yyyy-MM-dd"
        case .long: "d MMMM yyyy"
        case .weekdayLong: "EEEE, d MMMM yyyy"
        }
    }
}

/// A calendar day, independent of time zone. Owned by the linking plan; built in foundations Task 4.6.
public struct DayKey: Hashable, Comparable, Codable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    public func date(calendar: Calendar, hour: Int = 0) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// Daily note titles. Owned by the linking plan; built in foundations Task 4.6.
public enum DailyNoteTitle {
    /// iso "2026-10-19", long "19 October 2026", weekdayLong "Monday, 19 October 2026" (month and weekday in `locale`).
    public static func title(for day: DayKey, format: DailyTitleFormat, locale: Locale) -> String {
        let formatter = makeFormatter(format, locale: locale)
        guard let date = day.date(calendar: formatter.calendar, hour: 12) else { return "" }
        return formatter.string(from: date)
    }

    /// Parses `title` in every `DailyTitleFormat` (all of `allCases`, not just the chosen one), so a note titled
    /// under an earlier format is still found after the user switches; nil when no format matches.
    public static func parse(_ text: String, locale: Locale) -> DayKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for format in DailyTitleFormat.allCases {
            let formatter = makeFormatter(format, locale: locale)
            guard let date = formatter.date(from: trimmed) else { continue }
            let day = DayKey(date, calendar: formatter.calendar)
            // Strict: only a title that reads back exactly (ignoring case) is a daily title.
            if title(for: day, format: format, locale: locale).compare(trimmed, options: .caseInsensitive) == .orderedSame {
                return day
            }
        }
        return nil
    }

    private static func makeFormatter(_ format: DailyTitleFormat, locale: Locale) -> DateFormatter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = format == .iso ? Locale(identifier: "en_US_POSIX") : locale
        formatter.dateFormat = format.pattern
        formatter.isLenient = false
        return formatter
    }
}
