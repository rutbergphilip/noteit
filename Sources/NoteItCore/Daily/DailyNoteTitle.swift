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

    /// The calendar daily notes count days in: always Gregorian (titles are Gregorian dates), in `timeZone`.
    public static func dailyCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
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
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        if let day = isoDay(trimmed) { return day }
        // Every other format ends in a four-digit year; skip the formatters for titles that cannot match.
        let scalars = Array(trimmed.unicodeScalars)
        guard scalars.count > 4, scalars.suffix(4).allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        for format in DailyTitleFormat.allCases where format != .iso {
            switch format {
            case .long: guard ("0"..."9").contains(scalars[0]) else { continue }
            case .weekdayLong: guard trimmed.contains(", ") else { continue }
            case .iso: continue
            }
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

    /// "yyyy-MM-dd" without a formatter; nil for anything else, including invalid dates.
    private static func isoDay(_ text: String) -> DayKey? {
        let utf8 = Array(text.utf8)
        guard utf8.count == 10, utf8[4] == UInt8(ascii: "-"), utf8[7] == UInt8(ascii: "-") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in utf8[range] {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              year >= 1, (1...12).contains(month), day >= 1 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= lengths[month - 1] else { return nil }
        return DayKey(year: year, month: month, day: day)
    }

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// Cached per format and locale: building a `DateFormatter` costs far more than using one.
    private static func makeFormatter(_ format: DailyTitleFormat, locale: Locale) -> DateFormatter {
        let key = "\(format.rawValue)|\(locale.identifier)"
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = newFormatter(format, locale: locale)
        formatters[key] = formatter
        return formatter
    }

    private static func newFormatter(_ format: DailyTitleFormat, locale: Locale) -> DateFormatter {
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
