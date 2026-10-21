import AppKit
import NoteItCore

/// Additive helpers used by the menu bar panel and quick capture.
extension NoteStore {
    /// Notebook used for quick captures. Unset → "Inbox" (or the first notebook); "none" → no notebook.
    var defaultNotebookIDForNewNotes: UUID? {
        let stored = UserDefaults.standard.string(forKey: PrefKey.defaultNotebookID)
        if stored == PrefDefault.noNotebook { return nil }
        if let stored, let id = UUID(uuidString: stored), notebook(with: id) != nil { return id }
        let ordered = sortedNotebooks
        return (ordered.first { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame } ?? ordered.first)?.id
    }

    /// Creates a note from plain text. Returns nil if both title and body are blank.
    @discardableResult
    func captureNote(title: String, body: String, in notebookID: UUID?) -> NoteMeta? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else { return nil }
        if defaultTemplateID(for: notebookID) != nil {
            let content = NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: Self.capturedTextSize)])
            if let initial = templatedBody(for: notebookID, title: title, content: content) {
                return createNote(in: notebookID, initial: initial)
            }
        }
        return createNote(in: notebookID, initial: Self.capturedText(title: title, body: body))
    }

    /// The reminder Quick Capture offers: the future date written in the note's first line, unless it already has one.
    nonisolated static func captureReminder(title: String, body: String, now: Date, calendar: Calendar,
                                            defaultMinutes: Int) -> LocalDateTime? {
        let line = captureFirstLine(title: title, body: body)
        guard !line.contains("@remind(") else { return nil }
        return reminderDate(inLine: line, now: now, calendar: calendar, defaultMinutes: defaultMinutes)
    }

    /// Title and body with `@remind(…)` added to the end of the first line.
    nonisolated static func addingCaptureReminder(_ at: LocalDateTime, title: String, body: String) -> (title: String, body: String) {
        let token = "@remind(\(at.token))"
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return (trimmedTitle + " " + token, body) }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmedBody.components(separatedBy: "\n")
        lines[0] += " " + token
        return (title, lines.joined(separator: "\n"))
    }

    private nonisolated static func captureFirstLine(title: String, body: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmedTitle.isEmpty ? body.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedTitle
        return text.components(separatedBy: "\n").first ?? ""
    }

    /// A bold first-line title followed by the body, in the editor's font size.
    static func capturedText(title: String, body: String) -> NSAttributedString {
        let size = capturedTextSize
        let styledBody = NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: size)])
        return capturedText(title: title, body: styledBody)
    }

    /// Same title line as the plain-text variant, followed by an already styled body.
    nonisolated static func capturedText(title: String, body: NSAttributedString) -> NSAttributedString {
        let size = capturedTextSize
        let text = NSMutableAttributedString()
        if !title.isEmpty {
            text.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: round(size * 1.6), weight: .bold)]))
            if body.length > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size)])) }
        }
        if body.length > 0 {
            text.append(body)
        }
        return text
    }

    private nonisolated static var capturedTextSize: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: PrefKey.editorFontSize) as? Double ?? PrefDefault.editorFontSize)
    }

    /// Makes a note the visible selection in the main window.
    func reveal(_ id: UUID) {
        searchText = ""
        selection = .allNotes
        selectedNoteID = id
    }
}
