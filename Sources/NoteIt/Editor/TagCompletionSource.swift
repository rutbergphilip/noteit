import AppKit
import NoteItCore

/// `#` suggestions: existing tags ranked by fuzzy match, then by how many notes use them.
@MainActor
final class TagCompletionSource: InlineCompletionSource {
    let store: NoteStore

    init(store: NoteStore) {
        self.store = store
    }

    var accessibilityName: String { "Tag" }

    /// Characters a `#` may follow and still start a tag (as in `TokenGrammar`).
    static func isBoundary(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || ",;\"'".unicodeScalars.contains(scalar)
            || [.openPunctuation, .initialPunctuation].contains(scalar.properties.generalCategory)
    }

    func shouldEnd(for query: String) -> Bool {
        guard !query.isEmpty else { return false }
        return !TokenGrammar.isValidTagName(query.hasSuffix("/") ? String(query.dropLast()) : query)
    }

    func rows(for query: String) -> [InlineCompletionRow] {
        Self.rank(query: query, counts: tagCounts()).map { tag, count, matched in
            InlineCompletionRow(id: "tag:\(tag)", title: tag, detail: count == 1 ? "1 note" : "\(count) notes",
                                matched: matched, symbol: "number")
        }
    }

    func accept(_ row: InlineCompletionRow, replacing range: NSRange, in textView: NoteItTextView) {
        guard row.id.hasPrefix("tag:") else { return }
        let tag = String(row.id.dropFirst(4))
        var attrs = textView.typingAttributes
        attrs[.link] = nil
        let after = NSMaxRange(range) < textView.storage.length ? textView.nsString.character(at: NSMaxRange(range)) : 0x20
        let needsSpace = !(UnicodeScalar(after).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false)
        let text = NSAttributedString(string: tag + (needsSpace ? " " : ""), attributes: attrs)
        _ = textView.replace(range, with: text, select: NSRange(location: range.location + text.length, length: 0), actionName: "Tag")
    }

    private func tagCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for note in store.activeNotes {
            for tag in note.tags { counts[tag, default: 0] += 1 }
        }
        return counts
    }

    /// Up to eight tags: best fuzzy match first, then most used, then by name.
    static func rank(query: String, counts: [String: Int]) -> [(String, Int, [Range<String.Index>])] {
        let fuzzy = FuzzyQuery(query)
        var scored: [(tag: String, count: Int, score: Int, matched: [Range<String.Index>])] = []
        for (tag, count) in counts {
            if fuzzy.isEmpty {
                scored.append((tag, count, 0, []))
            } else if let match = FuzzyMatcher.match(fuzzy, in: tag) {
                let ranges = match.matchedIndices.map { offset -> Range<String.Index> in
                    let start = tag.index(tag.startIndex, offsetBy: offset)
                    return start..<tag.index(after: start)
                }
                scored.append((tag, count, match.score, ranges))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.count != b.count { return a.count > b.count }
            return a.tag < b.tag
        }
        return scored.prefix(InlineCompletionController.maxRows).map { ($0.tag, $0.count, $0.matched) }
    }
}
