import AppKit
import Foundation
import NoteItCore

struct LinkIndexFile: Codable {
    var version = 1
    var entries: [String: Entry]

    struct Entry: Codable {
        var updatedAt: Date
        var links: [OutgoingLink]
    }
}

/// Outgoing note links per note, with reverse maps for backlinks (spec §6). Registered with NoteStore's
/// derived-index registry; persisted to `link-index.json` in the data folder.
@MainActor
final class LinkIndex: ObservableObject, DerivedIndex {
    static let fileName = "link-index.json"
    static let progressStep = 200

    let indexID = "links"
    @Published private(set) var version = 0
    @Published private(set) var rebuildProgress: (done: Int, total: Int)?

    weak var store: NoteStore?
    var fileURL: URL?
    var writeDelay: TimeInterval = 3

    private var outgoingBySource: [UUID: [OutgoingLink]] = [:]
    private var incoming: [UUID: Set<UUID>] = [:]
    private var unresolvedByTitle: [String: Set<UUID>] = [:]
    private var isDirty = false
    private var writeWorkItem: DispatchWorkItem?
    private var changedDuringRebuild: Set<UUID> = []
    private var isRebuilding = false
    private(set) var loadTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    private var titleIndexVersion = -1
    private var titleIndexCache: [String: [UUID]] = [:]
    private var titleIndexTemplates: UUID?

    init() {}

    // MARK: Entries

    func set(_ links: [OutgoingLink], for source: UUID) {
        if isRebuilding { changedDuringRebuild.insert(source) }
        let old = outgoingBySource[source] ?? []
        if old == links, outgoingBySource[source] != nil { return }
        unlink(source, old)
        outgoingBySource[source] = links
        for item in links {
            switch item.link {
            case .note(let id, _)?: incoming[id, default: []].insert(source)
            case .unresolved(let title, _)?: unresolvedByTitle[TextFold.fold(title), default: []].insert(source)
            case nil: break
            }
        }
        changed()
    }

    func remove(_ source: UUID) {
        if isRebuilding { changedDuringRebuild.insert(source) }
        guard let old = outgoingBySource.removeValue(forKey: source) else { return }
        unlink(source, old)
        changed()
    }

    private func unlink(_ source: UUID, _ links: [OutgoingLink]) {
        for item in links {
            switch item.link {
            case .note(let id, _)?:
                incoming[id]?.remove(source)
                if incoming[id]?.isEmpty == true { incoming[id] = nil }
            case .unresolved(let title, _)?:
                let key = TextFold.fold(title)
                unresolvedByTitle[key]?.remove(source)
                if unresolvedByTitle[key]?.isEmpty == true { unresolvedByTitle[key] = nil }
            case nil: break
            }
        }
    }

    private func changed() {
        isDirty = true
        version &+= 1
    }

    func outgoing(from source: UUID) -> [OutgoingLink] { outgoingBySource[source] ?? [] }

    func sources(linkingTo id: UUID, title: String) -> Set<UUID> {
        var result = incoming[id] ?? []
        let key = TextFold.fold(title)
        if !key.isEmpty, let byTitle = unresolvedByTitle[key] { result.formUnion(byTitle) }
        return result
    }

    func hasEntry(for source: UUID) -> Bool { outgoingBySource[source] != nil }

    var entryCount: Int { outgoingBySource.count }

    func snapshot(updatedAt: [UUID: Date]) -> LinkIndexFile {
        var entries: [String: LinkIndexFile.Entry] = [:]
        for (id, date) in updatedAt {
            guard let links = outgoingBySource[id] else { continue }
            entries[id.uuidString] = LinkIndexFile.Entry(updatedAt: date, links: links)
        }
        return LinkIndexFile(entries: entries)
    }

    /// Loads entries whose date matches within 1 s. Returns the IDs in `metas` still without an entry.
    @discardableResult
    func load(_ file: LinkIndexFile, validFor metas: [UUID: Date]) -> Set<UUID> {
        var missing = Set<UUID>()
        guard file.version == 1 else { return Set(metas.keys.filter { !hasEntry(for: $0) }) }
        let wasDirty = isDirty
        for (id, date) in metas where !hasEntry(for: id) {
            guard let entry = file.entries[id.uuidString],
                  abs(entry.updatedAt.timeIntervalSince(date)) < 1 else {
                missing.insert(id)
                continue
            }
            set(entry.links, for: id)
        }
        isDirty = wasDirty
        return missing
    }

    // MARK: Title index

    func titleIndex(for store: NoteStore) -> [String: [UUID]] {
        let templates = store.templatesNotebookIDIfSet
        if titleIndexVersion == store.notesVersion, titleIndexTemplates == templates { return titleIndexCache }
        var map: [String: [UUID]] = [:]
        for meta in store.notes where meta.deletedAt == nil && (templates == nil || meta.notebookID != templates) {
            let key = TextFold.fold(meta.title)
            guard !key.isEmpty else { continue }
            map[key, default: []].append(meta.id)
        }
        titleIndexCache = map
        titleIndexVersion = store.notesVersion
        titleIndexTemplates = templates
        return map
    }

    func invalidateTitleIndex() { titleIndexVersion = -1 }

    // MARK: DerivedIndex

    func noteChanged(_ note: NoteMeta, body: NSAttributedString) {
        set(LinkExtractor.links(in: body), for: note.id)
    }

    func noteRemoved(_ noteID: UUID) {
        remove(noteID)
    }

    func metadataChanged(_ note: NoteMeta) {
        invalidateTitleIndex()
        version &+= 1
    }

    func rebuild(notes: [NoteMeta], body: @escaping (UUID) -> NSAttributedString?) async {
        await loadTask?.value
        let current = Set(notes.lazy.filter { !$0.isLocked }.map(\.id))
        // Notes created or unlocked since `notes` was taken keep their entries.
        for id in Array(outgoingBySource.keys) where !current.contains(id) {
            if let meta = store?.note(with: id), !meta.isLocked { continue }
            remove(id)
        }
        let missing = notes.filter { !$0.isLocked && !hasEntry(for: $0.id) }.map(\.id)
        guard !missing.isEmpty else { return }
        isRebuilding = true
        changedDuringRebuild = []
        defer {
            isRebuilding = false
            changedDuringRebuild = []
            rebuildProgress = nil
        }
        rebuildProgress = (0, missing.count)
        var done = 0
        var start = 0
        while start < missing.count {
            let chunk = Array(missing[start..<min(start + Self.progressStep, missing.count)])
            start += chunk.count
            let extracted = await Task.detached(priority: .utility) { () -> [(UUID, [OutgoingLink])] in
                chunk.compactMap { id in body(id).map { (id, LinkExtractor.links(in: $0)) } }
            }.value
            for (id, links) in extracted where !changedDuringRebuild.contains(id) && !hasEntry(for: id) {
                set(links, for: id)
            }
            done += chunk.count
            rebuildProgress = (done, missing.count)
        }
        if isDirty { flush() }
    }

    func flush() {
        guard isDirty, writeWorkItem == nil, fileURL != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.writeWorkItem = nil
                self.write(synchronously: false)
            }
        }
        writeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDelay, execute: item)
    }

    /// Writes now, on this thread (termination, tests).
    func writeNow() {
        writeWorkItem?.cancel()
        writeWorkItem = nil
        write(synchronously: true)
    }

    private func write(synchronously: Bool) {
        guard isDirty, let url = fileURL else { return }
        var dates: [UUID: Date] = [:]
        if let store {
            for meta in store.notes where !meta.isLocked && !store.isBodyDirty(meta.id) {
                dates[meta.id] = meta.updatedAt
            }
        }
        let file = snapshot(updatedAt: dates)
        isDirty = false
        let work = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(file) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if synchronously { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }

    // MARK: Opening

    nonisolated static func readFile(at url: URL) -> LinkIndexFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(LinkIndexFile.self, from: data), file.version == 1 else { return nil }
        return file
    }

    /// Reads `link-index.json` off the main actor and keeps its fresh entries; `rebuild` waits for it.
    func startLoading(store: NoteStore) {
        guard let url = fileURL else { return }
        loadTask = Task { [weak self] in
            let file = await Task.detached(priority: .userInitiated) { LinkIndex.readFile(at: url) }.value
            guard let self, let file else { return }
            var metas: [UUID: Date] = [:]
            for meta in store.notes where !meta.isLocked { metas[meta.id] = meta.updatedAt }
            self.load(file, validFor: metas)
        }
    }

    func observeTermination() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeNow() }
        }
    }
}
