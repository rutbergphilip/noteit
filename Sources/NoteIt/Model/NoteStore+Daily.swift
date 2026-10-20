import AppKit
import Foundation

/// Daily-note lookup. Behaviour owned by the linking plan (§10); built in foundations Task 4.6. Works regardless of
/// `DailyNotes.isAvailable`; callers check the gate.
extension NoteStore {
    static let dailyNotesNotebookName = "Daily Notes"

    func dailyNotesNotebookID(createIfMissing: Bool) -> UUID? {
        if let raw = preferences.string(forKey: PrefKey.dailyNotesNotebookID), let id = UUID(uuidString: raw),
           notebook(with: id) != nil {
            return id
        }
        guard createIfMissing else { return nil }
        let created = createNotebook(name: Self.dailyNotesNotebookName, symbol: "calendar",
                                     colorHex: NotebookPalette.colors.first ?? Tokens.Hex.notebookBlue)
        preferences.set(created.id.uuidString, forKey: PrefKey.dailyNotesNotebookID)
        return created.id
    }

    /// The live note in the Daily Notes notebook whose title is `date`'s day in any `DailyTitleFormat` (the oldest
    /// one when several match). With `createIfMissing`, a new note titled in the chosen format otherwise.
    func dailyNote(for date: Date, createIfMissing: Bool) throws -> NoteMeta? {
        guard let notebookID = dailyNotesNotebookID(createIfMissing: createIfMissing) else { return nil }
        let calendar = Calendar.current
        let locale = Locale.current
        let day = DayKey(date, calendar: calendar)
        let existing = notes
            .filter { $0.notebookID == notebookID && $0.deletedAt == nil
                && DailyNoteTitle.parse($0.title, locale: locale) == day }
            .min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        if let existing { return existing }
        guard createIfMissing else { return nil }
        let format = preferences.string(forKey: PrefKey.dailyNoteTitleFormat).flatMap(DailyTitleFormat.init) ?? .iso
        let title = DailyNoteTitle.title(for: day, format: format, locale: locale)
        return createNote(in: notebookID, initial: NSAttributedString(string: title, attributes: EditorStyle.bodyAttributes))
    }
}
