import Foundation

/// Renames `tag:` and `notebook:`/`in:` values inside a query, leaving the rest of the text as written.
public enum QueryRewriter {
    public static func renamingTag(_ from: String, to: String, in query: String) -> String {
        let old = TokenGrammar.normalizedTag(from)
        return rewrite(query, keys: ["tag"]) { value in
            let hash = value.hasPrefix("#") ? "#" : ""
            let name = TokenGrammar.normalizedTag(String(value.dropFirst(hash.count)))
            if name == old { return hash + to }
            if name.hasPrefix(old + "/") { return hash + to + name.dropFirst(old.count) }
            return nil
        }
    }

    /// Values equal to the old name, or starting with it followed by a `/`, are rewritten.
    public static func renamingNotebook(_ from: String, to: String, in query: String) -> String {
        rewrite(query, keys: ["notebook", "in"]) { value in
            if same(value, from) { return to }
            let prefix = from + "/"
            if value.count > prefix.count, same(String(value.prefix(prefix.count)), prefix) {
                return to + "/" + value.dropFirst(prefix.count)
            }
            return nil
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }

    private static func rewrite(_ query: String, keys: Set<String>, _ replacement: (String) -> String?) -> String {
        var result = query
        for lexeme in QueryLexer.lex(query).reversed() {
            guard lexeme.kind == .term, let key = lexeme.key, keys.contains(key), let range = lexeme.valueRange,
                  let new = replacement(String(query[range])) else { continue }
            let needsQuotes = !lexeme.quoted && new.contains { $0.isWhitespace || $0 == "\"" || $0 == "(" || $0 == ")" }
            let lower = result.index(result.startIndex, offsetBy: query.distance(from: query.startIndex, to: range.lowerBound))
            let upper = result.index(lower, offsetBy: query.distance(from: range.lowerBound, to: range.upperBound))
            result.replaceSubrange(lower..<upper, with: needsQuotes ? "\"\(new)\"" : new)
        }
        return result
    }
}
