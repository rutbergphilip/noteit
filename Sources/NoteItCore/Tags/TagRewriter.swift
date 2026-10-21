import Foundation

public enum TagEdit: Sendable, Equatable {
    case rename(from: String, to: String)
    case delete(String)
}

public struct TextEdit: Sendable, Equatable {
    /// UTF-16 range.
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public enum TagRewriter {
    public static let invalidNameMessage = "Tags can use letters, numbers, - and _, and / to nest."
    public static let insideItselfMessage = "A tag can’t be moved inside itself."
    public static let tooDeepMessage = "Tags can nest up to \(TokenGrammar.maxTagDepth) levels, and this would put some deeper."

    /// Why `to` can't replace `from`, or nil. Both without `#`. `tags` are the tags in use; a tag nested in `from`
    /// must still fit within `TokenGrammar.maxTagDepth` levels under `to`.
    public static func renameProblem(from: String, to: String, tags: [String] = []) -> String? {
        let target = to.hasPrefix("#") ? String(to.dropFirst()) : to
        guard TokenGrammar.isValidTagName(target) else { return invalidNameMessage }
        let source = TokenGrammar.normalizedTag(from), normalized = TokenGrammar.normalizedTag(target)
        if normalized != source, TagTree.matches(normalized, selected: source) { return insideItselfMessage }
        let sourceDepth = source.split(separator: "/").count, targetDepth = normalized.split(separator: "/").count
        let deepest = tags.lazy.map(TokenGrammar.normalizedTag).filter { TagTree.matches($0, selected: source) }
            .map { $0.split(separator: "/").count - sourceDepth }.max() ?? 0
        if targetDepth + deepest > TokenGrammar.maxTagDepth { return tooDeepMessage }
        return nil
    }

    /// The edits for one note's text with code and links masked out (`NoteStore.maskedForTokens`): non-overlapping,
    /// in descending order, so they can be applied one after another. A tag nested under the edited one is edited too.
    public static func edits(for edit: TagEdit, inMasked text: String) -> [TextEdit] {
        let ns = text as NSString
        var result: [TextEdit] = []
        for token in TokenGrammar.tokens(inMasked: text) {
            guard case .tag(let tag) = token.kind else { continue }
            switch edit {
            case let .rename(from, to):
                let source = TokenGrammar.normalizedTag(from)
                guard TagTree.matches(tag, selected: source) else { continue }
                let written = ns.substring(with: NSRange(location: token.range.location + 1, length: token.range.length - 1))
                let rest = written.split(separator: "/", omittingEmptySubsequences: false)
                    .dropFirst(source.split(separator: "/").count)
                let target = to.hasPrefix("#") ? String(to.dropFirst()) : to
                let replacement = "#" + ([target] + rest.map(String.init)).joined(separator: "/")
                if replacement != ns.substring(with: token.range) {
                    result.append(TextEdit(range: token.range, replacement: replacement))
                }
            case let .delete(name):
                guard TagTree.matches(tag, selected: TokenGrammar.normalizedTag(name)) else { continue }
                result.append(TextEdit(range: removalRange(token.range, in: ns), replacement: ""))
            }
        }
        return result.sorted { $0.range.location > $1.range.location }
    }

    /// The token and one space next to it, preferring the one after.
    static func removalRange(_ range: NSRange, in ns: NSString) -> NSRange {
        let end = NSMaxRange(range)
        if end < ns.length, isSpace(ns.character(at: end)) {
            return NSRange(location: range.location, length: range.length + 1)
        }
        if range.location > 0, isSpace(ns.character(at: range.location - 1)) {
            return NSRange(location: range.location - 1, length: range.length + 1)
        }
        return range
    }

    private static func isSpace(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }
}
