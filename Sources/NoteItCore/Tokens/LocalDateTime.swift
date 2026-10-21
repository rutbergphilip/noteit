import Foundation

/// A wall-clock date with an optional time, as written in `@due(…)` and `@remind(…)` tokens. It has no time zone:
/// 09:00 means 09:00 wherever the Mac is.
public struct LocalDateTime: Hashable, Codable, Sendable, Comparable {
    public var year: Int, month: Int, day: Int
    public var hour: Int?, minute: Int?

    public init?(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...Self.daysIn(month: month, year: year)).contains(day) else { return nil }
        if hour != nil || minute != nil {
            guard let hour, let minute, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        }
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    /// "2026-10-21" or "2026-10-21 14:00". Invalid calendar dates are nil.
    public init?(token: String) {
        let scalars = Array(token.utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= scalars.count else { return nil }
            var value = 0
            for byte in scalars[range] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard scalars.count == 10 || scalars.count == 16, scalars[4] == 45, scalars[7] == 45,
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10) else { return nil }
        if scalars.count == 16 {
            guard scalars[10] == 32, scalars[13] == 58, let hour = number(11..<13), let minute = number(14..<16) else {
                return nil
            }
            self.init(year: year, month: month, day: day, hour: hour, minute: minute)
        } else {
            self.init(year: year, month: month, day: day)
        }
    }

    public init(_ date: Date, calendar: Calendar, includeTime: Bool) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
        hour = includeTime ? parts.hour ?? 0 : nil
        minute = includeTime ? parts.minute ?? 0 : nil
    }

    public var hasTime: Bool { hour != nil }

    public var token: String {
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        guard let hour, let minute else { return date }
        return date + String(format: " %02d:%02d", hour, minute)
    }

    /// The same day without the time.
    public var dateOnly: LocalDateTime {
        var copy = self
        copy.hour = nil
        copy.minute = nil
        return copy
    }

    public func withTime(hour: Int, minute: Int) -> LocalDateTime {
        var copy = self
        copy.hour = hour
        copy.minute = minute
        return copy
    }

    /// The moment this wall-clock time happens in `calendar.timeZone`; midnight for a date without a time.
    public func date(in calendar: Calendar) -> Date? {
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour ?? 0
        parts.minute = minute ?? 0
        return calendar.date(from: parts)
    }

    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour ?? -1, lhs.minute ?? -1)
            < (rhs.year, rhs.month, rhs.day, rhs.hour ?? -1, rhs.minute ?? -1)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = LocalDateTime(token: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a date: \(string)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}
