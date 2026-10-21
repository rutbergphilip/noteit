import Foundation
import NoteItCore

/// Rewrites `@due(fri)` or `@remind(tomorrow 9am)` as a full date once its `)` is typed.
enum DateTokenAutoFormat {
    enum Kind { case due, remind }

    private static let regex = try! NSRegularExpression(pattern: "@(due|remind)\\(([^()\\n]*)\\)$")

    /// `text` is the paragraph up to and including the `)` just typed, masked for code and links. Returns the token's
    /// range in `text` and its replacement; nil when the token is already a full date or isn't a date at all.
    static func rewrite(_ text: String, now: Date, calendar: Calendar, reminderMinutes: Int)
        -> (range: NSRange, replacement: String, kind: Kind)? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let kind: Kind = ns.substring(with: match.range(at: 1)) == "due" ? .due : .remind
        var inner = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        var done = false
        if kind == .remind, inner.lowercased().hasSuffix(" done") {
            done = true
            inner = String(inner.dropLast(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !inner.isEmpty, LocalDateTime(token: inner) == nil,
              let parsed = NaturalDateParser.parse(inner, now: now, calendar: calendar, defaultHour: nil) else { return nil }
        let rest = inner.replacingCharacters(in: parsed.range, with: "")
        guard rest.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)).isEmpty else { return nil }
        var value = parsed.value
        if kind == .remind, !value.hasTime {
            value = value.withTime(hour: reminderMinutes / 60 % 24, minute: reminderMinutes % 60)
        }
        let name = kind == .due ? "due" : "remind"
        return (match.range, "@\(name)(\(value.token)\(done ? " done" : ""))", kind)
    }
}
