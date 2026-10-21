import Foundation

public struct RankedHit: Sendable, Equatable {
    public var index: Int
    public var score: Double
    /// Every term that matched, matched only in the image text.
    public var onlyInImage: Bool

    public init(index: Int, score: Double, onlyInImage: Bool) {
        self.index = index
        self.score = score
        self.onlyInImage = onlyInImage
    }
}

/// Best Match order (spec 5.1): BM25 over the folded body, title, tag, whole-query, proximity and recency boosts.
public enum SearchRanker {
    static let k1 = 1.2
    static let b = 0.75
    static let proximityWindow = 80

    /// Hits for every document, best first; ties go to pinned, then last edited.
    public static func rank(_ docs: [some SearchDocument], query: SearchQuery, foldedQueryText: String, now: Date) -> [RankedHit] {
        let terms = textTerms(query.root)
        let needles = terms.map { Array($0.utf8) }
        let count = docs.count
        guard count > 0 else { return [] }
        let texts = docs.map(\.foldedText)
        let images = docs.map(\.foldedImageText)
        let averageLength = max(1, Double(texts.reduce(0) { $0 + $1.count }) / Double(count))

        var bodyTF = Array(repeating: [Double](repeating: 0, count: needles.count), count: count)
        var imageTF = bodyTF
        var df = [Int](repeating: 0, count: needles.count)
        for (d, doc) in docs.enumerated() {
            for (t, needle) in needles.enumerated() {
                bodyTF[d][t] = weightedCount(needle, in: texts[d])
                imageTF[d][t] = weightedCount(needle, in: images[d])
                if bodyTF[d][t] > 0 || imageTF[d][t] > 0 || doc.foldedTitle.contains(terms[t]) { df[t] += 1 }
            }
        }
        let n = Double(count)
        let idf = df.map { log(1 + (n - Double($0) + 0.5) / (Double($0) + 0.5)) }
        let idfAverage = idf.isEmpty ? 0 : idf.reduce(0, +) / Double(idf.count)
        let wholeQuery = foldedQueryText.trimmingCharacters(in: .whitespacesAndNewlines)

        var hits: [RankedHit] = []
        hits.reserveCapacity(count)
        for (d, doc) in docs.enumerated() {
            var score = 0.0
            var inText = false
            var inImage = false
            let length = Double(texts[d].count)
            let imageLength = Double(images[d].count)
            for t in needles.indices {
                let tf = bodyTF[d][t]
                if tf > 0 {
                    score += idf[t] * tf * (k1 + 1) / (tf + k1 * (1 - b + b * length / averageLength))
                    inText = true
                }
                let itf = imageTF[d][t]
                if itf > 0 {
                    score += 0.5 * idf[t] * itf * (k1 + 1) / (itf + k1 * (1 - b + b * imageLength / averageLength))
                    inImage = true
                }
                if doc.foldedTitle.contains(terms[t]) {
                    score += 2 * idf[t]
                    if doc.foldedTitle.hasPrefix(terms[t]) { score += idf[t] }
                    inText = true
                }
                if doc.tags.contains(terms[t]) {
                    score += idf[t]
                    inText = true
                }
            }
            if !wholeQuery.isEmpty, doc.foldedTitle == wholeQuery { score += 3 }
            if needles.count > 1, withinWindow(needles, texts[d]) { score += 0.5 * idfAverage }
            let ageDays = max(0, now.timeIntervalSince(doc.updatedAt)) / 86400
            score *= 1 + 0.3 * exp(-ageDays / 30)
            hits.append(RankedHit(index: d, score: score, onlyInImage: inImage && !inText))
        }
        return hits.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let x = docs[a.index], y = docs[b.index]
            if x.isPinned != y.isPinned { return x.isPinned }
            if x.updatedAt != y.updatedAt { return x.updatedAt > y.updatedAt }
            return a.index < b.index
        }
    }

    /// Positive words and phrases, in order.
    static func textTerms(_ node: QueryNode, positive: Bool = true) -> [String] {
        switch node {
        case .word(let v), .phrase(let v): return positive && !v.isEmpty ? [v] : []
        case .not(let inner): return textTerms(inner, positive: !positive)
        case .and(let nodes), .or(let nodes):
            var seen = Set<String>()
            return nodes.flatMap { textTerms($0, positive: positive) }.filter { seen.insert($0).inserted }
        default: return []
        }
    }

    /// Occurrences at the start of a word count 1, inside a word 0.5.
    static func weightedCount(_ needle: [UInt8], in haystack: [UInt8]) -> Double {
        var total = 0.0
        var from = 0
        while let at = ByteSearch.firstIndex(haystack, needle, from: from) {
            total += isWordStart(haystack, at) ? 1 : 0.5
            from = at + 1
        }
        return total
    }

    static func isWordStart(_ bytes: [UInt8], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = bytes[index - 1]
        if before >= 0x80 { return false }
        let scalar = Unicode.Scalar(before)
        return !(CharacterSet.alphanumerics.contains(scalar))
    }

    /// True when one occurrence of every term fits in `proximityWindow` bytes.
    static func withinWindow(_ needles: [[UInt8]], _ text: [UInt8]) -> Bool {
        var events: [(start: Int, end: Int, term: Int)] = []
        for (t, needle) in needles.enumerated() {
            var from = 0
            var found = 0
            while found < 200, let at = ByteSearch.firstIndex(text, needle, from: from) {
                events.append((at, at + needle.count, t))
                from = at + 1
                found += 1
            }
            if found == 0 { return false }
        }
        events.sort { $0.start < $1.start }
        var counts = [Int](repeating: 0, count: needles.count)
        var covered = 0
        var left = 0
        for right in events.indices {
            if counts[events[right].term] == 0 { covered += 1 }
            counts[events[right].term] += 1
            while covered == needles.count {
                let end = events[left...right].map(\.end).max() ?? events[right].end
                if end - events[left].start <= proximityWindow { return true }
                counts[events[left].term] -= 1
                if counts[events[left].term] == 0 { covered -= 1 }
                left += 1
            }
        }
        return false
    }
}

extension SearchQuery {
    /// Folded words and phrases that aren't negated, in order.
    public var textTerms: [String] { SearchRanker.textTerms(root) }
}
