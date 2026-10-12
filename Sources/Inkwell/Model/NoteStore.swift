import AppKit
import Combine
import Foundation

@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published var notebooks: [Notebook] = []
    @Published var notes: [NoteMeta] = []
    @Published var selection: SidebarSelection? = .allNotes {
        didSet { if selection != oldValue { editingNoteID = nil } }
    }
    @Published var selectedNoteID: UUID? {
        didSet { if selectedNoteID != editingNoteID { editingNoteID = nil } }
    }
    @Published var searchText: String = "" {
        didSet { if searchText != oldValue { editingNoteID = nil } }
    }

    /// Window during which notes count as "Recent".
    static let recentInterval: TimeInterval = 7 * 24 * 60 * 60
    static let previewLength = 140
    static let titleLength = 120
    /// Max clean (non-dirty, non-selected) bodies kept in memory.
    static let bodyCacheLimit = 20

    let rootURL: URL
    var notesURL: URL { rootURL.appendingPathComponent("notes", isDirectory: true) }
    var libraryURL: URL { rootURL.appendingPathComponent("library.json") }
    var searchIndexURL: URL { rootURL.appendingPathComponent("search-index.json") }
    var trashURL: URL { rootURL.appendingPathComponent(".trash", isDirectory: true) }
    var tombstonesURL: URL { rootURL.appendingPathComponent("tombstones.json") }
    var recoveryURL: URL { rootURL.appendingPathComponent("recovery", isDirectory: true) }
    private var firstLaunchMarkerURL: URL { rootURL.appendingPathComponent(".initialized") }

    private var bodyCache: [UUID: NSAttributedString] = [:]
    private var bodyAccessOrder: [UUID] = []
    private var dirtyBodies: Set<UUID> = []
    private var libraryDirty = false
    private var saveWorkItem: DispatchWorkItem?
    private var isLoading = false

    /// Folded (case/diacritic/width-insensitive) plain text per note, persisted to `search-index.json`.
    private var searchIndex: [UUID: String] = [:]
    private var searchIndexDirty = false
    private var indexRebuildInFlight = false

    /// Read failures for note bodies, keyed by note ID (message suitable for UI).
    private var loadErrors: [UUID: String] = [:]
    /// File to reveal for a load error: the backup, or the original when it couldn't be backed up.
    private var loadErrorFiles: [UUID: URL] = [:]
    /// Metadata as last written to library.json; used for notes whose newer body failed to save,
    /// so the library never describes a body that isn't on disk.
    private var persistedMeta: [UUID: NoteMeta] = [:]
    /// Bodies whose last write attempt failed.
    private var failedBodies: Set<UUID> = []
    /// Set once the app is terminating: failed bodies are then written to `recovery/` as a last resort.
    private var isTerminating = false
    /// Snapshots already written to `recovery/` (avoids duplicate copies across terminate-time flushes).
    private var recoveredSnapshots: [UUID: ObjectIdentifier] = [:]
    /// Bodies whose unreadable original could not be backed up: never overwrite them.
    private var bodyWriteBlocked: Set<UUID> = []
    /// Set when library.json was unreadable and could not be backed up: never overwrite it.
    private var libraryWriteBlocked = false
    /// Deleted notes whose bodies are moved to `.trash` once the library deletion is persisted.
    /// Mirrored to `tombstones.json`; an ID leaves it only once its body is gone AND a saved
    /// library.json is known not to list it, so an interrupted deletion is finished (not resurrected).
    private var pendingTrash: Set<UUID> = []
    /// Note IDs in library.json as last read or written; nil when unknown (missing/unreadable/unsaved).
    private var libraryNoteIDsOnDisk: Set<UUID>?
    /// Note the user is currently typing in; selection reconciliation won't yank it.
    private var editingNoteID: UUID?

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else if let override = ProcessInfo.processInfo.environment["INKWELL_DATA_DIR"], !override.isEmpty {
            self.rootURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.rootURL = base.appendingPathComponent("Inkwell", isDirectory: true)
        }
        load()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTerminating = true
                self.flush()
            }
        }
    }

    // MARK: - Queries

    var sortedNotebooks: [Notebook] {
        notebooks.sorted { $0.sortIndex < $1.sortIndex }
    }

    func notebook(with id: UUID?) -> Notebook? {
        guard let id else { return nil }
        return notebooks.first { $0.id == id }
    }

    func note(with id: UUID?) -> NoteMeta? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    /// Pinned first, then most recently updated.
    func notes(for selection: SidebarSelection?, search: String) -> [NoteMeta] {
        let filtered: [NoteMeta]
        switch selection ?? .allNotes {
        case .allNotes:
            filtered = notes
        case .pinned:
            filtered = notes.filter(\.isPinned)
        case .recent:
            let cutoff = Date().addingTimeInterval(-Self.recentInterval)
            filtered = notes.filter { $0.updatedAt >= cutoff }
        case .notebook(let id):
            filtered = notes.filter { $0.notebookID == id }
        case .tag(let tag):
            filtered = notes.filter { $0.tags.contains(tag) }
        }

        let terms = Self.fold(search).split(whereSeparator: \.isWhitespace)
        let searched: [NoteMeta]
        if terms.isEmpty {
            searched = filtered
        } else {
            searched = filtered.filter { note in
                let haystack = searchIndex[note.id] ?? Self.fold(note.title + "\n" + note.preview)
                return terms.allSatisfy { haystack.contains($0) }
            }
        }

        return searched.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    func count(for selection: SidebarSelection) -> Int {
        notes(for: selection, search: "").count
    }

    /// Unique tags (lowercased, without `#`) across all notes, sorted.
    var allTags: [String] {
        Array(Set(notes.flatMap(\.tags))).sorted()
    }

    // MARK: - Selection

    /// Ensures `selectedNoteID` refers to a note in the visible list (current sidebar selection + search).
    /// Keeps the note the user is actively typing in, even if their edit hid it (e.g. removed its tag).
    func reconcileSelection() {
        let visible = notes(for: selection, search: searchText)
        if let id = selectedNoteID {
            if visible.contains(where: { $0.id == id }) { return }
            if id == editingNoteID, note(with: id) != nil { return }
        }
        let next = visible.first?.id
        if selectedNoteID != next { selectedNoteID = next }
    }

    // MARK: - Bodies

    func body(for id: UUID) -> NSAttributedString {
        if let cached = bodyCache[id] {
            touchBody(id)
            return cached
        }
        let url = bodyURL(for: id)
        let loaded: NSAttributedString
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                loaded = try Self.readBody(at: url)
            } catch {
                loaded = NSAttributedString()
                handleUnreadableBody(id, at: url, error: error)
            }
        } else {
            loaded = NSAttributedString()
        }
        bodyCache[id] = loaded
        touchBody(id)
        if loadErrors[id] == nil, searchIndex[id] == nil {
            setIndexEntry(id, text: loaded.string)
        }
        trimBodyCache()
        return loaded
    }

    func plainText(for id: UUID) -> String {
        body(for: id).string
    }

    /// Non-nil when the note's body file exists but could not be read. The original was backed up
    /// (unless the message says otherwise) and the note opens empty.
    func loadError(for id: UUID) -> String? {
        loadErrors[id]
    }

    /// The backup of an unreadable body (or the original, if it couldn't be backed up).
    func loadErrorFile(for id: UUID) -> URL? {
        loadErrorFiles[id]
    }

    /// True when edits to the note can't be saved (its unreadable original couldn't be backed up).
    func isBodyWriteBlocked(_ id: UUID) -> Bool {
        bodyWriteBlocked.contains(id)
    }

    func updateBody(_ id: UUID, _ text: NSAttributedString) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if body(for: id).isEqual(to: text) { return }

        let snapshot = text.copy() as? NSAttributedString ?? NSAttributedString(attributedString: text)
        bodyCache[id] = snapshot
        touchBody(id)
        dirtyBodies.insert(id)
        editingNoteID = id

        var meta = notes[index]
        Self.applyDerivedFields(to: &meta, from: snapshot)
        meta.updatedAt = Date()
        notes[index] = meta
        setIndexEntry(id, text: snapshot.string)
        libraryDirty = true
        scheduleSave()
    }

    private func touchBody(_ id: UUID) {
        if let i = bodyAccessOrder.lastIndex(of: id) { bodyAccessOrder.remove(at: i) }
        bodyAccessOrder.append(id)
    }

    /// LRU eviction of clean bodies; dirty bodies and the selected note are always kept.
    private func trimBodyCache() {
        var evictable = bodyAccessOrder.filter { !dirtyBodies.contains($0) && $0 != selectedNoteID }
        var excess = evictable.count - Self.bodyCacheLimit
        while excess > 0, !evictable.isEmpty {
            let victim = evictable.removeFirst()
            bodyCache[victim] = nil
            bodyAccessOrder.removeAll { $0 == victim }
            excess -= 1
        }
    }

    private func handleUnreadableBody(_ id: UUID, at url: URL, error: Error) {
        guard loadErrors[id] == nil else { return }
        let backup = Self.uniqueURL(notesURL.appendingPathComponent("\(id.uuidString).rtfd.corrupt-\(Self.timestamp())"))
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            loadErrorFiles[id] = backup
            loadErrors[id] = "This note couldn’t be read (\(error.localizedDescription)). The original was backed up to \(backup.lastPathComponent)."
            NSLog("Inkwell: failed to read note \(id) (\(error)); backed up to \(backup.path)")
        } catch let copyError {
            bodyWriteBlocked.insert(id)
            loadErrorFiles[id] = url
            loadErrors[id] = "This note couldn’t be read (\(error.localizedDescription)) or backed up; edits to it won’t be saved."
            NSLog("Inkwell: failed to read note \(id) (\(error)) and to back it up (\(copyError)); writes disabled")
        }
        // body(for:) can run during a view update; publish the error on the next turn.
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: - Search index

    nonisolated static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    private func setIndexEntry(_ id: UUID, text: String) {
        searchIndex[id] = Self.fold(text)
        searchIndexDirty = true
    }

    /// Indexes notes lacking a (fresh) entry by parsing their RTFD off the main actor.
    private func scheduleIndexRebuild() {
        guard !indexRebuildInFlight else { return }
        let missing = notes.filter { searchIndex[$0.id] == nil && loadErrors[$0.id] == nil }
            .map { ($0.id, bodyURL(for: $0.id)) }
        guard !missing.isEmpty else { return }
        indexRebuildInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            var results: [UUID: String] = [:]
            for (id, url) in missing {
                guard FileManager.default.fileExists(atPath: url.path),
                      let text = try? NoteStore.readBody(at: url) else { continue }
                results[id] = NoteStore.fold(text.string)
            }
            let found = results
            await self?.mergeIndex(found)
        }
    }

    private func mergeIndex(_ results: [UUID: String]) {
        indexRebuildInFlight = false
        var changed = false
        for (id, text) in results where searchIndex[id] == nil {
            guard note(with: id) != nil else { continue }
            searchIndex[id] = text
            changed = true
        }
        guard changed else { return }
        searchIndexDirty = true
        objectWillChange.send()
        scheduleSave()
    }

    private struct SearchIndexFile: Codable {
        struct Entry: Codable {
            var text: String
            var updatedAt: Date
        }
        var version: Int
        var entries: [String: Entry]
    }

    private func loadSearchIndex() {
        guard let data = try? Data(contentsOf: searchIndexURL),
              let file = try? Self.decoder.decode(SearchIndexFile.self, from: data) else { return }
        for meta in notes where searchIndex[meta.id] == nil {
            guard let entry = file.entries[meta.id.uuidString],
                  abs(entry.updatedAt.timeIntervalSince(meta.updatedAt)) < 1 else { continue }
            searchIndex[meta.id] = entry.text
        }
    }

    private func saveSearchIndex() {
        var entries: [String: SearchIndexFile.Entry] = [:]
        // Entries are stamped with the note's updatedAt; unsaved bodies are left out so a crash or a
        // failed write can't leave the index ahead of (or behind) what's on disk.
        for meta in notes where !dirtyBodies.contains(meta.id) {
            guard let text = searchIndex[meta.id] else { continue }
            entries[meta.id.uuidString] = .init(text: text, updatedAt: meta.updatedAt)
        }
        do {
            let data = try Self.encoder.encode(SearchIndexFile(version: 1, entries: entries))
            try data.write(to: searchIndexURL, options: .atomic)
            searchIndexDirty = false
        } catch {
            NSLog("Inkwell: failed to save search index: \(error)")
        }
    }

    // MARK: - Notes

    @discardableResult
    func createNote(in notebookID: UUID?, initial: NSAttributedString? = nil) -> NoteMeta {
        let now = Date()
        let body = initial ?? NSAttributedString()
        var meta = NoteMeta(
            id: UUID(),
            notebookID: notebookID,
            title: "",
            preview: "",
            isPinned: false,
            createdAt: now,
            updatedAt: now,
            tags: []
        )
        Self.applyDerivedFields(to: &meta, from: body)
        bodyCache[meta.id] = body
        touchBody(meta.id)
        dirtyBodies.insert(meta.id)
        notes.append(meta)
        setIndexEntry(meta.id, text: body.string)
        libraryDirty = true
        scheduleSave()
        return meta
    }

    /// Creates a note in the notebook implied by the current sidebar selection and selects it.
    @discardableResult
    func createNoteInCurrentContext(initial: NSAttributedString? = nil) -> NoteMeta {
        var notebookID: UUID?
        switch selection {
        case .notebook(let id):
            notebookID = id
        case .pinned, .tag, .none:
            selection = .allNotes
        case .allNotes, .recent:
            break
        }
        searchText = ""
        let meta = createNote(in: notebookID, initial: initial)
        selectedNoteID = meta.id
        return meta
    }

    /// Persists the metadata removal first, then moves the body into `.trash` (never deleted outright).
    func deleteNote(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if selectedNoteID == id {
            let visible = notes(for: selection, search: searchText)
            if let pos = visible.firstIndex(where: { $0.id == id }) {
                let next = visible.indices.contains(pos + 1) ? visible[pos + 1] : (pos > 0 ? visible[pos - 1] : nil)
                selectedNoteID = next?.id
            } else {
                selectedNoteID = nil
            }
        }
        notes.remove(at: index)
        bodyCache[id] = nil
        bodyAccessOrder.removeAll { $0 == id }
        dirtyBodies.remove(id)
        searchIndex[id] = nil
        searchIndexDirty = true
        loadErrors[id] = nil
        loadErrorFiles[id] = nil
        failedBodies.remove(id)
        pendingTrash.insert(id)
        saveTombstones()
        libraryDirty = true
        flush()
        reconcileSelection()
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        libraryDirty = true
        scheduleSave()
        reconcileSelectionAfterUserAction()
    }

    func moveNote(_ id: UUID, to notebookID: UUID?) {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].notebookID != notebookID else { return }
        notes[index].notebookID = notebookID
        libraryDirty = true
        scheduleSave()
        reconcileSelectionAfterUserAction()
    }

    private func reconcileSelectionAfterUserAction() {
        guard !isLoading else { return }
        editingNoteID = nil
        reconcileSelection()
    }

    // MARK: - Notebooks

    @discardableResult
    func createNotebook(name: String, symbol: String, colorHex: String) -> Notebook {
        let nextIndex = (notebooks.map(\.sortIndex).max() ?? -1) + 1
        let notebook = Notebook(id: UUID(), name: name, symbol: symbol, colorHex: colorHex, sortIndex: nextIndex)
        notebooks.append(notebook)
        libraryDirty = true
        scheduleSave()
        return notebook
    }

    func updateNotebook(_ nb: Notebook) {
        guard let index = notebooks.firstIndex(where: { $0.id == nb.id }) else { return }
        notebooks[index] = nb
        libraryDirty = true
        scheduleSave()
    }

    /// Deletes the notebook; its notes are kept and move to "no notebook".
    func deleteNotebook(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        for index in notes.indices where notes[index].notebookID == id {
            notes[index].notebookID = nil
        }
        if selection == .notebook(id) { selection = .allNotes }
        reindexNotebooks(sortedNotebooks)
        libraryDirty = true
        scheduleSave()
        reconcileSelectionAfterUserAction()
    }

    /// Offsets refer to `sortedNotebooks` order.
    func moveNotebooks(from source: IndexSet, to destination: Int) {
        var ordered = sortedNotebooks
        ordered.move(fromOffsets: source, toOffset: destination)
        reindexNotebooks(ordered)
        libraryDirty = true
        scheduleSave()
    }

    private func reindexNotebooks(_ ordered: [Notebook]) {
        notebooks = ordered.enumerated().map { offset, nb in
            var copy = nb
            copy.sortIndex = offset
            return copy
        }
    }

    // MARK: - Derived fields

    static func applyDerivedFields(to meta: inout NoteMeta, from string: String) {
        applyTitleAndPreview(to: &meta, from: string)
        meta.tags = parseTags(string)
    }

    /// Like the string variant, but ignores hashtags inside code (monospaced) and links.
    static func applyDerivedFields(to meta: inout NoteMeta, from text: NSAttributedString) {
        applyTitleAndPreview(to: &meta, lines: previewLines(of: text))
        meta.tags = parseTags(text)
    }

    /// Paragraphs as display lines, with each table collapsed into one line: cells of a row joined
    /// by " · ", rows by two spaces, and a header row (shaded or bold) left out.
    static func previewLines(of text: NSAttributedString) -> [String] {
        let ns = text.string as NSString
        var lines: [String] = []
        var currentTable: NSTextTable?
        var rows: [String] = []
        var row: [String] = []
        var rowIndex = -1
        var rowIsHeader = false

        func endRow() {
            let cells = row.filter { !$0.isEmpty }
            if !rowIsHeader, !cells.isEmpty { rows.append(cells.joined(separator: " · ")) }
            row = []
        }
        func endTable() {
            guard currentTable != nil else { return }
            endRow()
            if !rows.isEmpty { lines.append(rows.joined(separator: "  ")) }
            rows = []
            currentTable = nil
            rowIndex = -1
        }

        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(para) }
            let line = clean(ns.substring(with: para))
            let ps = text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            guard let block = ps?.textBlocks.lazy.compactMap({ $0 as? NSTextTableBlock }).first else {
                endTable()
                lines.append(line)
                continue
            }
            if block.table !== currentTable { endTable(); currentTable = block.table }
            if block.startingRow != rowIndex {
                endRow()
                rowIndex = block.startingRow
                rowIsHeader = false
            }
            if block.startingRow == 0 {
                let font = text.attribute(.font, at: para.location, effectiveRange: nil) as? NSFont
                let bold = font.map { $0.fontDescriptor.symbolicTraits.contains(.bold) } ?? false
                if block.backgroundColor != nil || (bold && !line.isEmpty) { rowIsHeader = true }
            }
            row.append(line)
        }
        endTable()
        return lines
    }

    private static func applyTitleAndPreview(to meta: inout NoteMeta, from string: String) {
        applyTitleAndPreview(to: &meta, lines: string.components(separatedBy: .newlines))
    }

    private static func applyTitleAndPreview(to meta: inout NoteMeta, lines: [String]) {
        var titleLineIndex: Int?
        for (i, line) in lines.enumerated() where !clean(line).isEmpty {
            titleLineIndex = i
            break
        }
        if let titleLineIndex {
            meta.title = String(clean(lines[titleLineIndex]).prefix(titleLength))
            let rest = lines[(titleLineIndex + 1)...]
                .map(clean)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            meta.preview = String(rest.prefix(previewLength))
        } else {
            meta.title = ""
            meta.preview = ""
        }
    }

    /// Trims whitespace and invisible characters (attachment glyphs, list markers' tabs).
    private static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `#` must start the text or follow whitespace / opening brackets & quotes / `,` `;`
    /// (so `?q=#swift` or `site.com/#anchor` aren't tags). Tag bodies allow combining marks.
    private static let tagRegex = try? NSRegularExpression(
        pattern: "(?<![^\\s\\p{Ps}\\p{Pi},;\"'])#([\\p{L}_][\\p{L}\\p{M}\\p{N}_\\-]*)"
    )

    static func parseTags(_ string: String) -> [String] {
        guard let regex = tagRegex else { return [] }
        let normalized = string.precomposedStringWithCanonicalMapping
        let ns = normalized as NSString
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1)).lowercased().precomposedStringWithCanonicalMapping
            if seen.insert(tag).inserted { result.append(tag) }
        }
        return result
    }

    /// Blanks out code (monospaced font) and link ranges before parsing, keeping UTF-16 offsets intact.
    static func parseTags(_ text: NSAttributedString) -> [String] {
        let masked = NSMutableString(string: text.string)
        let full = NSRange(location: 0, length: text.length)
        func blank(_ range: NSRange) {
            masked.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            if font.fontDescriptor.symbolicTraits.contains(.monoSpace) || font.isFixedPitch { blank(range) }
        }
        text.enumerateAttribute(.link, in: full) { value, range, _ in
            if value != nil { blank(range) }
        }
        return parseTags(masked as String)
    }

    // MARK: - Persistence

    private struct LibraryFile: Codable {
        var version: Int
        var notebooks: [Notebook]
        var notes: [NoteMeta]
    }

    /// Best-effort salvage of a library.json that failed strict decoding.
    private struct PartialLibrary: Decodable {
        var notebooks: [Notebook]?
        var notes: [NoteMeta]?

        enum CodingKeys: String, CodingKey { case notebooks, notes }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notebooks = try? c.decode([Notebook].self, forKey: .notebooks)
            notes = try? c.decode([NoteMeta].self, forKey: .notes)
        }
    }

    private func bodyURL(for id: UUID) -> URL {
        notesURL.appendingPathComponent("\(id.uuidString).rtfd", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    nonisolated private static func readBody(at url: URL) throws -> NSAttributedString {
        try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
    }

    nonisolated private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    nonisolated private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-\(n)")
            n += 1
        }
        return candidate
    }

    /// IDs of `notes/<uuid>.rtfd` bodies on disk (ignores temp files and corrupt-backups).
    private func bodyIDsOnDisk() -> [UUID] {
        let items = (try? FileManager.default.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url in
            guard url.pathExtension == "rtfd" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let fm = FileManager.default
        try? fm.createDirectory(at: notesURL, withIntermediateDirectories: true)
        // Tombstoned notes are filtered from the library below; their bodies are trashed by flush()
        // only after a library save (or the library just read) confirms they're gone.
        loadTombstones()

        if fm.fileExists(atPath: libraryURL.path) {
            var data: Data?
            do {
                let raw = try Data(contentsOf: libraryURL)
                data = raw
                let library = try Self.decoder.decode(LibraryFile.self, from: raw)
                notebooks = library.notebooks
                notes = library.notes
                libraryNoteIDsOnDisk = Set(library.notes.map(\.id))
                let undeleted = Set(notes.map(\.id).filter(tombstoned))
                if !undeleted.isEmpty {
                    // A deletion whose library save didn't land: complete it (tombstones stay until it's saved).
                    notes.removeAll { undeleted.contains($0.id) }
                    libraryDirty = true
                    debugCrashPoint("after-library-filter")
                }
                markInitialized()
                finishLoad()
                if libraryDirty || !pendingTrash.isEmpty { flush() }
                return
            } catch {
                NSLog("Inkwell: failed to read library.json (\(error))")
                backUpUnreadableLibrary()
                let partial = data.flatMap { try? Self.decoder.decode(PartialLibrary.self, from: $0) }
                rebuildFromBodies(recovered: partial)
                libraryDirty = true
                markInitialized()
                finishLoad()
                flush()
                return
            }
        }

        if !bodyIDsOnDisk().isEmpty {
            NSLog("Inkwell: library.json missing; rebuilding from note bodies")
            rebuildFromBodies(recovered: nil)
        } else if !fm.fileExists(atPath: firstLaunchMarkerURL.path) {
            SeedData.seed(into: self)
        }
        libraryDirty = true
        markInitialized()
        finishLoad()
        flush()
    }

    private func finishLoad() {
        for meta in notes { persistedMeta[meta.id] = meta }
        loadSearchIndex()
        selectedNoteID = notes(for: selection, search: "").first?.id
        scheduleIndexRebuild()
    }

    private func markInitialized() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: firstLaunchMarkerURL.path) else { return }
        fm.createFile(atPath: firstLaunchMarkerURL.path, contents: Data())
    }

    /// Copies (never moves) an unreadable library.json aside; if that fails, the original is write-protected.
    private func backUpUnreadableLibrary() {
        let backup = Self.uniqueURL(rootURL.appendingPathComponent("library.corrupt-\(Self.timestamp()).json"))
        do {
            try FileManager.default.copyItem(at: libraryURL, to: backup)
            libraryWriteBlocked = false
            NSLog("Inkwell: backed up unreadable library.json to \(backup.path)")
        } catch {
            libraryWriteBlocked = true
            NSLog("Inkwell: could not back up unreadable library.json (\(error)); it will not be overwritten")
        }
    }

    /// Recreates note metadata from `notes/*.rtfd`. Salvaged metadata is reused when available;
    /// otherwise notes get a derived title and no notebook.
    private func rebuildFromBodies(recovered: PartialLibrary?) {
        let fm = FileManager.default
        notebooks = recovered?.notebooks ?? []
        let notebookIDs = Set(notebooks.map(\.id))
        var known: [UUID: NoteMeta] = [:]
        for meta in recovered?.notes ?? [] { known[meta.id] = meta }

        var rebuilt: [NoteMeta] = []
        for id in bodyIDsOnDisk() where !tombstoned(id) {
            if var meta = known[id] {
                if let nb = meta.notebookID, !notebookIDs.contains(nb) { meta.notebookID = nil }
                rebuilt.append(meta)
                continue
            }
            let url = bodyURL(for: id)
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let modified = attrs[.modificationDate] as? Date ?? Date()
            let created = attrs[.creationDate] as? Date ?? modified
            var meta = NoteMeta(id: id, notebookID: nil, title: "", preview: "", isPinned: false,
                                createdAt: created, updatedAt: modified, tags: [])
            if let text = try? Self.readBody(at: url) {
                Self.applyDerivedFields(to: &meta, from: text)
                searchIndex[id] = Self.fold(text.string)
                searchIndexDirty = true
            } else {
                meta.title = "Recovered Note"
            }
            rebuilt.append(meta)
        }
        notes = rebuilt
        NSLog("Inkwell: rebuilt library with \(rebuilt.count) note(s) from bodies")
    }

    private func scheduleSave(after delay: TimeInterval = 0.5) {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Synchronously writes all pending changes to disk. Failed body writes stay dirty and are retried;
    /// meanwhile the library keeps their last persisted title/preview/date. At termination, bodies that
    /// still can't be saved are written to `recovery/` instead.
    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: notesURL, withIntermediateDirectories: true)

        var written: Set<UUID> = []
        for id in dirtyBodies {
            guard let text = bodyCache[id] else { written.insert(id); continue }
            if bodyWriteBlocked.contains(id) {
                NSLog("Inkwell: not saving note \(id): unreadable original could not be backed up")
                continue
            }
            do {
                try writeBody(text, to: bodyURL(for: id))
                written.insert(id)
                if failedBodies.remove(id) != nil {
                    // The library and index held back this note's new metadata/text; persist them now.
                    libraryDirty = true
                    searchIndexDirty = true
                }
            } catch {
                let episodeStart = failedBodies.insert(id).inserted
                NSLog("Inkwell: failed to save note \(id): \(error)")
                // A note with no body on disk has nothing to fall back on: keep a copy right away
                // (once per failure episode) instead of only at quit.
                if episodeStart, !fm.fileExists(atPath: bodyURL(for: id).path) {
                    writeRecoveryCopy(id, text)
                }
            }
        }
        dirtyBodies.subtract(written)
        for id in written { recoveredSnapshots[id] = nil }

        if libraryDirty || !fm.fileExists(atPath: libraryURL.path) {
            saveLibrary()
        }
        // Bodies of deleted notes move to .trash only once their removal is persisted.
        if !libraryDirty, !pendingTrash.isEmpty { trashPendingBodies() }
        if searchIndexDirty { saveSearchIndex() }
        if isTerminating { writeRecoveryCopies() }
        trimBodyCache()

        let retryable = dirtyBodies.subtracting(bodyWriteBlocked)
        if !retryable.isEmpty || libraryDirty || !pendingTrash.isEmpty {
            scheduleSave(after: 5)
        }
    }

    /// Notes are written with their last persisted title/preview/date/tags while their body is unsaved.
    /// Notes whose body was never saved are still listed (with current metadata) so they survive a crash;
    /// a listed note without a body file loads as empty.
    @discardableResult
    private func saveLibrary() -> Bool {
        if libraryWriteBlocked {
            backUpUnreadableLibrary()
            if libraryWriteBlocked { return false }
        }
        let fm = FileManager.default
        let unsaved = dirtyBodies
        let persisted: [NoteMeta] = notes.map { meta in
            guard unsaved.contains(meta.id) else { return meta }
            guard let old = persistedMeta[meta.id],
                  fm.fileExists(atPath: bodyURL(for: meta.id).path) else { return meta }
            var copy = meta
            copy.title = old.title
            copy.preview = old.preview
            copy.updatedAt = old.updatedAt
            copy.tags = old.tags
            return copy
        }
        do {
            let data = try Self.encoder.encode(LibraryFile(version: 1, notebooks: notebooks, notes: persisted))
            try data.write(to: libraryURL, options: .atomic)
            persistedMeta = Dictionary(persisted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            libraryNoteIDsOnDisk = Set(persisted.map(\.id))
            libraryDirty = false
            debugCrashPoint("after-library-save")
            return true
        } catch {
            NSLog("Inkwell: failed to save library: \(error)")
            return false
        }
    }

    /// Last resort at quit: copies bodies that couldn't be saved to `recovery/<id>-<timestamp>.rtfd`.
    private func writeRecoveryCopies() {
        for id in dirtyBodies {
            guard let text = bodyCache[id] else { continue }
            writeRecoveryCopy(id, text)
        }
    }

    /// Writes `text` to `recovery/<id>-<timestamp>.rtfd` unless this exact snapshot was already copied.
    private func writeRecoveryCopy(_ id: UUID, _ text: NSAttributedString) {
        guard recoveredSnapshots[id] != ObjectIdentifier(text) else { return }
        do {
            try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
            let url = Self.uniqueURL(recoveryURL.appendingPathComponent("\(id.uuidString)-\(Self.timestamp()).rtfd"))
            try writeBody(text, to: url)
            recoveredSnapshots[id] = ObjectIdentifier(text)
            NSLog("Inkwell: note \(id) couldn’t be saved; wrote a recovery copy to \(url.path)")
        } catch {
            NSLog("Inkwell: note \(id) couldn’t be saved, and writing a recovery copy failed too: \(error)")
        }
    }

    /// Moves tombstoned bodies to `.trash`, then drops tombstones whose body is gone and which the
    /// saved library.json is known not to list.
    private func trashPendingBodies() {
        let fm = FileManager.default
        let before = pendingTrash
        for id in pendingTrash {
            let url = bodyURL(for: id)
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
                    let dest = Self.uniqueURL(trashURL.appendingPathComponent("\(id.uuidString)-\(Self.timestamp()).rtfd"))
                    try fm.moveItem(at: url, to: dest)
                } catch {
                    NSLog("Inkwell: failed to move deleted note \(id) to trash: \(error)")
                    continue
                }
            }
            guard let listed = libraryNoteIDsOnDisk, !listed.contains(id) else { continue }
            pendingTrash.remove(id)
        }
        debugCrashPoint("after-trash")
        if pendingTrash != before { saveTombstones() }
    }

    // MARK: Tombstones

    private func tombstoned(_ id: UUID) -> Bool {
        pendingTrash.contains(id)
    }

    private func loadTombstones() {
        guard let data = try? Data(contentsOf: tombstonesURL) else { return }
        guard let ids = try? Self.decoder.decode([UUID].self, from: data) else {
            NSLog("Inkwell: tombstones.json is unreadable; ignoring it")
            return
        }
        pendingTrash.formUnion(ids)
    }

    /// Debug-only crash simulation: `INKWELL_STORE_CRASHPOINT=<name>` exits immediately (no further
    /// saves, no terminate handlers) when execution reaches that point.
    private func debugCrashPoint(_ name: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["INKWELL_STORE_CRASHPOINT"] == name else { return }
        FileHandle.standardOutput.write("STORETEST crashpoint \(name)\n".data(using: .utf8)!)
        _exit(99)
        #endif
    }

    private func saveTombstones() {
        do {
            if pendingTrash.isEmpty {
                if FileManager.default.fileExists(atPath: tombstonesURL.path) {
                    try FileManager.default.removeItem(at: tombstonesURL)
                }
            } else {
                let ids = pendingTrash.sorted { $0.uuidString < $1.uuidString }
                try Self.encoder.encode(ids).write(to: tombstonesURL, options: .atomic)
            }
        } catch {
            NSLog("Inkwell: failed to save tombstones: \(error)")
        }
    }

    /// RTFD is a directory, so write to a sibling temp location then swap it in.
    private func writeBody(_ text: NSAttributedString, to url: URL) throws {
        let fm = FileManager.default
        let range = NSRange(location: 0, length: text.length)
        let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).rtfd.tmp", isDirectory: true)
        do {
            try wrapper.write(to: temp, options: [], originalContentsURL: nil)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
