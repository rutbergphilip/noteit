import CryptoKit
import Foundation

/// A checkbox paragraph. `text` is the paragraph without its marker, tokens included.
public struct TaskLine: Sendable, Equatable, Codable {
    public var paragraph: Int
    public var text: String
    public var checked: Bool
    public var due: LocalDateTime?
    public var remind: LocalDateTime?
    public var remindDone: Bool
    /// Hex SHA-256 of the whole paragraph, marker included.
    public var textHash: String

    public init(paragraph: Int, text: String, checked: Bool, due: LocalDateTime?, remind: LocalDateTime?,
                remindDone: Bool, textHash: String) {
        self.paragraph = paragraph
        self.text = text
        self.checked = checked
        self.due = due
        self.remind = remind
        self.remindDone = remindDone
        self.textHash = textHash
    }
}

/// A paragraph with an `@remind(…)` token. `text` is the line as a notification shows it (`TaskParser.displayText`).
public struct ReminderLine: Sendable, Equatable, Codable {
    public var paragraph: Int, text: String, at: LocalDateTime, done: Bool, isTask: Bool, checked: Bool
    public var textHash: String

    public init(paragraph: Int, text: String, at: LocalDateTime, done: Bool, isTask: Bool, checked: Bool, textHash: String) {
        self.paragraph = paragraph
        self.text = text
        self.at = at
        self.done = done
        self.isTask = isTask
        self.checked = checked
        self.textHash = textHash
    }
}

public enum TaskParser {
    static let uncheckedPrefix = ChecklistMarkers.unchecked + "\t"
    static let checkedPrefix = ChecklistMarkers.checked + "\t"

    /// Paragraphs are separated by "\n"; the first `@due` and the first `@remind` on a line count.
    public static func parse(masked text: String) -> (tasks: [TaskLine], reminders: [ReminderLine]) {
        var tasks: [TaskLine] = []
        var reminders: [ReminderLine] = []
        guard text.contains(ChecklistMarkers.unchecked) || text.contains(ChecklistMarkers.checked)
                || text.contains("@remind(") else { return ([], []) }
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let checked: Bool?
            if line.hasPrefix(uncheckedPrefix) {
                checked = false
            } else if line.hasPrefix(checkedPrefix) {
                checked = true
            } else {
                checked = nil
            }
            let hasRemind = line.contains("@remind(")
            guard checked != nil || hasRemind else { continue }
            let body = checked == nil ? line : String(line.dropFirst(2))
            var due: LocalDateTime?
            var remind: (LocalDateTime, Bool)?
            for token in TokenGrammar.tokens(inMasked: body) {
                switch token.kind {
                case .due(let value) where due == nil: due = value
                case .remind(let value, let done) where remind == nil: remind = (value, done)
                default: break
                }
            }
            let hash = textHash(line)
            if let checked {
                tasks.append(TaskLine(paragraph: index, text: body, checked: checked, due: due, remind: remind?.0,
                                      remindDone: remind?.1 ?? false, textHash: hash))
            }
            if let remind {
                reminders.append(ReminderLine(paragraph: index, text: displayText(line), at: remind.0, done: remind.1,
                                              isTask: checked != nil, checked: checked ?? false, textHash: hash))
            }
        }
        return (tasks, reminders)
    }

    /// The line without its checkbox marker and without `@due`/`@remind` tokens, spaces collapsed.
    public static func displayText(_ line: String) -> String {
        var body = line
        if body.hasPrefix(uncheckedPrefix) || body.hasPrefix(checkedPrefix) { body = String(body.dropFirst(2)) }
        let ns = NSMutableString(string: body)
        for token in TokenGrammar.tokens(inMasked: body).reversed() {
            switch token.kind {
            case .due, .remind: ns.replaceCharacters(in: token.range, with: " ")
            case .tag: break
            }
        }
        return (ns as String).split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    public static func textHash(_ paragraph: String) -> String {
        SHA256.hash(data: Data(paragraph.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
