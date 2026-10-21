import Foundation

public struct NaturalDateResult: Sendable, Equatable {
    public var value: LocalDateTime
    public var range: Range<String.Index>

    public init(value: LocalDateTime, range: Range<String.Index>) {
        self.value = value
        self.range = range
    }
}

/// Reads a date written in words: exact forms first, then English short forms, then `NSDataDetector`.
public enum NaturalDateParser {
    private static let weekdays: [(names: [String], weekday: Int)] = [
        (["sunday", "sun"], 1), (["monday", "mon"], 2), (["tuesday", "tue", "tues"], 3),
        (["wednesday", "wed"], 4), (["thursday", "thu", "thur", "thurs"], 5), (["friday", "fri"], 6),
        (["saturday", "sat"], 7),
    ]

    private static let time = "(?:\\s+(?:at\\s+)?(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)|\\s+(?:at\\s+)?(\\d{1,2}):(\\d{2})|\\s+(?:at\\s+)?(noon|midnight))?"
    private static let weekdayAlternation = weekdays.flatMap(\.names).sorted { $0.count > $1.count }.joined(separator: "|")

    private static let isoRegex = try! NSRegularExpression(
        pattern: "(?<![\\d-])(\\d{4}-\\d{2}-\\d{2})(?:[ T](\\d{2}):(\\d{2}))?(?![\\d:])")
    private static let clockRegex = try! NSRegularExpression(
        pattern: "(?<![\\w:.])(?:at\\s+)?(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)(?!\\w)|(?<![\\w:.])(?:at\\s+)?(\\d{1,2}):(\\d{2})(?![\\w:])",
        options: [.caseInsensitive])
    /// A time written before the day word ("3pm tomorrow", "noon friday").
    private static let leadingTimeRegex = try! NSRegularExpression(
        pattern: "(?<![\\w:.])(?:at\\s+)?(?:(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)|(\\d{1,2}):(\\d{2})|(noon|midnight))\\s+(?:on\\s+)?",
        options: [.caseInsensitive])
    private static let shortRegex = try! NSRegularExpression(
        pattern: "(?<![\\w+])(today|tonight|tomorrow|tmrw|(?:next\\s+)?(?:\(weekdayAlternation))|\\+(\\d{1,3})([dw])|in\\s+(\\d{1,3})\\s+(minutes?|mins?|hours?|hrs?|days?|weeks?))(?!\\w)\(time)(?!\\w)",
        options: [.caseInsensitive])

    /// The first date found in `text`. A date without a time gets `defaultHour`:00 when `defaultHour` is set and
    /// stays date-only otherwise. Weekday names never mean today.
    public static func parse(_ text: String, now: Date, calendar: Calendar, defaultHour: Int?) -> NaturalDateResult? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let today = LocalDateTime(now, calendar: calendar, includeTime: false)

        func result(_ value: LocalDateTime, _ range: NSRange) -> NaturalDateResult? {
            guard let swiftRange = Range(range, in: text) else { return nil }
            var value = value
            if !value.hasTime, let defaultHour { value = value.withTime(hour: defaultHour, minute: 0) }
            return NaturalDateResult(value: value, range: swiftRange)
        }

        if let match = isoRegex.firstMatch(in: text, range: full) {
            var token = ns.substring(with: match.range(at: 1))
            if match.range(at: 2).location != NSNotFound {
                token += " \(ns.substring(with: match.range(at: 2))):\(ns.substring(with: match.range(at: 3)))"
            }
            if let value = LocalDateTime(token: token) { return result(value, match.range) }
        }

        let shortMatch = shortRegex.firstMatch(in: text, range: full)
        for lead in leadingTimeRegex.matches(in: text, range: full) {
            if let shortMatch, shortMatch.range.location < lead.range.location { break }
            let end = NSMaxRange(lead.range)
            guard let day = shortRegex.firstMatch(in: text, options: [.anchored], range: NSRange(location: end, length: ns.length - end)),
                  day.range(at: 4).location == NSNotFound || !isClockUnit(ns.substring(with: day.range(at: 5))),
                  let leadTime = clock(lead, in: ns, hourGroup: 1, minuteGroup: 2, meridiemGroup: 3)
                    ?? clock(lead, in: ns, hourGroup: 4, minuteGroup: 5, meridiemGroup: nil)
                    ?? named(lead, in: ns, group: 6),
                  let value = shortForm(day, in: ns, now: now, today: today, calendar: calendar, leadingTime: leadTime)
            else { continue }
            return result(value, NSUnionRange(lead.range, day.range))
        }
        if let match = shortMatch, let value = shortForm(match, in: ns, now: now, today: today, calendar: calendar) {
            return result(value, match.range)
        }

        let detectedDate = detected(text, calendar: calendar)
        if let match = clockRegex.firstMatch(in: text, range: full),
           let (hour, minute) = clock(match, in: ns, hourGroup: 1, minuteGroup: 2, meridiemGroup: 3)
            ?? clock(match, in: ns, hourGroup: 4, minuteGroup: 5, meridiemGroup: nil) {
            // A bare time, unless it is part of a longer date the detector read ("October 21 at 1:30 PM").
            let longer = detectedDate.map { NSIntersectionRange($0.1, match.range).length > 0 && $0.1.length > match.range.length } ?? false
            if !longer {
                var value = today.withTime(hour: hour, minute: minute)
                if let date = value.date(in: calendar), date <= now { value = adding(days: 1, to: value, calendar: calendar) }
                return result(value, match.range)
            }
        }

        return detectedDate.flatMap { result($0.0, $0.1) }
    }

    private static func shortForm(_ match: NSTextCheckingResult, in ns: NSString, now: Date, today: LocalDateTime,
                                  calendar: Calendar, leadingTime: (Int, Int)? = nil) -> LocalDateTime? {
        let word = ns.substring(with: match.range(at: 1)).lowercased()
        let clockTime = clock(match, in: ns, hourGroup: 6, minuteGroup: 7, meridiemGroup: 8)
            ?? clock(match, in: ns, hourGroup: 9, minuteGroup: 10, meridiemGroup: nil)
            ?? named(match, in: ns, group: 11)
            ?? leadingTime
        func at(_ day: LocalDateTime) -> LocalDateTime {
            guard let clockTime else { return day }
            return day.withTime(hour: clockTime.0, minute: clockTime.1)
        }
        switch word {
        case "today": return at(today)
        case "tonight":
            return today.withTime(hour: clockTime?.0 ?? 20, minute: clockTime?.1 ?? 0)
        case "tomorrow", "tmrw": return at(adding(days: 1, to: today, calendar: calendar))
        default: break
        }
        if match.range(at: 2).location != NSNotFound, let count = Int(ns.substring(with: match.range(at: 2))) {
            let unit = ns.substring(with: match.range(at: 3)).lowercased()
            return at(adding(days: unit == "w" ? count * 7 : count, to: today, calendar: calendar))
        }
        if match.range(at: 4).location != NSNotFound, let count = Int(ns.substring(with: match.range(at: 4))) {
            let unit = ns.substring(with: match.range(at: 5)).lowercased()
            if unit.hasPrefix("m") || unit.hasPrefix("h") {
                let seconds = Double(count) * (unit.hasPrefix("h") ? 3600 : 60)
                return LocalDateTime(now.addingTimeInterval(seconds), calendar: calendar, includeTime: true)
            }
            return at(adding(days: unit.hasPrefix("w") ? count * 7 : count, to: today, calendar: calendar))
        }
        let isNext = word.hasPrefix("next")
        let name = isNext ? String(word.dropFirst(4)).trimmingCharacters(in: .whitespaces) : word
        guard let weekday = weekdays.first(where: { $0.names.contains(name) })?.weekday,
              let start = today.date(in: calendar) else { return nil }
        let current = calendar.component(.weekday, from: start)
        var ahead = (weekday - current + 7) % 7
        if ahead == 0 { ahead = 7 }
        if isNext, let target = calendar.date(byAdding: .day, value: ahead, to: start),
           calendar.isDate(target, equalTo: start, toGranularity: .weekOfYear) {
            ahead += 7
        }
        return at(adding(days: ahead, to: today, calendar: calendar))
    }

    private static func isClockUnit(_ unit: String) -> Bool {
        let unit = unit.lowercased()
        return unit.hasPrefix("m") || unit.hasPrefix("h")
    }

    private static func named(_ match: NSTextCheckingResult, in ns: NSString, group: Int) -> (Int, Int)? {
        guard match.numberOfRanges > group, match.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: group)).lowercased() == "noon" ? (12, 0) : (0, 0)
    }

    private static func clock(_ match: NSTextCheckingResult, in ns: NSString, hourGroup: Int, minuteGroup: Int,
                              meridiemGroup: Int?) -> (Int, Int)? {
        guard match.numberOfRanges > hourGroup, match.range(at: hourGroup).location != NSNotFound,
              var hour = Int(ns.substring(with: match.range(at: hourGroup))) else { return nil }
        var minute = 0
        if match.range(at: minuteGroup).location != NSNotFound {
            minute = Int(ns.substring(with: match.range(at: minuteGroup))) ?? 0
        }
        if let meridiemGroup, match.range(at: meridiemGroup).location != NSNotFound {
            guard (1...12).contains(hour) else { return nil }
            let pm = ns.substring(with: match.range(at: meridiemGroup)).lowercased() == "pm"
            hour = hour % 12 + (pm ? 12 : 0)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func adding(days: Int, to day: LocalDateTime, calendar: Calendar) -> LocalDateTime {
        guard let start = day.date(in: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: start) else { return day }
        var result = LocalDateTime(moved, calendar: calendar, includeTime: false)
        if let hour = day.hour, let minute = day.minute { result = result.withTime(hour: hour, minute: minute) }
        return result
    }

    private static let timeHint = try! NSRegularExpression(
        pattern: "\\d[:.h]\\d|\\d\\s*(am|pm|uhr|h\\b)|noon|midnight|o'clock", options: [.caseInsensitive])

    /// NSDataDetector reads text in the Mac's own time zone and fills date-only matches in at 12:00.
    private static func detected(_ text: String, calendar: Calendar) -> (LocalDateTime, NSRange)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = text as NSString
        guard let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let date = match.date else { return nil }
        var local = calendar
        local.timeZone = match.timeZone ?? .current
        let matched = ns.substring(with: match.range)
        let hasTime = timeHint.firstMatch(in: matched, range: NSRange(location: 0, length: (matched as NSString).length)) != nil
        let parts = local.dateComponents([.hour, .minute], from: date)
        let looksDateOnly = !hasTime && parts.hour == 12 && parts.minute == 0
        return (LocalDateTime(date, calendar: local, includeTime: !looksDateOnly), match.range)
    }
}
