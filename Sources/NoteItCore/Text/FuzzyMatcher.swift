import Foundation

/// A fuzzy match result. Moved from the app in foundations Task 1.2.
public struct FuzzyMatch: Equatable, Sendable {
    public let score: Int
    public let matchedIndices: [Int]   // Character offsets into the ORIGINAL candidate string, ascending

    public init(score: Int, matchedIndices: [Int]) {
        self.score = score
        self.matchedIndices = matchedIndices
    }
}

/// A query folded once, for matching against many candidates. Moved from the app in foundations Task 1.2.
public struct FuzzyQuery: Sendable {
    let terms: [[UInt32]]
    let whole: [UInt32]
    public var isEmpty: Bool { terms.isEmpty }

    public init(_ query: String) {
        terms = query.split(whereSeparator: \.isWhitespace)
            .map { FuzzyMatcher.foldedCodes($0) }
            .filter { !$0.isEmpty }
        whole = FuzzyMatcher.foldedCodes(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Subsequence matcher for short titles. Folds like `TextFold.fold` (case, diacritics, width)
/// one Character at a time so match positions map back to the original string. Folded characters
/// are compared as integer codes, and prepared candidates are cached. Moved from the app in foundations Task 1.2.
public enum FuzzyMatcher {
    private static let matchScore = 16
    private static let wordStartBonus = 12
    private static let firstCharacterBonus = 4
    private static let minConsecutiveBonus = 6
    private static let gapOpenPenalty = 3            // plus 1 per skipped character
    private static let maxLeadPenalty = 6
    private static let prefixBonus = 100
    private static let maxLengthPenalty = 20
    private static let unreachable = Int.min / 4

    /// nil when the query doesn't match. Empty/whitespace query matches everything with score 0 and no indices.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        evaluate(FuzzyQuery(query), in: candidate)?.match
    }

    public static func match(_ query: FuzzyQuery, in candidate: String) -> FuzzyMatch? {
        evaluate(query, in: candidate)?.match
    }

    /// `isExact` is true when the folded candidate equals the folded query.
    public static func evaluate(_ query: FuzzyQuery, in candidate: String) -> (match: FuzzyMatch, isExact: Bool)? {
        guard !query.isEmpty else { return (FuzzyMatch(score: 0, matchedIndices: []), false) }
        let target = PreparedCandidateCache.shared.prepared(candidate)
        for term in query.terms where !isSubsequence(term, of: target.codes) {
            return nil
        }

        var total = 0
        var indices: [Int] = []
        for term in query.terms {
            guard let (score, positions) = align(term, in: target) else { return nil }
            total += score
            for position in positions { indices.append(Int(target.origin[position])) }
        }

        let isExact = target.codes == query.whole
        if isExact {
            total += exactBonus(queryLength: query.whole.count)
        } else if target.codes.starts(with: query.whole) {
            total += prefixBonus
        }
        total -= min(target.characterCount / 4, maxLengthPenalty)

        indices.sort()
        var unique: [Int] = []
        unique.reserveCapacity(indices.count)
        for index in indices where unique.last != index { unique.append(index) }
        return (FuzzyMatch(score: max(1, total), matchedIndices: unique), isExact)
    }

    /// Larger than any non-exact score for the same query: a matched character earns at most
    /// 16 + 12 + 4, plus 8 per character and 32 per term of contiguity bonus, plus the prefix bonus.
    private static func exactBonus(queryLength: Int) -> Int {
        1000 + 80 * queryLength
    }

    /// Bonus for a term matched as one contiguous run; big enough that a contiguous occurrence
    /// always beats a scattered alignment of the same term (see `align`).
    private static func contiguityBonus(termLength: Int) -> Int {
        termLength > 1 ? 8 * termLength + 32 : 0
    }

    // MARK: - Folding

    public static func foldedCodes<S: StringProtocol>(_ string: S) -> [UInt32] {
        var result: [UInt32] = []
        for character in string {
            fold(character) { result.append($0) }
        }
        return result
    }

    fileprivate static func fold(_ character: Character, into append: (UInt32) -> Void) {
        if let ascii = character.asciiValue {
            append(ascii >= 65 && ascii <= 90 ? UInt32(ascii) + 32 : UInt32(ascii))
            return
        }
        for folded in TextFold.fold(String(character)) {
            append(code(of: folded))
        }
    }

    /// Single-scalar characters use their scalar value; multi-scalar ones (emoji sequences, flags,
    /// leftover combining marks) get a hash outside the Unicode range.
    private static func code(of character: Character) -> UInt32 {
        var scalars = character.unicodeScalars.makeIterator()
        if let first = scalars.next(), scalars.next() == nil { return first.value }
        var hasher = Hasher()
        hasher.combine(character)
        return 0x0020_0000 | UInt32(truncatingIfNeeded: hasher.finalize())
    }

    fileprivate static func isWordStart(_ character: Character, after previous: Character?) -> Bool {
        guard let previous else { return true }
        if let p = previous.asciiValue, let c = character.asciiValue {
            let pLower = p >= 97 && p <= 122
            let pUpper = p >= 65 && p <= 90
            let pDigit = p >= 48 && p <= 57
            if !(pLower || pUpper || pDigit) { return true }
            return pLower && c >= 65 && c <= 90
        }
        if !(previous.isLetter || previous.isNumber) { return true }
        return previous.isLowercase && character.isUppercase
    }

    fileprivate static var wordStartBonusValue: UInt8 { UInt8(wordStartBonus) }

    // MARK: - Alignment

    private static func isSubsequence(_ needle: [UInt32], of haystack: [UInt32]) -> Bool {
        var i = 0
        let count = needle.count
        for code in haystack where code == needle[i] {
            i += 1
            if i == count { return true }
        }
        return false
    }

    private static func firstScore(_ j: Int, _ target: PreparedCandidate) -> Int {
        var score = matchScore + Int(target.bonus[j]) - min(j, maxLeadPenalty)
        if j == 0 { score += firstCharacterBonus }
        return score
    }

    /// Best placement of `needle` in the folded candidate, as folded positions. A contiguous
    /// occurrence always wins: it scores at least 30m + 20 for a term of m >= 2 characters, while
    /// a scattered alignment scores at most 32 + 24(m - 1). Otherwise a small DP picks the best
    /// scattered alignment. Within a run, each character keeps the word-start bonus the run began
    /// with (fzf-style), so a whole word beats hopping between word starts.
    private static func align(_ needle: [UInt32], in target: PreparedCandidate) -> (Int, [Int])? {
        let m = needle.count
        let n = target.codes.count
        guard m > 0, m <= n else { return nil }

        if let contiguous = bestContiguous(needle, in: target) {
            return (contiguous.score + contiguityBonus(termLength: m), Array(contiguous.start..<(contiguous.start + m)))
        }
        return bestScattered(needle, in: target)
    }

    private static func bestContiguous(_ needle: [UInt32], in target: PreparedCandidate) -> (score: Int, start: Int)? {
        let m = needle.count
        let codes = target.codes
        var best: (score: Int, start: Int)?
        var start = 0
        while start + m <= codes.count {
            defer { start += 1 }
            guard codes[start] == needle[0] else { continue }
            var matches = true
            for i in 1..<m where codes[start + i] != needle[i] {
                matches = false
                break
            }
            guard matches else { continue }

            var score = firstScore(start, target)
            var carry = target.bonus[start]
            for i in 1..<m {
                let own = target.bonus[start + i]
                score += matchScore + max(Int(own), Int(carry), minConsecutiveBonus)
                carry = max(carry, own)
            }
            if best == nil || score > best!.score { best = (score, start) }
        }
        return best
    }

    private static func bestScattered(_ needle: [UInt32], in target: PreparedCandidate) -> (Int, [Int])? {
        let m = needle.count
        let n = target.codes.count
        let codes = target.codes
        let bonus = target.bonus

        var scores = [Int](repeating: unreachable, count: m * n)
        var parents = [Int32](repeating: -1, count: m * n)
        var carries = [UInt8](repeating: 0, count: m * n)

        for j in 0..<n where codes[j] == needle[0] {
            scores[j] = firstScore(j, target)
            carries[j] = bonus[j]
        }

        for i in 1..<m {
            let row = i * n
            let previousRow = row - n
            // Running max of scores[previousRow + k] + k over k <= j - 2 (a gap of at least one).
            var bestGapValue = unreachable
            var bestGapIndex = -1
            for j in i..<n {
                let k = j - 2
                if k >= 0, scores[previousRow + k] > unreachable {
                    let value = scores[previousRow + k] + k
                    if value > bestGapValue {
                        bestGapValue = value
                        bestGapIndex = k
                    }
                }
                guard codes[j] == needle[i] else { continue }

                let own = bonus[j]
                var best = unreachable
                var parent = -1
                var carry = own
                if scores[previousRow + j - 1] > unreachable {
                    let previousCarry = carries[previousRow + j - 1]
                    best = scores[previousRow + j - 1] + max(Int(own), Int(previousCarry), minConsecutiveBonus)
                    parent = j - 1
                    carry = max(own, previousCarry)
                }
                if bestGapIndex >= 0 {
                    // gap = j - k - 1, penalty = gapOpenPenalty + gap
                    let gapped = bestGapValue - (j - 1) - gapOpenPenalty + Int(own)
                    if gapped > best {
                        best = gapped
                        parent = bestGapIndex
                        carry = own
                    }
                }
                if parent >= 0 {
                    scores[row + j] = best + matchScore
                    parents[row + j] = Int32(parent)
                    carries[row + j] = carry
                }
            }
        }

        let lastRow = (m - 1) * n
        var bestScore = unreachable
        var bestEnd = -1
        for j in (m - 1)..<n where scores[lastRow + j] > bestScore {
            bestScore = scores[lastRow + j]
            bestEnd = j
        }
        guard bestEnd >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: m)
        var j = bestEnd
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = Int(parents[i * n + j])
        }
        return (bestScore, positions)
    }
}

/// A candidate folded per Character: one entry per folded character.
fileprivate final class PreparedCandidate {
    let codes: [UInt32]
    let origin: [Int32]       // original Character offset of each folded character
    let bonus: [UInt8]        // word-start bonus at each folded position
    let characterCount: Int

    init(_ string: String) {
        var codes: [UInt32] = []
        var origin: [Int32] = []
        var bonus: [UInt8] = []
        codes.reserveCapacity(string.utf8.count)
        origin.reserveCapacity(string.utf8.count)
        bonus.reserveCapacity(string.utf8.count)
        var previous: Character?
        var offset: Int32 = 0
        for character in string {
            let startBonus = FuzzyMatcher.isWordStart(character, after: previous) ? FuzzyMatcher.wordStartBonusValue : 0
            var first = true
            FuzzyMatcher.fold(character) { code in
                codes.append(code)
                origin.append(offset)
                bonus.append(first ? startBonus : 0)
                first = false
            }
            previous = character
            offset += 1
        }
        self.codes = codes
        self.origin = origin
        self.bonus = bonus
        self.characterCount = Int(offset)
    }
}

/// Bounded, thread-safe cache of prepared candidates keyed by the candidate string. Two
/// generations: entries used since the last rotation survive it, stale ones are dropped.
fileprivate final class PreparedCandidateCache {
    static let shared = PreparedCandidateCache()

    private let lock = NSLock()
    private let generationLimit: Int
    private var current: [String: PreparedCandidate] = [:]
    private var previous: [String: PreparedCandidate] = [:]

    init(generationLimit: Int = 16_384) {
        self.generationLimit = generationLimit
    }

    func prepared(_ string: String) -> PreparedCandidate {
        lock.lock()
        if let hit = current[string] {
            lock.unlock()
            return hit
        }
        if let hit = previous[string] {
            insert(hit, for: string)
            lock.unlock()
            return hit
        }
        lock.unlock()

        let made = PreparedCandidate(string)
        lock.lock()
        insert(made, for: string)
        lock.unlock()
        return made
    }

    private func insert(_ candidate: PreparedCandidate, for string: String) {
        if current.count >= generationLimit {
            previous = current
            current = [:]
        }
        current[string] = candidate
    }
}
