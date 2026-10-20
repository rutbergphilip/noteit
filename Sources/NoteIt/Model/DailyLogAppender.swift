import AppKit
import Foundation

/// What `DailyLogAppender` appends. Owned by the linking plan; built in foundations Task 4.6.
enum DailyLogContent {
    case plain(String)
    case attributed(NSAttributedString)
}

enum DailyLogError: Error, Equatable {
    case emptyText
}

/// Appends entries to daily notes. Owned by the linking plan; built in foundations Task 4.6.
@MainActor
enum DailyLogAppender {
    /// Appends one entry as the last paragraph of that day's note, through editBody. .plain text goes through
    /// DailyLogLine.format; .attributed content follows DailyLogLine.prefix and keeps its formatting. Callers
    /// that accept Markdown parse it with the existing Markdown importer first and pass .attributed.
    @discardableResult
    static func append(_ content: DailyLogContent, timestamp: Bool = true, to date: Date, in store: NoteStore,
                       now: Date = Date()) throws -> NoteMeta {
        let entry = try makeEntry(content, timestamp: timestamp, now: now)
        guard let note = try store.dailyNote(for: date, createIfMissing: true) else { throw BodyEditError.noteMissing }
        try store.editBody(note.id, actionName: "Log to Daily Note") { body in
            if body.length > 0, !body.string.hasSuffix("\n") {
                body.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
            }
            body.append(entry)
        }
        return store.note(with: note.id) ?? note
    }

    private static func makeEntry(_ content: DailyLogContent, timestamp: Bool, now: Date) throws -> NSAttributedString {
        switch content {
        case .plain(let text):
            guard let line = DailyLogLine.format(text: text, at: now, timeZone: .current, timestamp: timestamp) else {
                throw DailyLogError.emptyText
            }
            return NSAttributedString(string: line, attributes: EditorStyle.bodyAttributes)
        case .attributed(let text):
            let trimmed = trimmed(text)
            guard trimmed.length > 0 else { throw DailyLogError.emptyText }
            let entry = NSMutableAttributedString(string: DailyLogLine.prefix(at: now, timeZone: .current, timestamp: timestamp),
                                                  attributes: EditorStyle.bodyAttributes)
            entry.append(trimmed)
            return entry
        }
    }

    private static func trimmed(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        let keep = CharacterSet.whitespacesAndNewlines.inverted
        let first = string.rangeOfCharacter(from: keep)
        guard first.location != NSNotFound else { return NSAttributedString() }
        let last = string.rangeOfCharacter(from: keep, options: .backwards)
        return text.attributedSubstring(from: NSRange(location: first.location,
                                                      length: NSMaxRange(last) - first.location))
    }
}
