import AppKit
import Foundation
import NoteItCore

struct SearchResult: Identifiable, Equatable {
    var id: UUID { note.id }
    var note: NoteMeta
    var score: Double?
    var titleHighlights: [NSRange]
    var snippet: Snippet?
    /// Matched only in image text.
    var foundInImage: Bool
}

enum SearchSortOrder: String, CaseIterable {
    case bestMatch, dateEdited
}

/// One note as the query evaluator and ranker see it.
struct StoreSearchDocument: SearchDocument {
    var meta: NoteMeta
    var foldedText: [UInt8]
    var foldedImageText: [UInt8] = []
    var foldedTitle: String
    var openTaskCount: Int
    var doneTaskCount: Int
    var openDueDates: [LocalDateTime]
    var hasLiveReminder: Bool
    var hasAttachment: Bool

    var tags: [String] { meta.tags }
    var notebookID: UUID? { meta.notebookID }
    var isPinned: Bool { meta.isPinned }
    var isConflict: Bool { meta.conflictSource != nil }
    var createdAt: Date { meta.createdAt }
    var updatedAt: Date { meta.updatedAt }

    /// A note without an entry yet is searched by title and preview, as before the index existed; a locked note by
    /// its title only.
    init(meta: NoteMeta, entry: SearchIndexEntry?) {
        self.meta = meta
        foldedTitle = TextFold.fold(meta.displayTitle)
        if meta.isLocked {
            foldedText = []
        } else if let entry {
            foldedText = Array(entry.text.utf8)
        } else {
            foldedText = Array(TextFold.fold(meta.title + "\n" + meta.preview).utf8)
        }
        let tasks = meta.isLocked ? [] : entry?.tasks ?? []
        openTaskCount = tasks.lazy.filter { !$0.checked }.count
        doneTaskCount = tasks.count - openTaskCount
        openDueDates = tasks.compactMap { $0.checked ? nil : $0.due }
        hasLiveReminder = !meta.isLocked && (entry?.reminders ?? []).contains { !$0.done && !($0.isTask && $0.checked) }
        hasAttachment = !meta.isLocked && entry?.hasAttachment == true
    }
}

struct SearchDocumentCache {
    var notesVersion: Int
    var indexVersion: Int
    var documents: [UUID: StoreSearchDocument]
}

struct SearchResultKey: Hashable {
    var selection: SidebarSelection?
    var search: String
    var order: SearchSortOrder
    var decorated: Bool
    var notesVersion: Int
    var notebooksVersion: Int
    var indexVersion: Int
    var minute: Int
}

extension NoteStore {
    /// Results beyond this many get no snippet (their row shows the preview).
    static let snippetLimit = 150
    static let snippetLength = 140

    /// Called once at launch by the feature that recognises text in images.
    func registerImageTextProvider(_ provider: ImageTextProviding) {
        imageTextProvider = provider
        searchResultCache.removeAll()
    }

    func searchResults(for selection: SidebarSelection?, search: String, order: SearchSortOrder) -> [SearchResult] {
        searchResults(for: selection, search: search, order: order, decorated: true)
    }

    /// `decorated` false skips highlights and snippets (callers that only need the notes).
    func searchResults(for selection: SidebarSelection?, search: String, order: SearchSortOrder,
                       decorated: Bool, now: Date = Date()) -> [SearchResult] {
        let base = LibraryQuery.notes(notes, for: selection, search: "", now: now, indexedText: { _ in nil },
                                      notebookScope: notebookIDsIncludingDescendants)
        let query = SearchQuery.parse(search)
        if query.isEmpty {
            return base.map { SearchResult(note: $0, score: nil, titleHighlights: [], snippet: nil, foundInImage: false) }
        }
        let bypass = imageTextProvider != nil && query.hasTextTerms
        let key = SearchResultKey(selection: selection, search: search, order: order, decorated: decorated,
                                  notesVersion: notesVersion, notebooksVersion: notebooksVersion,
                                  indexVersion: searchIndexer.version, minute: Int(now.timeIntervalSince1970 / 60))
        if !bypass, let cached = searchResultCache[key] { return cached }

        let documents = searchDocuments()
        var docs: [StoreSearchDocument] = []
        docs.reserveCapacity(base.count)
        for meta in base {
            var doc = documents[meta.id] ?? StoreSearchDocument(meta: meta, entry: nil)
            doc.meta = meta
            if let provider = imageTextProvider, !meta.isLocked, let text = provider.imageText(for: meta.id) {
                doc.foldedImageText = Array(TextFold.fold(text).utf8)
            }
            docs.append(doc)
        }
        let context = QueryContext(now: now, calendar: .current, notebooks: notebookTree)
        let matched = docs.filter { QueryEvaluator.matches(query, $0, context: context) }

        var ordered: [(doc: StoreSearchDocument, score: Double?, onlyInImage: Bool)]
        if query.hasTextTerms, order == .bestMatch, selection != .recentlyDeleted {
            let hits = SearchRanker.rank(matched, query: query, foldedQueryText: TextFold.fold(search), now: now)
            ordered = hits.map { (matched[$0.index], $0.score, $0.onlyInImage) }
        } else {
            let terms = query.textTerms
            ordered = matched.map { ($0, nil, Self.matchesOnlyInImage($0, terms: terms)) }
        }

        var results: [SearchResult] = []
        results.reserveCapacity(ordered.count)
        for (position, item) in ordered.enumerated() {
            var result = SearchResult(note: item.doc.meta, score: item.score, titleHighlights: [], snippet: nil,
                                      foundInImage: imageTextProvider != nil && item.onlyInImage)
            if decorated, !query.highlightTerms.isEmpty {
                result.titleHighlights = SearchHighlighter.ranges(of: query.highlightTerms, in: item.doc.meta.displayTitle)
                if position < Self.snippetLimit, !result.foundInImage, !item.doc.meta.isLocked,
                   let plain = searchIndexer.entries[item.doc.meta.id]?.plain {
                    result.snippet = SearchHighlighter.snippet(of: Self.bodyAfterTitle(plain), terms: query.highlightTerms,
                                                               maxLength: Self.snippetLength)
                }
            }
            results.append(result)
        }
        if !bypass {
            if searchResultCache.count > 16 { searchResultCache.removeAll() }
            searchResultCache[key] = results
        }
        return results
    }

    /// Documents for every note, rebuilt when notes or the index change.
    private func searchDocuments() -> [UUID: StoreSearchDocument] {
        if let cache = searchDocumentCache, cache.notesVersion == notesVersion, cache.indexVersion == searchIndexer.version {
            return cache.documents
        }
        var documents: [UUID: StoreSearchDocument] = [:]
        documents.reserveCapacity(notes.count)
        for meta in notes {
            documents[meta.id] = StoreSearchDocument(meta: meta, entry: searchIndexer.entries[meta.id])
        }
        searchDocumentCache = SearchDocumentCache(notesVersion: notesVersion, indexVersion: searchIndexer.version,
                                                  documents: documents)
        return documents
    }

    private static func matchesOnlyInImage(_ doc: StoreSearchDocument, terms: [String]) -> Bool {
        guard !doc.foldedImageText.isEmpty, !terms.isEmpty else { return false }
        var inImage = false
        for term in terms {
            let needle = Array(term.utf8)
            if doc.foldedTitle.contains(term) || doc.tags.contains(term) || contains(doc.foldedText, needle) { return false }
            if contains(doc.foldedImageText, needle) { inImage = true }
        }
        return inImage
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil }
        }
    }

    /// The text below the title line, which is what a row's preview shows.
    static func bodyAfterTitle(_ plain: String) -> String {
        let trimmed = plain.drop { $0.isWhitespace }
        guard let newline = trimmed.firstIndex(where: \.isNewline) else { return "" }
        return String(trimmed[trimmed.index(after: newline)...])
    }
}
