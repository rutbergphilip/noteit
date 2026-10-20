import Foundation

/// One daily-log entry line. Owned by the linking plan; built in foundations Task 4.6.
public enum DailyLogLine {
    public static let maxTextLength = 2_000

    /// "- HH:mm text" (timestamp true) or "- text" (timestamp false), 24-hour, en_US_POSIX. Newlines and tabs
    /// become spaces, runs collapse, trimmed, capped at maxTextLength characters; nil when nothing is left.
    public static func format(text: String, at date: Date, timeZone: TimeZone, timestamp: Bool = true) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let cleaned = String(words.joined(separator: " ").prefix(maxTextLength))
        return prefix(at: date, timeZone: timeZone, timestamp: timestamp) + cleaned
    }

    /// "- HH:mm " or "- ": what DailyLogAppender puts before attributed content.
    public static func prefix(at date: Date, timeZone: TimeZone, timestamp: Bool = true) -> String {
        guard timestamp else { return "- " }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "- \(formatter.string(from: date)) "
    }
}
