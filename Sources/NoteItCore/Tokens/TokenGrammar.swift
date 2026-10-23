import Foundation

public enum TokenKind: Sendable, Equatable {
    /// Lowercased and NFC, segments joined with "/".
    case tag(String)
    case due(LocalDateTime)
    case remind(LocalDateTime, done: Bool)
}

public struct TextToken: Sendable, Equatable {
    public var kind: TokenKind
    /// UTF-16 range of the whole token, `#` or `@` included.
    public var range: NSRange

    public init(kind: TokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

/// The tokens NoteIt reads from note text: `#tag/sub`, `@due(…)` and `@remind(…)`. Callers pass text with code
/// and links already blanked out (`NoteStore.maskedForTokens`).
public enum TokenGrammar {
    public static let maxTagDepth = 5

    static let segment = "[\\p{L}_][\\p{L}\\p{M}\\p{N}_\\-]*"
    /// `#` must start the text or follow whitespace, an opening bracket or quote, `,` or `;`, so `?q=#swift` and
    /// `site.com/#anchor` aren't tags.
    static let tagPattern = "(?<![^\\s\\p{Ps}\\p{Pi},;\"'])#(\(segment)(?:/\(segment)){0,\(maxTagDepth - 1)})"
    static let duePattern = "@due\\((\\d{4}-\\d{2}-\\d{2})(?: (\\d{2}):(\\d{2}))?\\)"
    static let remindPattern = "@remind\\((\\d{4}-\\d{2}-\\d{2}) (\\d{2}):(\\d{2})( done)?\\)"

    static let tagRegex = try! NSRegularExpression(pattern: tagPattern)
    static let dueRegex = try! NSRegularExpression(pattern: duePattern)
    static let remindRegex = try! NSRegularExpression(pattern: remindPattern)
    static let tagNameRegex = try! NSRegularExpression(
        pattern: "^\(segment)(?:/\(segment)){0,\(maxTagDepth - 1)}$")

    /// Every token in order of position.
    public static func tokens(inMasked text: String) -> [TextToken] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [TextToken] = []
        for match in tagRegex.matches(in: text, range: full) {
            result.append(TextToken(kind: .tag(normalizedTag(ns.substring(with: match.range(at: 1)))), range: match.range))
        }
        for match in dueRegex.matches(in: text, range: full) {
            guard let value = dateTime(match, in: ns) else { continue }
            result.append(TextToken(kind: .due(value), range: match.range))
        }
        for match in remindRegex.matches(in: text, range: full) {
            guard let value = dateTime(match, in: ns) else { continue }
            result.append(TextToken(kind: .remind(value, done: match.range(at: 4).location != NSNotFound),
                                    range: match.range))
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    /// The tags in order of first appearance, without duplicates.
    public static func tags(inMasked text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var result: [String] = []
        for match in tagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = normalizedTag(ns.substring(with: match.range(at: 1)))
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    /// A tag name without `#`: one to five segments of letters, digits, `-` and `_`, not starting with a digit.
    public static func isValidTagName(_ name: String) -> Bool {
        let ns = name as NSString
        return tagNameRegex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) != nil
    }

    public static func normalizedTag(_ tag: String) -> String {
        tag.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }

    private static func dateTime(_ match: NSTextCheckingResult, in ns: NSString) -> LocalDateTime? {
        let date = ns.substring(with: match.range(at: 1))
        guard match.range(at: 2).location != NSNotFound else { return LocalDateTime(token: date) }
        return LocalDateTime(token: "\(date) \(ns.substring(with: match.range(at: 2))):\(ns.substring(with: match.range(at: 3)))")
    }
}
