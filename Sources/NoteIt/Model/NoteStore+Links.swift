import AppKit
import Foundation
import NoteItCore

enum LinkResolution: Equatable {
    case note(UUID, heading: String?)
    case unresolved(title: String)
    case deleted(UUID)
    case missing(UUID)
}

/// Notes changed by a rename update or Link All. `updated` counts links, `skipped` notes that couldn't be changed;
/// `notes` maps each changed note to its revision right after the change.
struct LinkRewriteResult {
    var updated = 0
    var skipped = 0
    var notes: [UUID: UUID] = [:]
}

struct MentionResult: Identifiable {
    var id: UUID { source }
    var source: UUID
    var contexts: [String]
    var count: Int
}

struct Backlink: Identifiable {
    var id: UUID { source }
    var source: UUID
    var occurrences: [OutgoingLink]
}

extension NoteStore {
    /// The link index registered with the derived-index registry; installed on first use.
    var linkIndex: LinkIndex {
        if let index = derivedIndexes.first(where: { $0.indexID == "links" }) as? LinkIndex { return index }
        return installLinkIndex()
    }

    /// Registers the link index, starts reading `link-index.json`, then rebuilds so entries the file lacks are
    /// extracted (the store's own load-time rebuild ran before the index existed).
    @discardableResult
    func installLinkIndex() -> LinkIndex {
        if let index = derivedIndexes.first(where: { $0.indexID == "links" }) as? LinkIndex { return index }
        let index = LinkIndex()
        index.store = self
        index.fileURL = rootURL.appendingPathComponent(LinkIndex.fileName)
        registerDerivedIndex(index)
        index.startLoading(store: self)
        index.observeTermination()
        rebuildDerivedIndexes()
        return index
    }

    // MARK: Resolution

    func resolve(_ link: NoteLink, from source: UUID?) -> LinkResolution {
        switch link {
        case .note(let id, let heading):
            guard let meta = note(with: id) else { return .missing(id) }
            if meta.deletedAt != nil { return .deleted(id) }
            return .note(id, heading: heading)
        case .unresolved(let title, let heading):
            let preferred = note(with: source)?.notebookID
            if let id = noteID(forTitle: title, preferring: preferred) { return .note(id, heading: heading) }
            return .unresolved(title: title)
        }
    }

    /// The live note with this title (folded): the one in `notebookID` first, else the most recently edited.
    func noteID(forTitle title: String, preferring notebookID: UUID?) -> UUID? {
        let key = TextFold.fold(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty, let ids = linkIndex.titleIndex(for: self)[key], !ids.isEmpty else { return nil }
        let metas = ids.compactMap { note(with: $0) }
        if let notebookID, let same = metas.filter({ $0.notebookID == notebookID }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return same.id
        }
        return metas.max(by: { $0.updatedAt < $1.updatedAt })?.id
    }

    func linkCandidates(excluding id: UUID?) -> [LinkCandidate] {
        let names = Dictionary(notebooks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let templates = templatesNotebookIDIfSet
        return notes.compactMap { meta in
            guard meta.deletedAt == nil, meta.id != id,
                  !meta.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  templates == nil || meta.notebookID != templates else { return nil }
            return LinkCandidate(id: meta.id, title: meta.title,
                                 notebookName: meta.notebookID.flatMap { names[$0] } ?? "",
                                 updatedAt: meta.updatedAt)
        }
    }

    // MARK: Queries

    func outgoingLinks(from id: UUID) -> [OutgoingLink] {
        guard let meta = note(with: id), !meta.isLocked else { return [] }
        return linkIndex.outgoing(from: id)
    }

    /// Live sources linking to `id`, newest first; self-links are left to `outgoingLinks`.
    func backlinks(to id: UUID) -> [Backlink] {
        guard let target = note(with: id) else { return [] }
        let templates = templatesNotebookIDIfSet
        var result: [(Backlink, Date)] = []
        for source in linkIndex.sources(linkingTo: id, title: target.title) where source != id {
            guard let meta = note(with: source), meta.deletedAt == nil, !meta.isLocked,
                  templates == nil || meta.notebookID != templates else { continue }
            let occurrences = linkIndex.outgoing(from: source).filter { item in
                guard let link = item.link else { return false }
                if case .note(let resolved, _) = resolve(link, from: source) { return resolved == id }
                return false
            }
            guard !occurrences.isEmpty else { continue }
            result.append((Backlink(source: source, occurrences: occurrences), meta.updatedAt))
        }
        return result.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// What `followLink` asks the user; replaced by tests.
enum LinkAlert: Equatable {
    case deleted(title: String)
    case missing
}

/// Transient link-navigation state the editor header shows.
@MainActor
final class LinkNavigationState: ObservableObject {
    static let shared = LinkNavigationState()
    /// Set for 3 seconds after a link's heading wasn't found in its note.
    @Published var missingHeading: (note: UUID, heading: String)?
    private var clearTask: Task<Void, Never>?

    func showMissingHeading(_ heading: String, in note: UUID) {
        missingHeading = (note, heading)
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.missingHeading = nil
        }
    }

    /// Returns true for the confirming button (Show / Remove Link).
    var confirm: @MainActor (LinkAlert) -> Bool = LinkNavigationState.runAlert

    private static func runAlert(_ kind: LinkAlert) -> Bool {
        let alert = NSAlert()
        switch kind {
        case .deleted(let title):
            alert.messageText = title.isEmpty ? "This note is in Recently Deleted." : "“\(title)” is in Recently Deleted."
            alert.addButton(withTitle: "Show")
        case .missing:
            alert.messageText = "This note no longer exists"
            alert.addButton(withTitle: "Remove Link")
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension NoteStore {
    // MARK: Following links

    /// Opens what `link` points at (spec §3). `source` is the note the link is in; nil when it came from outside.
    func followLink(_ link: NoteLink, from source: UUID?) {
        switch resolve(link, from: source) {
        case .note(let id, let heading):
            if case .unresolved = link, let source { rewriteLinks(in: source, matching: link, to: id) }
            navigate(to: id, heading: heading)
        case .unresolved(let title):
            let meta = createNoteForLink(title: title, from: source)
            if let source { rewriteLinks(in: source, matching: link, to: meta.id) }
            navigate(to: meta.id, heading: nil)
        case .deleted(let id):
            guard LinkNavigationState.shared.confirm(.deleted(title: note(with: id)?.title ?? "")) else { return }
            if source == nil { WindowRouter.showMainWindow() }
            searchText = ""
            selection = .recentlyDeleted
            selectedNoteID = id
        case .missing:
            guard let source, LinkNavigationState.shared.confirm(.missing) else { return }
            try? editBody(source, actionName: "Remove Link", versioning: .none) { text in
                for range in Self.linkRanges(in: text, matching: link).reversed() {
                    text.removeAttribute(.link, range: range)
                }
            }
        }
    }

    /// Selects `id`, with the caret at `heading` when the note has it. Leaves the sidebar alone when the note is
    /// already in the visible list.
    func navigate(to id: UUID, heading: String?) {
        if let heading {
            let location = headingLocation(heading, in: id)
            if location == nil { LinkNavigationState.shared.showMissingHeading(heading, in: id) }
            if selectedNoteID == id, let textView = OpenEditorRegistry.shared.textView(for: id) {
                textView.setSelectedRange(NSRange(location: location ?? 0, length: 0))
                textView.scrollToTopThird(location ?? 0)
            } else {
                RichTextEditor.pendingCaret[id] = location ?? 0
            }
        }
        if notes(for: selection, search: searchText).contains(where: { $0.id == id }) {
            selectedNoteID = id
        } else {
            reveal(id)
        }
    }

    /// Where the first heading whose folded text equals `heading` starts; nil when the note has none. A heading of
    /// exactly `NoteLink.maxTextLength` characters was cut to fit a link, so it matches the start of a longer one.
    func headingLocation(_ heading: String, in id: UUID) -> Int? {
        let wanted = TextFold.fold(heading.trimmingCharacters(in: .whitespaces))
        let items = headings(for: id)
        if let exact = items.first(where: { TextFold.fold($0.text) == wanted }) { return exact.range.location }
        guard heading.count == NoteLink.maxTextLength, !wanted.isEmpty else { return nil }
        return items.first { TextFold.fold($0.text).hasPrefix(wanted) }?.range.location
    }

    private static var headingCache: [UUID: (updatedAt: Date, items: [OutlineItem])] = [:]

    /// The note's outline from its stored body, cached per `updatedAt`. Empty for locked notes.
    func headings(for id: UUID) -> [OutlineItem] {
        guard let meta = note(with: id), !meta.isLocked else { return [] }
        if let cached = Self.headingCache[id], cached.updatedAt == meta.updatedAt { return cached.items }
        let items = OutlineExtractor.items(in: body(for: id))
        if Self.headingCache.count > 500 { Self.headingCache.removeAll() }
        Self.headingCache[id] = (meta.updatedAt, items)
        return items
    }

    /// Creates the note an unresolved link names, in the notebook the Links setting picks. Not selected.
    @discardableResult
    func createNoteForLink(title: String, from source: UUID?) -> NoteMeta {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(NoteLink.maxTextLength))
        let notebookID: UUID?
        if preferences.string(forKey: PrefKey.linkNewNoteNotebook) == "default" {
            notebookID = defaultNotebookIDForNewNotes
        } else if let source {
            notebookID = note(with: source)?.notebookID
        } else {
            notebookID = defaultNotebookIDForNewNotes
        }
        if let template = defaultTemplateID(for: notebookID) {
            return createNote(fromTemplate: template, title: title, in: notebookID)
        }
        return createNote(in: notebookID, initial: Self.linkedNoteBody(title: title))
    }

    /// A title paragraph and an empty body paragraph.
    static func linkedNoteBody(title: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + "\n", attributes: EditorStyle.attributes(for: .title))
        text.append(NSAttributedString(string: "", attributes: EditorStyle.bodyAttributes))
        return text
    }

    /// Points the links in `source` that are `link` (same target, folded) at `id`, keeping their headings.
    func rewriteLinks(in source: UUID, matching link: NoteLink, to id: UUID) {
        let current = body(for: source)
        guard !Self.linkRanges(in: current, matching: link).isEmpty else { return }
        try? editBody(source, actionName: "Link", versioning: .none) { text in
            for range in Self.linkRanges(in: text, matching: link) {
                guard let url = text.attribute(.link, at: range.location, effectiveRange: nil).flatMap(Self.url(from:)),
                      let existing = NoteLink(url: url) else { continue }
                text.addAttribute(.link, value: NoteLink.note(id: id, heading: existing.heading).url, range: range)
            }
        }
    }

    /// `.link` runs whose note link has the same target as `link` (headings ignored, titles folded).
    static func linkRanges(in text: NSAttributedString, matching link: NoteLink) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value.flatMap(url(from:)), let found = NoteLink(url: url) else { return }
            if sameTarget(found, link) { ranges.append(range) }
        }
        return ranges
    }

    private static func sameTarget(_ a: NoteLink, _ b: NoteLink) -> Bool {
        switch (a, b) {
        case let (.note(x, _), .note(y, _)): return x == y
        case let (.unresolved(x, _), .unresolved(y, _)):
            return TextFold.fold(x.trimmingCharacters(in: .whitespacesAndNewlines))
                == TextFold.fold(y.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return false
        }
    }

    static func url(from value: Any) -> URL? {
        (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }
}

extension NoteStore {
    func linkToolTip(for link: NoteLink, from source: UUID?) -> String {
        switch resolve(link, from: source) {
        case .note(let id, let heading):
            guard let meta = note(with: id) else { return "" }
            var text = meta.displayTitle
            if let heading, !heading.isEmpty { text += " › \(heading)" }
            if let name = meta.notebookID.flatMap({ notebook(with: $0)?.name }) { text += " — \(name)" }
            return text
        case .unresolved(let title):
            return "Create “\(title)”"
        case .deleted(let id):
            return "\(note(with: id)?.displayTitle ?? "") — Recently Deleted"
        case .missing:
            return "This note no longer exists"
        }
    }

    // MARK: Rename updates

    static let rewriteBatchSize = 20

    /// `.link` runs to `id` (by ID) whose text folds equal to `oldTitle`.
    static func linkTextRanges(in text: NSAttributedString, targeting id: UUID, title oldTitle: String) -> [NSRange] {
        let wanted = TextFold.fold(oldTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !wanted.isEmpty else { return [] }
        let ns = text.string as NSString
        return linkRanges(in: text, matching: .note(id: id, heading: nil)).filter {
            TextFold.fold(ns.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)) == wanted
        }
    }

    /// Sources whose index entry has a link to `id` showing `oldTitle`, the note itself included.
    private func linkTextSources(for id: UUID, oldTitle: String) -> [UUID] {
        let wanted = TextFold.fold(oldTitle.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !wanted.isEmpty else { return [] }
        return linkIndex.sources(linkingTo: id, title: "").filter { source in
            linkIndex.outgoing(from: source).contains { item in
                guard case .note(let target, _) = item.link, target == id else { return false }
                return TextFold.fold(item.text.trimmingCharacters(in: .whitespacesAndNewlines)) == wanted
            }
        }.sorted { $0.uuidString < $1.uuidString }
    }

    /// Live, editable notes with links to `id` whose text is `oldTitle`.
    func renameCandidates(for id: UUID, oldTitle: String) -> [UUID] {
        linkTextSources(for: id, oldTitle: oldTitle).filter { source in
            guard let meta = note(with: source), meta.deletedAt == nil, !meta.isLocked else { return false }
            return !isBodyWriteBlocked(source)
        }
    }

    /// Replaces the text of links to `id` that read `oldTitle` with `newTitle`, keeping their attributes, one
    /// `editBody` per note (each records a version first). Notes that can't be changed are counted as skipped.
    func rewriteLinkText(targeting id: UUID, from oldTitle: String, to newTitle: String) async -> LinkRewriteResult {
        var result = LinkRewriteResult()
        let replacement = String(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(NoteLink.maxTextLength))
        guard !replacement.isEmpty else { return result }
        for (index, source) in linkTextSources(for: id, oldTitle: oldTitle).enumerated() {
            if index > 0, index % Self.rewriteBatchSize == 0 { await Task.yield() }
            var count = 0
            do {
                try editBody(source, actionName: "Update Links", versioning: .recordCurrent) { text in
                    let ranges = Self.linkTextRanges(in: text, targeting: id, title: oldTitle)
                    count = ranges.count
                    for range in ranges.reversed() {
                        let attributes = text.attributes(at: range.location, effectiveRange: nil)
                        text.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attributes))
                    }
                }
            } catch {
                result.skipped += 1
                continue
            }
            guard count > 0, let revision = note(with: source)?.revision else { continue }
            result.updated += count
            result.notes[source] = revision
        }
        return result
    }

    /// Restores the version `editBody` recorded for each note in `result` that hasn't changed since. Returns how many
    /// notes were left alone.
    @discardableResult
    func undoLinkRewrite(_ result: LinkRewriteResult) -> Int {
        var leftAlone = 0
        for (id, revision) in result.notes {
            guard let meta = note(with: id), meta.revision == revision, let version = versions(of: id).first else {
                leftAlone += 1
                continue
            }
            do { try restoreVersion(version) } catch { leftAlone += 1 }
        }
        return leftAlone
    }

    // MARK: Unlinked mentions

    /// Titles too short, or only a date, to search for.
    func mentionsAreSearched(for id: UUID) -> Bool {
        guard let title = note(with: id)?.title.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return title.count >= MentionFinder.minimumTitleLength && DailyNoteTitle.parse(title, locale: .current) == nil
    }

    /// Live notes that mention `id`'s title in plain text and don't link to it, newest first, each with the context
    /// of its first 3 mentions. Scans the folded search text off the main actor; stops early when cancelled.
    func unlinkedMentions(of id: UUID) async -> [MentionResult] {
        guard let target = note(with: id), mentionsAreSearched(for: id) else { return [] }
        let title = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = TextFold.fold(title)
        let templates = templatesNotebookIDIfSet
        let linking = linkIndex.sources(linkingTo: id, title: title)
        let candidates = notes.filter { meta in
            meta.id != id && meta.deletedAt == nil && !meta.isLocked && !linking.contains(meta.id)
                && (templates == nil || meta.notebookID != templates)
        }
        let order = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.updatedAt) })
        let texts = foldedSearchText(of: candidates.map(\.id))
        let matches: [UUID]? = await Task.detached(priority: .userInitiated) {
            var found: [UUID] = []
            for (index, entry) in texts.enumerated() {
                if index % 500 == 0, Task.isCancelled { return nil }
                if MentionFinder.mayMention(folded, inFolded: entry.value) { found.append(entry.key) }
            }
            return found
        }.value
        guard var matches, !Task.isCancelled else { return [] }
        matches.sort { (order[$0] ?? .distantPast) > (order[$1] ?? .distantPast) }
        var results: [MentionResult] = []
        for (index, source) in matches.enumerated() {
            if index > 0, index % Self.rewriteBatchSize == 0 {
                await Task.yield()
                if Task.isCancelled { return [] }
            }
            guard let meta = note(with: source), meta.deletedAt == nil, !meta.isLocked else { continue }
            let text = body(for: source)
            let ranges = MentionFinder.ranges(of: title, in: text)
            guard !ranges.isEmpty else { continue }
            let ns = text.string as NSString
            let contexts = ranges.prefix(3).map { LinkExtractor.context(around: $0, in: ns) }
            results.append(MentionResult(source: source, contexts: contexts, count: ranges.count))
        }
        return results
    }

    /// Turns the mentions of `target`'s title in each source into links to it, keeping the text. One source is
    /// changed with `versioning: .none` (one Undo step in an open editor); several record a version each.
    func linkMentions(of target: UUID, in sources: [UUID],
                      versioning: EditBodyVersioning? = nil) async -> (linked: Int, result: LinkRewriteResult) {
        var result = LinkRewriteResult()
        guard let title = note(with: target)?.title else { return (0, result) }
        let url = NoteLink.note(id: target, heading: nil).url
        let versioning = versioning ?? (sources.count > 1 ? .recordCurrent : .none)
        for (index, source) in sources.enumerated() {
            if index > 0, index % Self.rewriteBatchSize == 0 { await Task.yield() }
            var count = 0
            do {
                try editBody(source, actionName: "Link Mention", versioning: versioning) { text in
                    let ranges = MentionFinder.ranges(of: title, in: text)
                    count = ranges.count
                    for range in ranges { text.addAttribute(.link, value: url, range: range) }
                }
            } catch {
                result.skipped += 1
                continue
            }
            guard count > 0, let revision = note(with: source)?.revision else { continue }
            result.updated += count
            result.notes[source] = revision
        }
        return (result.updated, result)
    }
}

