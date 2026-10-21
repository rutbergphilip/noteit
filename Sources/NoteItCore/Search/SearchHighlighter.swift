import Foundation

public struct Snippet: Sendable, Equatable {
    public var text: String
    public var highlights: [NSRange]

    public init(text: String, highlights: [NSRange]) {
        self.text = text
        self.highlights = highlights
    }
}

/// Finds folded terms in original text (spec 5.3).
public enum SearchHighlighter {
    public static func ranges(of terms: [String], in text: String) -> [NSRange] {
        merge(termRanges(terms, in: text).flatMap(\.self))
    }

    /// The window of `maxLength` UTF-16 units with the most distinct terms, preferring a line or sentence start,
    /// with `…` on cut sides. Nil when no term occurs.
    public static func snippet(of text: String, terms: [String], maxLength: Int) -> Snippet? {
        let perTerm = termRanges(terms, in: text)
        let all = perTerm.enumerated().flatMap { term, ranges in ranges.map { (range: $0, term: term) } }
            .sorted { $0.range.location < $1.range.location }
        guard let firstHit = all.first, maxLength > 0 else { return nil }
        let ns = text as NSString
        let length = ns.length

        var bestStart = firstHit.range.location
        var bestCount = 0
        for hit in all {
            let start = hit.range.location
            let end = start + maxLength
            let distinct = Set(all.lazy.filter { $0.range.location >= start && NSMaxRange($0.range) <= end }.map(\.term)).count
            if distinct > bestCount {
                bestCount = distinct
                bestStart = start
            }
        }

        // Back up to a line or sentence start close before the match, else to a word start.
        let lookBack = max(0, bestStart - min(40, maxLength / 3))
        var start = bestStart
        var i = bestStart
        var foundBoundary = false
        while i > lookBack {
            let c = ns.character(at: i - 1)
            if c == 0x0A || c == 0x0D {
                start = i
                foundBoundary = true
                break
            }
            if i >= 2, c == 0x20, [0x2E, 0x21, 0x3F].contains(ns.character(at: i - 2)) {
                start = i
                foundBoundary = true
                break
            }
            i -= 1
        }
        if !foundBoundary {
            start = lookBack
            if start > 0 {
                while start < bestStart, ns.character(at: start - 1) != 0x20 { start += 1 }
            }
        }
        if start == 0 || foundBoundary {
            while start < bestStart, isSpace(ns.character(at: start)) { start += 1 }
        }
        var end = min(length, start + maxLength)
        if end < length {
            var cut = end
            while cut > bestStart, ns.character(at: cut) != 0x20 { cut -= 1 }
            if cut > bestStart { end = cut }
        }
        start = adjusted(ns, start, forward: true)
        end = adjusted(ns, end, forward: false)

        let window = ns.substring(with: NSRange(location: start, length: end - start))
        let body = String(window.map { $0.isNewline ? " " : $0 })
        let prefix = start > 0 ? "…" : ""
        let suffix = end < length ? "…" : ""
        let shift = (prefix as NSString).length
        let highlights = merge(all.map(\.range).filter { $0.location >= start && NSMaxRange($0) <= end })
            .map { NSRange(location: $0.location - start + shift, length: $0.length) }
        return Snippet(text: prefix + body + suffix, highlights: highlights)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

    /// Keeps a boundary off the middle of a surrogate pair.
    private static func adjusted(_ ns: NSString, _ index: Int, forward: Bool) -> Int {
        guard index > 0, index < ns.length else { return index }
        let range = ns.rangeOfComposedCharacterSequence(at: index)
        guard range.location != index else { return index }
        return forward ? NSMaxRange(range) : range.location
    }

    /// Ranges of each term, in original UTF-16 offsets. Each character is folded on its own, keeping a map back.
    static func termRanges(_ terms: [String], in text: String) -> [[NSRange]] {
        let wanted = terms.filter { !$0.isEmpty }
        guard !wanted.isEmpty, !text.isEmpty else { return terms.map { _ in [] } }
        var folded: [unichar] = []
        folded.reserveCapacity(text.utf16.count)
        var starts: [Int] = []          // folded UTF-16 offset -> original UTF-16 offset of its character
        var ends: [Int] = []
        var offset = 0
        for character in text {
            if let ascii = character.asciiValue, character.utf16.count == 1 {
                let lower = (65...90).contains(ascii) ? ascii + 32 : ascii
                folded.append(unichar(lower))
                starts.append(offset)
                ends.append(offset + 1)
                offset += 1
                continue
            }
            let width = character.utf16.count
            for unit in TextFold.fold(String(character)).utf16 {
                folded.append(unit)
                starts.append(offset)
                ends.append(offset + width)
            }
            offset += width
        }
        let haystack = NSString(characters: folded, length: folded.count)
        return terms.map { term in
            guard !term.isEmpty else { return [] }
            var result: [NSRange] = []
            var search = NSRange(location: 0, length: haystack.length)
            while search.length > 0 {
                let found = haystack.range(of: term, options: [.literal], range: search)
                guard found.location != NSNotFound, found.length > 0 else { break }
                let lower = starts[found.location]
                let upper = ends[NSMaxRange(found) - 1]
                result.append(NSRange(location: lower, length: upper - lower))
                let next = NSMaxRange(found)
                search = NSRange(location: next, length: haystack.length - next)
            }
            return result
        }
    }

    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
