import AppKit
import NoteItCore

/// Live daily notes in the daily notes notebook, by day (the oldest note for a day).
struct DailyNoteIndex {
    var version: Int
    var notebookID: UUID
    var localeID: String
    var byDay: [DayKey: UUID]
    var dayByNote: [UUID: DayKey]
    /// Parsed titles, reused by the next build so only new and renamed notes are parsed again.
    var parsedTitles: [UUID: ParsedTitle]

    struct ParsedTitle {
        var title: String
        var day: DayKey?
    }
}

/// The daily-note UI (spec §10): Today, the calendar and ‹ › in the header.
extension NoteStore {
    var dailyNoteIndex: DailyNoteIndex? {
        guard let notebookID = dailyNotesNotebookID(createIfMissing: false) else { return nil }
        let locale = Locale.current
        if let cache = dailyNoteIndexCache, cache.version == notesVersion, cache.notebookID == notebookID,
           cache.localeID == locale.identifier {
            return cache
        }
        let previous = dailyNoteIndexCache?.localeID == locale.identifier ? dailyNoteIndexCache?.parsedTitles ?? [:] : [:]
        var parsed: [UUID: DailyNoteIndex.ParsedTitle] = [:]
        var oldest: [DayKey: NoteMeta] = [:]
        for meta in notes where meta.notebookID == notebookID && meta.deletedAt == nil {
            let day: DayKey?
            if let known = previous[meta.id], known.title == meta.title {
                day = known.day
            } else {
                day = DailyNoteTitle.parse(meta.title, locale: locale)
            }
            parsed[meta.id] = DailyNoteIndex.ParsedTitle(title: meta.title, day: day)
            guard let day else { continue }
            if let current = oldest[day], (current.createdAt, current.id.uuidString) <= (meta.createdAt, meta.id.uuidString) { continue }
            oldest[day] = meta
        }
        let index = DailyNoteIndex(version: notesVersion, notebookID: notebookID, localeID: locale.identifier,
                                   byDay: oldest.mapValues(\.id),
                                   dayByNote: Dictionary(uniqueKeysWithValues: oldest.map { ($0.value.id, $0.key) }),
                                   parsedTitles: parsed)
        dailyNoteIndexCache = index
        return index
    }

    /// The day of a daily note; nil for any other note.
    func dailyDay(of id: UUID?) -> DayKey? {
        guard let id else { return nil }
        return dailyNoteIndex?.dayByNote[id]
    }

    /// Opens (creating if needed) the day's note: selects its notebook and the note, caret at `{{cursor}}` or the end.
    func openDailyNote(for date: Date) {
        guard let meta = try? dailyNote(for: date, createIfMissing: true) else { return }
        searchText = ""
        if let notebookID = meta.notebookID { selection = .notebook(notebookID) }
        if RichTextEditor.pendingCaret[meta.id] == nil, !meta.isLocked {
            RichTextEditor.pendingCaret[meta.id] = body(for: meta.id).length
        }
        selectedNoteID = meta.id
    }

    /// Opens the note for `day`, a day in the daily calendar.
    func openDailyNote(for day: DayKey) {
        guard let date = day.date(calendar: DayKey.dailyCalendar(), hour: 12) else { return }
        openDailyNote(for: date)
    }

    func dailyNoteDays(inMonthOf date: Date) -> Set<DayKey> {
        let month = DayKey(date, calendar: DayKey.dailyCalendar())
        return Set((dailyNoteIndex?.byDay.keys).map { $0.filter { $0.year == month.year && $0.month == month.month } } ?? [])
    }

    /// The daily note on the nearest earlier (or later) day that has one.
    func adjacentDailyNote(to id: UUID, forward: Bool) -> NoteMeta? {
        guard let index = dailyNoteIndex, let day = index.dayByNote[id] else { return nil }
        let other = forward
            ? index.byDay.keys.filter { $0 > day }.min()
            : index.byDay.keys.filter { $0 < day }.max()
        return other.flatMap { index.byDay[$0] }.flatMap { note(with: $0) }
    }

    /// ‹ › in a daily note's header. Reveals the note when the current list (a search, Pinned…) doesn't show it.
    func openAdjacentDailyNote(to id: UUID, forward: Bool) {
        guard let other = adjacentDailyNote(to: id, forward: forward) else { return }
        navigate(to: other.id, heading: nil)
    }
}
