import AppKit
import Foundation
import NoteItCore

/// The search index (`indexID` "search"): folded and plain text, tasks and reminders of every unlocked note, kept in
/// `search-index.json` in the data folder. Pin, notebook and Recently Deleted are read from `NoteMeta` at query time.
@MainActor
final class OrganiseIndexer: DerivedIndex {
    static let fileName = "search-index.json"
    static let progressStep = 200

    let indexID = "search"
    private(set) var entries: [UUID: SearchIndexEntry] = [:]
    /// Bumped on every change, metadata included.
    private(set) var version = 0

    weak var store: NoteStore?
    let fileURL: URL
    private(set) var isDirty = false
    private var isRebuilding = false
    /// Set once a rebuild has gone over every note after launch.
    private(set) var hasRebuilt = false
    private var changedDuringRebuild: Set<UUID> = []
    /// Entries built off the main actor for a body about to be applied (see `prime`).
    private var primed: [UUID: (body: WeakSnapshot, entry: SearchIndexEntry)] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    nonisolated static func makeEntry(_ body: NSAttributedString, updatedAt: Date) -> SearchIndexEntry {
        let masked = NoteStore.maskedForTokens(body)
        let parsed = TaskParser.parse(masked: masked)
        var hasAttachment = false
        if body.length > 0 {
            body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, _, stop in
                if value != nil {
                    hasAttachment = true
                    stop.pointee = true
                }
            }
        }
        return SearchIndexEntry(text: TextFold.fold(body.string), plain: body.string, tasks: parsed.tasks,
                                reminders: parsed.reminders, hasAttachment: hasAttachment, updatedAt: updatedAt)
    }

    /// The folded text of `id`, or nil when it has no entry.
    func text(for id: UUID) -> String? { entries[id]?.text }

    /// Lets the next `noteChanged` for exactly this body reuse an entry built off the main actor.
    func prime(_ id: UUID, body: NSAttributedString, entry: SearchIndexEntry) {
        primed[id] = (WeakSnapshot(body), entry)
    }

    /// Indexes one note without notifying other indexes (a body read for the first time).
    func indexIfMissing(_ meta: NoteMeta, body: NSAttributedString) {
        guard !meta.isLocked, entries[meta.id]?.isComplete != true else { return }
        set(Self.makeEntry(body, updatedAt: meta.updatedAt), for: meta.id)
    }

    func markDirty() { isDirty = true }

    private func set(_ entry: SearchIndexEntry, for id: UUID) {
        entries[id] = entry
        if isRebuilding { changedDuringRebuild.insert(id) }
        isDirty = true
        version &+= 1
    }

    // MARK: DerivedIndex

    func noteChanged(_ note: NoteMeta, body: NSAttributedString) {
        var entry: SearchIndexEntry
        if let ready = primed.removeValue(forKey: note.id), ready.body.text === body {
            entry = ready.entry
        } else {
            entry = Self.makeEntry(body, updatedAt: note.updatedAt)
        }
        entry.updatedAt = note.updatedAt
        set(entry, for: note.id)
    }

    func noteRemoved(_ noteID: UUID) {
        primed[noteID] = nil
        if isRebuilding { changedDuringRebuild.insert(noteID) }
        guard entries.removeValue(forKey: noteID) != nil else { return }
        isDirty = true
        version &+= 1
    }

    func metadataChanged(_ note: NoteMeta) {
        version &+= 1
    }

    /// Builds the entries that are missing or came from a version 1 file; drops entries of notes that are gone.
    func rebuild(notes: [NoteMeta], body: @escaping (UUID) -> NSAttributedString?) async {
        guard !isRebuilding else { return }
        let unlocked = Set(notes.lazy.filter { !$0.isLocked }.map(\.id))
        for id in Array(entries.keys) where !unlocked.contains(id) {
            if let meta = store?.note(with: id), !meta.isLocked { continue }
            entries[id] = nil
            isDirty = true
            version &+= 1
        }
        let missing = notes.filter { !$0.isLocked && entries[$0.id]?.isComplete != true && store?.hasUnreadableBody($0.id) != true }
        guard !missing.isEmpty else {
            hasRebuilt = true
            return
        }
        isRebuilding = true
        changedDuringRebuild = []
        defer {
            hasRebuilt = true
            isRebuilding = false
            changedDuringRebuild = []
        }
        var merged = false
        var start = 0
        while start < missing.count {
            let chunk = Array(missing[start..<min(start + Self.progressStep, missing.count)])
            start += chunk.count
            let built = await Task.detached(priority: .utility) { () -> [(UUID, SearchIndexEntry)] in
                chunk.compactMap { meta in body(meta.id).map { (meta.id, Self.makeEntry($0, updatedAt: meta.updatedAt)) } }
            }.value
            for (id, entry) in built where !changedDuringRebuild.contains(id) && entries[id]?.isComplete != true {
                guard let meta = store?.note(with: id), !meta.isLocked else { continue }
                var fresh = entry
                fresh.updatedAt = meta.updatedAt
                entries[id] = fresh
                isDirty = true
                version &+= 1
                merged = true
            }
        }
        if merged { store?.searchIndexDidRebuild() }
    }

    func flush() {
        if isDirty { save() }
    }

    // MARK: File

    /// Keeps the entries whose `updatedAt` matches the note's (within a second); locked notes get none.
    func load(notes: [NoteMeta]) {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? NoteStore.decoder.decode(SearchIndexFile.self, from: data) else { return }
        for meta in notes where !meta.isLocked && entries[meta.id] == nil {
            guard let entry = file.entries[meta.id.uuidString],
                  abs(entry.updatedAt.timeIntervalSince(meta.updatedAt)) < 1 else { continue }
            entries[meta.id] = entry
        }
        if file.version != SearchIndexFile.currentVersion { isDirty = true }
        version &+= 1
    }

    /// Entries are stamped with the note's updatedAt; unsaved bodies are left out so a crash or a failed write can't
    /// leave the index ahead of (or behind) what's on disk.
    func save() {
        guard let store else { return }
        var out: [String: SearchIndexEntry] = [:]
        for meta in store.notes where !meta.isLocked && !store.isBodyDirty(meta.id) {
            guard var entry = entries[meta.id] else { continue }
            entry.updatedAt = meta.updatedAt
            out[meta.id.uuidString] = entry
        }
        do {
            let data = try NoteStore.encoder.encode(SearchIndexFile(version: SearchIndexFile.currentVersion, entries: out))
            try data.write(to: fileURL, options: .atomic)
            isDirty = false
        } catch {
            NSLog("NoteIt: failed to save search index: \(error)")
        }
    }
}
