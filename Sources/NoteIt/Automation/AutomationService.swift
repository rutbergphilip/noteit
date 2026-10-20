import AppKit
import Foundation
import NoteItAPI
import NoteItCore

enum NotebookRef: Equatable { case id(UUID), name(String) }
enum DeletedFilter { case exclude, include, only }
enum ListSort { case list, updated }

/// The one facade every automation surface (URL scheme, Local API, App Intents, Spotlight, Share) uses over
/// `NoteStore`. Bodies change only through `NoteStore.editBody`; locked notes never give up or take a body.
@MainActor
final class AutomationService {
    static let shared = AutomationService(store: .shared, staged: StagedUploads())

    /// Plain and Markdown text over this many UTF-8 bytes is refused.
    static let maxTextBytes = 1_000_000
    static let maxListLimit = 500

    let store: NoteStore
    let defaults: UserDefaults
    let staged: StagedUploads
    let now: () -> Date
    private let dailyNotesAvailable: () -> Bool
    private let isLoading: () -> Bool

    init(store: NoteStore, defaults: UserDefaults = .standard, staged: StagedUploads, now: @escaping () -> Date = Date.init,
         dailyNotesAvailable: @escaping () -> Bool = { DailyNotes.isAvailable }, isLoading: (() -> Bool)? = nil) {
        self.store = store
        self.defaults = defaults
        self.staged = staged
        self.now = now
        self.dailyNotesAvailable = dailyNotesAvailable
        self.isLoading = isLoading ?? { [unowned store] in store.isLoading }
        store.assignMissingRevisions()
    }

    static func link(for id: UUID) -> URL {
        NoteLink.note(id: id, heading: nil).url
    }

    func ensureReady() throws(AutomationError) {
        if isLoading() { throw .notReady }
    }

    // MARK: Notes

    func create(title: String?, body: String, format: BodyFormatDTO, notebook: NotebookRef?, tags: [String],
                pinned: Bool) throws(AutomationError) -> NoteMeta {
        try ensureReady()
        let notebookID = try resolveNotebook(notebook)
        let content = NSMutableAttributedString(attributedString: try attributedBody(from: body, format: format))
        let tagLine = Self.tagLine(tags)
        if !tagLine.isEmpty {
            if content.length > 0, !content.string.hasSuffix("\n") { content.append(plain("\n")) }
            content.append(plain(tagLine))
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = NoteStore.capturedText(title: trimmedTitle, body: content)
        let meta = store.createNote(in: notebookID, initial: text)
        if pinned { store.togglePin(meta.id) }
        return visible(try existing(meta.id))
    }

    func note(_ id: UUID) throws(AutomationError) -> NoteMeta {
        try ensureReady()
        return visible(try existing(id))
    }

    func body(_ id: UUID, format: BodyFormatDTO) throws(AutomationError) -> String {
        try ensureReady()
        let meta = try existing(id)
        if meta.isLocked { throw .noteLocked }
        return try bodyString(of: id, format: format)
    }

    func patch(_ id: UUID, title: String?, body: (String, BodyFormatDTO)?, notebookID: UUID??, pinned: Bool?,
               ifRevision: UUID?) throws(AutomationError) -> NoteMeta {
        try ensureReady()
        let meta = try existing(id)
        if meta.deletedAt != nil { throw .noteDeleted }
        try checkRevision(meta, ifRevision)
        if let notebookID, let target = notebookID, store.notebook(with: target) == nil { throw .notebookNotFound }
        if title != nil || body != nil {
            if meta.isLocked { throw .noteLocked }
            if let (text, format) = body {
                let replacement = try attributedBody(from: text, format: format, sameNote: id)
                try edit(id, actionName: "Replace Text", versioning: .recordCurrent) { storage in
                    storage.setAttributedString(replacement)
                }
            }
            if let title {
                try setTitle(id, title)
            }
        }
        if let notebookID { store.moveNote(id, to: notebookID) }
        if let pinned, try existing(id).isPinned != pinned { store.togglePin(id) }
        return visible(try existing(id))
    }

    func append(_ id: UUID, text: String, format: BodyFormatDTO, position: AppendPosition, timestamp: Bool,
                ifRevision: UUID?) throws(AutomationError) -> NoteMeta {
        try ensureReady()
        let meta = try existing(id)
        try checkRevision(meta, ifRevision)
        let stamped = timestamp ? Self.timestamp(now()) + " " + text : text
        let addition = try attributedBody(from: stamped, format: format, sameNote: id)
        try edit(id, actionName: "Append Text", versioning: .none) { storage in
            Self.insert(addition, into: storage, at: position)
        }
        return visible(try existing(id))
    }

    func open(_ id: UUID) throws(AutomationError) {
        try ensureReady()
        _ = try existing(id)
        WindowRouter.showMainWindow()
        store.reveal(id)
    }

    func moveToRecentlyDeleted(_ id: UUID) throws(AutomationError) {
        try ensureReady()
        let meta = try existing(id)
        if meta.deletedAt != nil { return }
        store.moveToRecentlyDeleted([id])
    }

    func deletePermanently(_ id: UUID) throws(AutomationError) {
        try ensureReady()
        let meta = try existing(id)
        guard meta.deletedAt != nil else {
            throw .invalidInput("Only notes in Recently Deleted can be deleted permanently.")
        }
        store.deleteNow([id])
    }

    func restore(_ id: UUID) throws(AutomationError) -> NoteMeta {
        try ensureReady()
        let meta = try existing(id)
        if meta.deletedAt != nil { store.recover([id]) }
        return visible(try existing(id))
    }

    func emptyRecentlyDeleted() {
        guard !isLoading() else { return }
        store.emptyRecentlyDeleted()
    }

    /// The most recently edited note whose stored title equals `title`, ignoring case only. Untitled notes never match.
    func findByTitle(_ title: String) -> NoteMeta? {
        guard !isLoading() else { return nil }
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return store.notes(for: .allNotes, search: "")
            .filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame }
            .max { $0.updatedAt < $1.updatedAt }
            .map(visible)
    }

    // MARK: Listing and search

    func list(notebook: NotebookRef?, tag: String?, query: String?, updatedSince: Date?, deleted: DeletedFilter,
              sort: ListSort, limit: Int, cursor: String?) throws(AutomationError) -> (notes: [NoteMeta], nextCursor: String?) {
        try ensureReady()
        guard limit > 0 else { throw .invalidInput("The limit must be at least 1.") }
        var notes = try matchingNotes(notebook: notebook, tag: tag, query: query ?? "", deleted: deleted)
        if let updatedSince { notes = notes.filter { $0.updatedAt > updatedSince } }
        notes.sort { Self.precedes($0, $1, pinnedFirst: sort == .list) }
        var start = 0
        if let cursor {
            guard let position = ListCursor(cursor) else { throw .invalidInput("That cursor isn't valid.") }
            if let index = notes.firstIndex(where: { $0.id == position.id }) {
                start = index + 1
            } else {
                start = notes.firstIndex { position.precedes($0, pinnedFirst: sort == .list) } ?? notes.count
            }
        }
        let page = Array(notes[start..<min(notes.count, start + min(limit, Self.maxListLimit))])
        let more = start + page.count < notes.count
        return (page.map(visible), more ? page.last.map { ListCursor($0).encoded } : nil)
    }

    func search(_ query: String, notebook: NotebookRef?, tag: String?,
                limit: Int) throws(AutomationError) -> [(NoteMeta, snippet: String)] {
        try ensureReady()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("Type something to search for.") }
        let notes = try matchingNotes(notebook: notebook, tag: tag, query: trimmed, deleted: .exclude)
            .sorted { Self.precedes($0, $1, pinnedFirst: true) }
        return notes.prefix(max(1, min(limit, Self.maxListLimit))).map { meta in
            (visible(meta), meta.isLocked ? "" : Self.snippet(store.plainText(for: meta.id), query: trimmed))
        }
    }

    // MARK: Notebooks and tags

    func notebooks() -> [(Notebook, noteCount: Int)] {
        let active = store.activeNotes
        var counts: [UUID: Int] = [:]
        for note in active { if let id = note.notebookID { counts[id, default: 0] += 1 } }
        return store.sortedNotebooks.map { ($0, counts[$0.id] ?? 0) }
    }

    func createNotebook(name: String, symbol: String?, color: String?) throws(AutomationError) -> Notebook {
        try ensureReady()
        let trimmed = try Self.notebookName(name)
        let colorHex = try color.map(Self.colorHex) ?? Tokens.Hex.notebookBlue
        return store.createNotebook(name: trimmed, symbol: try Self.symbol(symbol) ?? "folder", colorHex: colorHex)
    }

    func updateNotebook(_ id: UUID, name: String?, symbol: String?, color: String?) throws(AutomationError) -> Notebook {
        try ensureReady()
        guard var notebook = store.notebook(with: id) else { throw .notebookNotFound }
        if let name { notebook.name = try Self.notebookName(name) }
        if let symbol = try Self.symbol(symbol) { notebook.symbol = symbol }
        if let color { notebook.colorHex = try Self.colorHex(color) }
        store.updateNotebook(notebook)
        guard let updated = store.notebook(with: id) else { throw .notebookNotFound }
        return updated
    }

    func deleteNotebook(_ id: UUID) throws(AutomationError) {
        try ensureReady()
        guard store.notebook(with: id) != nil else { throw .notebookNotFound }
        store.deleteNotebook(id)
    }

    func tags() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in store.activeNotes {
            for tag in Set(note.tags) { counts[tag, default: 0] += 1 }
        }
        return counts.keys.sorted().map { ($0, counts[$0] ?? 0) }
    }

    // MARK: Daily notes

    func daily(date: Date, create: Bool) throws(AutomationError) -> NoteMeta? {
        try ensureReady()
        throw .dailyNotesUnavailable
    }

    func appendToDaily(text: String, format: DailyFormat, timestamp: Bool, date: Date) throws(AutomationError) -> NoteMeta {
        try ensureReady()
        throw .dailyNotesUnavailable
    }

    // MARK: Helpers

    func existing(_ id: UUID) throws(AutomationError) -> NoteMeta {
        guard let meta = store.note(with: id) else { throw .notFound }
        return meta
    }

    /// Locked notes keep their title and metadata but never show text.
    func visible(_ meta: NoteMeta) -> NoteMeta {
        guard meta.isLocked else { return meta }
        var redacted = meta
        redacted.preview = ""
        return redacted
    }

    func resolveNotebook(_ ref: NotebookRef?) throws(AutomationError) -> UUID? {
        switch ref {
        case .none:
            return defaultNotebookID
        case .id(let id):
            guard store.notebook(with: id) != nil else { throw .notebookNotFound }
            return id
        case .name(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = store.sortedNotebooks.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                throw .notebookNotFound
            }
            return match.id
        }
    }

    /// `NoteStore.defaultNotebookIDForNewNotes`, read from this service's defaults.
    private var defaultNotebookID: UUID? {
        let stored = defaults.string(forKey: PrefKey.defaultNotebookID)
        if stored == PrefDefault.noNotebook { return nil }
        if let stored, let id = UUID(uuidString: stored), store.notebook(with: id) != nil { return id }
        let ordered = store.sortedNotebooks
        return (ordered.first { $0.name.caseInsensitiveCompare("Inbox") == .orderedSame } ?? ordered.first)?.id
    }

    private func checkRevision(_ meta: NoteMeta, _ ifRevision: UUID?) throws(AutomationError) {
        if let ifRevision, ifRevision != meta.revision { throw .revisionMismatch(current: meta.revision) }
    }

    private func matchingNotes(notebook: NotebookRef?, tag: String?, query: String,
                               deleted: DeletedFilter) throws(AutomationError) -> [NoteMeta] {
        let notebookID: UUID? = try notebook.map { ref throws(AutomationError) in try resolveNotebook(ref) ?? UUID() }
        let tagPath = tag.map(Self.normalizedTag).flatMap { $0.isEmpty ? nil : $0 }
        var selections: [SidebarSelection] = []
        if deleted != .only {
            if let notebookID { selections.append(.notebook(notebookID)) }
            else if let tagPath { selections.append(.tag(tagPath)) }
            else { selections.append(.allNotes) }
        }
        if deleted != .exclude { selections.append(.recentlyDeleted) }
        var result: [NoteMeta] = []
        for selection in selections {
            result += searched(store.notes(for: selection, search: ""), in: selection, query: query)
        }
        return result.filter { meta in
            if let notebookID, meta.notebookID != notebookID { return false }
            if let tagPath, !meta.tags.contains(where: { $0 == tagPath || $0.hasPrefix(tagPath + "/") }) { return false }
            return true
        }
    }

    /// The store's search for readable notes; locked notes match on their title only.
    private func searched(_ notes: [NoteMeta], in selection: SidebarSelection, query: String) -> [NoteMeta] {
        let terms = NoteStore.fold(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return notes }
        let hits = Set(store.notes(for: selection, search: query).filter { !$0.isLocked }.map(\.id))
        return notes.filter { meta in
            guard meta.isLocked else { return hits.contains(meta.id) }
            let title = NoteStore.fold(meta.title)
            return terms.allSatisfy { title.contains($0) }
        }
    }

    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: NoteStore.capturedText(title: "", body: "x").attributes(at: 0, effectiveRange: nil))
    }

    static func tagLine(_ tags: [String]) -> String {
        var seen = Set<String>()
        return tags.map(normalizedTag).filter { !$0.isEmpty && seen.insert($0).inserted }.map { "#" + $0 }.joined(separator: " ")
    }

    static func normalizedTag(_ tag: String) -> String {
        var trimmed = Substring(tag.trimmingCharacters(in: .whitespacesAndNewlines))
        while trimmed.first == "#" { trimmed = trimmed.dropFirst() }
        return trimmed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func notebookName(_ name: String) throws(AutomationError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("A notebook needs a name.") }
        guard trimmed.count <= 200 else { throw .invalidInput("That notebook name is too long.") }
        return trimmed
    }

    private static func symbol(_ symbol: String?) throws(AutomationError) -> String? {
        guard let symbol else { return nil }
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else {
            throw .invalidInput("That symbol isn't valid.")
        }
        return trimmed
    }

    private static func colorHex(_ color: String) throws(AutomationError) -> String {
        let trimmed = color.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : Substring(trimmed)
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else {
            throw .invalidInput("Colors look like #0A84FF.")
        }
        return "#" + digits.uppercased()
    }

    /// Pinned first for `.list`, then most recently updated, then by id, so pages never overlap.
    static func precedes(_ a: NoteMeta, _ b: NoteMeta, pinnedFirst: Bool) -> Bool {
        if pinnedFirst, a.isPinned != b.isPinned { return a.isPinned }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// The text around the first query term: 60 characters before and 100 after, cut on word boundaries.
    static func snippet(_ text: String, query: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let terms = NoteStore.fold(query).split(whereSeparator: \.isWhitespace)
        let match = terms.lazy.compactMap { flat.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) }.first
        guard let match else { return cut(flat, from: flat.startIndex) }
        let start = flat.index(match.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        return cut(flat, from: start, keep: match.lowerBound)
    }

    private static func cut(_ text: String, from start: String.Index, keep: String.Index? = nil) -> String {
        var lower = start
        if lower > text.startIndex, !text[text.index(before: lower)].isWhitespace {
            let limit = keep ?? text.endIndex
            if let space = text[lower..<limit].firstIndex(where: \.isWhitespace) { lower = text.index(after: space) }
        }
        let anchor = keep ?? lower
        var upper = text.index(anchor, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        if upper < text.endIndex, !text[upper].isWhitespace,
           let space = text[anchor..<upper].lastIndex(where: \.isWhitespace) {
            upper = space
        }
        var result = String(text[lower..<upper]).trimmingCharacters(in: .whitespaces)
        if lower > text.startIndex { result = "…" + result }
        if upper < text.endIndex { result += "…" }
        return result
    }
}

/// `base64url("<updatedAt ms>|<UUID>")` of the last note on a page.
struct ListCursor: Equatable {
    var updatedAtMilliseconds: Int64
    var id: UUID

    init(_ meta: NoteMeta) {
        updatedAtMilliseconds = Int64((meta.updatedAt.timeIntervalSince1970 * 1000).rounded(.down))
        id = meta.id
    }

    init?(_ encoded: String) {
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let ms = Int64(parts[0]), let id = UUID(uuidString: String(parts[1])) else { return nil }
        updatedAtMilliseconds = ms
        self.id = id
    }

    var encoded: String {
        Data("\(updatedAtMilliseconds)|\(id.uuidString)".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// True when `meta` sorts after this position; used when the cursor's note left the list.
    func precedes(_ meta: NoteMeta, pinnedFirst: Bool) -> Bool {
        let ms = Int64((meta.updatedAt.timeIntervalSince1970 * 1000).rounded(.down))
        if pinnedFirst, meta.isPinned { return false }
        if ms != updatedAtMilliseconds { return ms < updatedAtMilliseconds }
        return meta.id.uuidString > id.uuidString
    }
}
