import Foundation
import NoteItCore

/// Suggestions for the search being typed in the smart folder sheet: filter keys, then values for the key
/// (tags, notebooks, `is:`/`has:` filters, dates). Completes the last term only.
enum QueryCompletionSource {
    struct Suggestion: Equatable, Identifiable {
        let title: String
        /// The whole search after accepting.
        let text: String
        var id: String { title }
    }

    static let maxSuggestions = 8
    static let keys = ["tag", "notebook", "in", "title", "is", "has", "due", "edited", "created"]
    static let isValues = ["pinned", "todo", "done", "untagged", "conflict"]
    static let hasValues = ["due", "reminder", "attachment"]
    static let dateValues = ["today", "yesterday", "this-week", "last-week", "this-month", "<7d", ">30d"]

    static func suggestions(for text: String, tags: [String], notebooks: [String]) -> [Suggestion] {
        guard let last = text.last, !last.isWhitespace else { return [] }
        let start = text.lastIndex(where: \.isWhitespace).map(text.index(after:)) ?? text.startIndex
        var term = text[start...]
        let prefixEnd = term.firstIndex { $0 != "-" && $0 != "(" } ?? term.endIndex
        let head = String(text[..<prefixEnd])
        term = term[prefixEnd...]
        guard !term.isEmpty else { return [] }

        guard let colon = term.firstIndex(of: ":") else {
            let typed = term.lowercased()
            return keys.filter { $0.hasPrefix(typed) && $0 != typed }
                .prefix(maxSuggestions).map { Suggestion(title: "\($0):", text: head + "\($0):") }
        }
        let key = term[..<colon].lowercased()
        var typed = String(term[term.index(after: colon)...])
        if typed.hasPrefix("\"") { typed.removeFirst() }
        let candidates: [String]
        switch key {
        case "tag": candidates = tags
        case "notebook", "in": candidates = notebooks
        case "is": candidates = isValues
        case "has": candidates = hasValues
        case "due": candidates = ["overdue"] + dateValues
        case "edited", "created": candidates = dateValues
        default: return []
        }
        let folded = typed.lowercased()
        let matches = candidates.filter { candidate in
            let lower = candidate.lowercased()
            return lower != folded && (folded.isEmpty || lower.hasPrefix(folded) || lower.contains("/" + folded))
        }
        return matches.prefix(maxSuggestions).map { value in
            let quoted = value.contains(where: { $0.isWhitespace || $0 == "\"" })
                ? "\"\(value.replacingOccurrences(of: "\"", with: ""))\"" : value
            return Suggestion(title: "\(key):\(quoted)", text: head + "\(key):\(quoted) ")
        }
    }
}
