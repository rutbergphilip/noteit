import AppKit
import NoteItCore

enum ReminderAction: Hashable {
    case done, snooze(TimeInterval), tomorrow, remove, set(LocalDateTime)
}

/// What Done does to a line with a reminder.
enum ReminderDoneEdit: Equatable {
    case check
    /// The new `@remind(… done)` token.
    case markDone(String)
}

struct LiveReminder: Identifiable, Hashable {
    var id: UUID
    var noteID: UUID
    var line: ReminderLine
    var fireDate: Date

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension NoteStore {
    static func reminderDefaultMinutes(_ defaults: UserDefaults = .standard) -> Int {
        let minutes = defaults.object(forKey: PrefKey.reminderDefaultTime) as? Int ?? PrefDefault.reminderDefaultTime
        return min(max(minutes, 0), 24 * 60 - 1)
    }

    /// Reminders that can still ring, soonest first: not done, not on a checked task, in notes that aren't locked or
    /// in Recently Deleted (locked notes have no index entry).
    func liveReminders(calendar: Calendar = .current) -> [LiveReminder] {
        let entries = searchIndexer.entries
        var result: [LiveReminder] = []
        for meta in notes where meta.deletedAt == nil && !meta.isLocked {
            guard let lines = entries[meta.id]?.reminders else { continue }
            for line in lines where !line.done && !(line.isTask && line.checked) {
                guard let date = line.at.date(in: calendar) else { continue }
                result.append(LiveReminder(id: ReminderIdentity.id(noteID: meta.id, at: line.at, lineText: line.text),
                                           noteID: meta.id, line: line, fireDate: date))
            }
        }
        return result.sorted { $0.fireDate != $1.fireDate ? $0.fireDate < $1.fireDate : $0.id.uuidString < $1.id.uuidString }
    }

    /// True when every note that can hold a live reminder has its reminders read into the index.
    var remindersAreIndexed: Bool {
        let entries = searchIndexer.entries
        return notes.allSatisfy { meta in
            meta.deletedAt != nil || meta.isLocked || entries[meta.id]?.reminders != nil || hasUnreadableBody(meta.id)
        }
    }

    /// Adds or replaces the `@remind(…)` token on paragraph `paragraph` of the note.
    func addReminder(noteID: UUID, paragraph: Int, at: LocalDateTime) throws {
        let value = at.hasTime ? at : Self.withDefaultTime(at)
        try editBody(noteID, actionName: "Set Reminder", versioning: .none) { body in
            guard let range = Self.paragraphRanges(body.string as NSString)[safe: paragraph] else { throw BodyEditError.taskChanged }
            Self.setToken(.remind, value: "@remind(\(value.token))", paragraph: range, in: body)
        }
    }

    /// Done, Snooze, Tomorrow, Remove or a new time for a live reminder, as an edit of its line.
    func updateReminder(_ id: UUID, action: ReminderAction, now: Date = Date(), calendar: Calendar = .current) throws {
        guard let reminder = liveReminders(calendar: calendar).first(where: { $0.id == id }) else { throw BodyEditError.taskChanged }
        let line = reminder.line
        let actionName: String
        switch action {
        case .done: actionName = line.isTask ? "Check" : "Mark Reminder Done"
        case .remove: actionName = "Remove Reminder"
        default: actionName = "Set Reminder"
        }
        try editBody(reminder.noteID, actionName: actionName, versioning: .none) { body in
            let range = try Self.resolveLine(paragraph: line.paragraph, textHash: line.textHash, in: body)
            switch action {
            case .done:
                if line.isTask {
                    Self.setChecked(true, paragraph: range, in: body)
                } else {
                    Self.setToken(.remind, value: "@remind(\(line.at.token) done)", paragraph: range, in: body)
                }
            case .remove:
                Self.setToken(.remind, value: nil, paragraph: range, in: body)
            case .snooze(let interval):
                let at = LocalDateTime(now.addingTimeInterval(interval), calendar: calendar, includeTime: true)
                Self.setToken(.remind, value: "@remind(\(at.token))", paragraph: range, in: body)
            case .tomorrow:
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
                let at = Self.withDefaultTime(LocalDateTime(tomorrow, calendar: calendar, includeTime: false))
                Self.setToken(.remind, value: "@remind(\(at.token))", paragraph: range, in: body)
            case .set(let value):
                let at = value.hasTime ? value : Self.withDefaultTime(value)
                Self.setToken(.remind, value: "@remind(\(at.token))", paragraph: range, in: body)
            }
        }
    }

    /// Done for the reminder on a line: checks an unchecked task, otherwise marks the token done. Nil when the line
    /// has no reminder left to finish.
    nonisolated static func reminderDoneEdit(forMaskedLine line: String) -> ReminderDoneEdit? {
        guard let reminder = TaskParser.parse(masked: line).reminders.first, !reminder.done,
              !(reminder.isTask && reminder.checked) else { return nil }
        return reminder.isTask ? .check : .markDone("@remind(\(reminder.at.token) done)")
    }

    /// The date written in a line, for Add Reminder: dates without a time get the default time; past dates don't count.
    nonisolated static func reminderDate(inLine masked: String, now: Date, calendar: Calendar, defaultMinutes: Int) -> LocalDateTime? {
        let stripped = TaskParser.displayText(masked)
        guard let found = NaturalDateParser.parse(stripped, now: now, calendar: calendar, defaultHour: nil) else { return nil }
        var value = found.value
        if !value.hasTime { value = value.withTime(hour: defaultMinutes / 60, minute: defaultMinutes % 60) }
        guard let date = value.date(in: calendar), date > now else { return nil }
        return value
    }

    private static func withDefaultTime(_ value: LocalDateTime) -> LocalDateTime {
        let minutes = reminderDefaultMinutes()
        return value.withTime(hour: minutes / 60, minute: minutes % 60)
    }

    nonisolated static func paragraphRanges(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location <= text.length {
            let end = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
            let stop = end.location == NSNotFound ? text.length : end.location
            ranges.append(NSRange(location: location, length: stop - location))
            if end.location == NSNotFound { break }
            location = stop + 1
        }
        return ranges
    }

    /// The paragraph at the index if its masked text still has `textHash`, else the first one that does.
    nonisolated static func resolveLine(paragraph: Int, textHash: String, in body: NSAttributedString) throws -> NSRange {
        let masked = maskedForTokens(body) as NSString
        let ranges = paragraphRanges(masked)
        func matches(_ range: NSRange) -> Bool { TaskParser.textHash(masked.substring(with: range)) == textHash }
        if paragraph < ranges.count, matches(ranges[paragraph]) { return ranges[paragraph] }
        if let range = ranges.first(where: matches) { return range }
        throw BodyEditError.taskChanged
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
