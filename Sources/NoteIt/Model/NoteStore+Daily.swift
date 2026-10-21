import AppKit
import Foundation

/// Daily-note lookup. Behaviour owned by the linking plan (§10); built in foundations Task 4.6. Works regardless of
/// `DailyNotes.isAvailable`; callers check the gate.
extension NoteStore {
    static let dailyNotesNotebookName = "Daily Notes"

    /// The notebook from the preference, else the first one named "Daily Notes" (synced from another Mac,
    /// imported, or left after the preference was reset). Never creates one or writes the preference.
    var dailyNotesNotebookIDIfSet: UUID? {
        if let raw = preferences.string(forKey: PrefKey.dailyNotesNotebookID), let id = UUID(uuidString: raw),
           notebook(with: id) != nil {
            return id
        }
        return sortedNotebooks.first {
            $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(Self.dailyNotesNotebookName) == .orderedSame
        }?.id
    }

    func dailyNotesNotebookID(createIfMissing: Bool) -> UUID? {
        if let id = dailyNotesNotebookIDIfSet {
            if createIfMissing, preferences.string(forKey: PrefKey.dailyNotesNotebookID) != id.uuidString {
                preferences.set(id.uuidString, forKey: PrefKey.dailyNotesNotebookID)
            }
            return id
        }
        guard createIfMissing else { return nil }
        let created = createNotebook(name: Self.dailyNotesNotebookName, symbol: "calendar",
                                     colorHex: NotebookPalette.colors.first ?? Tokens.Hex.notebookBlue)
        preferences.set(created.id.uuidString, forKey: PrefKey.dailyNotesNotebookID)
        return created.id
    }

    /// The live note in the Daily Notes notebook whose title is `date`'s day in any `DailyTitleFormat` (the oldest
    /// one when several match). With `createIfMissing`, a new note titled in the chosen format otherwise. Days are
    /// Gregorian whatever the system calendar is; only `systemCalendar`'s time zone is used. Only `interactive`
    /// callers (the user opening the note) let the template read the clipboard and place the caret.
    func dailyNote(for date: Date, createIfMissing: Bool, interactive: Bool = false,
                   systemCalendar: Calendar = .current) throws -> NoteMeta? {
        guard let notebookID = dailyNotesNotebookID(createIfMissing: createIfMissing) else { return nil }
        let locale = Locale.current
        let day = DayKey(date, calendar: DayKey.dailyCalendar(timeZone: systemCalendar.timeZone))
        let existing = notes
            .filter { $0.notebookID == notebookID && $0.deletedAt == nil
                && DailyNoteTitle.parse($0.title, locale: locale) == day }
            .min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        if let existing { return existing }
        guard createIfMissing else { return nil }
        let format = preferences.string(forKey: PrefKey.dailyNoteTitleFormat).flatMap(DailyTitleFormat.init) ?? .iso
        let title = DailyNoteTitle.title(for: day, format: format, locale: locale)
        if let template = dailyNoteTemplateID,
           let date = day.date(calendar: DayKey.dailyCalendar(timeZone: systemCalendar.timeZone), hour: 9),
           let expansion = expandedTemplate(template, title: title, date: date, readsClipboard: interactive) {
            // The title line must stay the date, or the note would never be found again.
            let text = NSMutableAttributedString(attributedString: expansion.text)
            var caret = expansion.caret
            let firstLine = text.string.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if DailyNoteTitle.parse(firstLine, locale: locale) != day {
                let heading = NSAttributedString(string: title + "\n", attributes: EditorStyle.bodyAttributes)
                text.insert(heading, at: 0)
                caret = caret.map { $0 + heading.length }
            }
            let meta = createNote(in: notebookID, initial: text)
            if interactive, let caret { RichTextEditor.pendingCaret[meta.id] = caret }
            return meta
        }
        return createNote(in: notebookID, initial: NSAttributedString(string: title, attributes: EditorStyle.bodyAttributes))
    }

    /// Settings › Editor › Daily Notes › Template, while it is still a usable template.
    var dailyNoteTemplateID: UUID? {
        guard let raw = preferences.string(forKey: PrefKey.dailyNoteTemplateID), let id = UUID(uuidString: raw),
              let meta = note(with: id), meta.deletedAt == nil, !meta.isLocked, isTemplate(id) else { return nil }
        return id
    }
}
