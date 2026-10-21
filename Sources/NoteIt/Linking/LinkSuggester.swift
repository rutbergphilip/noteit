import Foundation
import NoteItCore

struct LinkCandidate: Sendable {
    var id: UUID
    var title: String
    var notebookName: String
    var updatedAt: Date
}

enum LinkSuggestion: Equatable {
    case note(id: UUID, title: String, notebookName: String, matched: [Range<String.Index>])
    case heading(noteID: UUID, text: String, level: Int)
    case create(title: String)
}

/// Ranks the `[[` list (spec §4). Callers pass candidates without templates and empty titles, and without the
/// current note unless the query has a heading.
enum LinkSuggester {
    /// A non-nil `heading` (empty after a bare `#`) lists the target's headings.
    static func suggestions(for query: LinkQuery, candidates: [LinkCandidate],
                            headings: (UUID) -> [OutlineItem], limit: Int = 8) -> [LinkSuggestion] {
        let title = query.title.trimmingCharacters(in: .whitespaces)
        guard limit > 0 else { return [] }
        if let heading = query.heading {
            guard !title.isEmpty else { return [] }
            let ranked = rankedNotes(title, in: candidates)
            let exact = ranked.first { $0.isExact }
            guard let target = exact?.candidate ?? ranked.first?.candidate else {
                return [.create(title: title)]
            }
            let fuzzy = FuzzyQuery(heading)
            let items = headings(target.id).filter { $0.level > 0 }
            let matches = items.enumerated().compactMap { offset, item -> (OutlineItem, Int, Int)? in
                guard let result = FuzzyMatcher.evaluate(fuzzy, in: item.text) else { return nil }
                return (item, result.isExact ? Int.max : result.match.score, offset)
            }
            let sorted = fuzzy.isEmpty ? matches : matches.sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            return sorted.prefix(limit).map { .heading(noteID: target.id, text: $0.0.text, level: $0.0.level) }
        }

        if title.isEmpty {
            return candidates.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).map {
                .note(id: $0.id, title: $0.title, notebookName: $0.notebookName, matched: [])
            }
        }

        let ranked = rankedNotes(title, in: candidates)
        let hasExact = ranked.contains { $0.isExact }
        let noteLimit = hasExact ? limit : limit - 1
        var result: [LinkSuggestion] = ranked.prefix(noteLimit).map {
            .note(id: $0.candidate.id, title: $0.candidate.title, notebookName: $0.candidate.notebookName,
                  matched: ranges(of: $0.indices, in: $0.candidate.title))
        }
        if !hasExact { result.append(.create(title: title)) }
        return result
    }

    private struct Ranked {
        var candidate: LinkCandidate
        var score: Int
        var isExact: Bool
        var indices: [Int]
    }

    private static func rankedNotes(_ title: String, in candidates: [LinkCandidate]) -> [Ranked] {
        let fuzzy = FuzzyQuery(title)
        let folded = TextFold.fold(title)
        let ranked = candidates.compactMap { candidate -> Ranked? in
            guard let result = FuzzyMatcher.evaluate(fuzzy, in: candidate.title) else { return nil }
            let exact = result.isExact || TextFold.fold(candidate.title.trimmingCharacters(in: .whitespaces)) == folded
            return Ranked(candidate: candidate, score: result.match.score, isExact: exact, indices: result.match.matchedIndices)
        }
        return ranked.sorted { a, b in
            if a.isExact != b.isExact { return a.isExact }
            if a.score != b.score { return a.score > b.score }
            return a.candidate.updatedAt > b.candidate.updatedAt
        }
    }

    /// Character offsets to ranges, merging neighbours.
    static func ranges(of indices: [Int], in text: String) -> [Range<String.Index>] {
        guard !indices.isEmpty else { return [] }
        let wanted = Set(indices)
        var result: [Range<String.Index>] = []
        var start: String.Index?
        var offset = 0
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if wanted.contains(offset) {
                if start == nil { start = index }
            } else if let s = start {
                result.append(s..<index)
                start = nil
            }
            index = next
            offset += 1
        }
        if let s = start { result.append(s..<text.endIndex) }
        return result
    }
}
