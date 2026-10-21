import AppKit
import Combine
import CryptoKit
import Foundation
import NoteItSync

@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore(location: defaultLocation())

    @Published var notebooks: [Notebook] = [] {
        didSet { notebooksVersion &+= 1 }
    }
    @Published var notes: [NoteMeta] = [] {
        didSet { notesVersion &+= 1 }
    }
    @Published var selection: SidebarSelection? = .allNotes {
        didSet { if selection != oldValue { editingNoteID = nil } }
    }
    @Published var selectedNoteID: UUID? {
        didSet { if selectedNoteID != editingNoteID { editingNoteID = nil } }
    }
    @Published var searchText: String = "" {
        didSet { if searchText != oldValue { editingNoteID = nil } }
    }
    /// Last note whose content was replaced outside its editor (sync, editBody); the editor reloads it when it's
    /// open, and read-only observers get the saved body.
    @Published var externallyUpdatedNoteID: UUID? {
        didSet {
            guard let id = externallyUpdatedNoteID, OpenEditorRegistry.shared.hasObservers(for: id) else { return }
            OpenEditorRegistry.shared.notifyObservers(of: id, body: body(for: id))
        }
    }

    /// Journal local deletions to `sync-deletions.json`; set by the sync controller while sync is configured.
    static var syncJournalEnabled = false

    /// Window during which notes count as "Recent".
    static let recentInterval: TimeInterval = LibraryQuery.recentInterval
    nonisolated static let previewLength = 140
    nonisolated static let titleLength = 120
    /// Max clean (non-dirty, non-selected) bodies kept in memory.
    static let bodyCacheLimit = 20

    nonisolated let rootURL: URL
    /// Where the note bodies live (Task 4.1): `RTFDBodyStorage(rootURL:)` in wave 0.
    nonisolated let bodyStorage: NoteBodyStorage
    nonisolated var notesURL: URL { bodyStorage.contentRootURL }
    var libraryURL: URL { rootURL.appendingPathComponent("library.json") }
    var searchIndexURL: URL { rootURL.appendingPathComponent(OrganiseIndexer.fileName) }
    var trashURL: URL { rootURL.appendingPathComponent(".trash", isDirectory: true) }
    var tombstonesURL: URL { rootURL.appendingPathComponent("tombstones.json") }
    var recoveryURL: URL { rootURL.appendingPathComponent("recovery", isDirectory: true) }
    var syncDeletionsURL: URL { rootURL.appendingPathComponent("sync-deletions.json") }
    nonisolated var historyURL: URL { rootURL.appendingPathComponent("history", isDirectory: true) }
    /// Earlier bodies of each note, kept on this Mac only.
    let history: VersionHistory
    private var firstLaunchMarkerURL: URL { rootURL.appendingPathComponent(".initialized") }
    /// False when migration didn't report a fresh install (see `LibraryMigration.Outcome.allowsSeeding`).
    private let seedsFreshLibrary: Bool

    private var bodyCache: [UUID: NSAttributedString] = [:]
    private var bodyAccessOrder: [UUID] = []
    private var dirtyBodies: Set<UUID> = []
    private(set) var libraryDirty = false
    private var saveWorkItem: DispatchWorkItem?
    /// True while `load()` reads the library; automation answers `.notReady` meanwhile.
    private(set) var isLoading = false

    /// The search index (`search-index.json`), registered as the first derived index.
    let searchIndexer: OrganiseIndexer
    private(set) var notebooksVersion = 0
    /// Search state kept by NoteStore+Search.
    var imageTextProvider: ImageTextProviding?
    var searchDocumentCache: SearchDocumentCache?
    var searchResultCache: [SearchResultKey: [SearchResult]] = [:]
    private var indexSaveWorkItem: DispatchWorkItem?

    /// Position hints for `note(with:)`; rebuilt only after `notes` changed and a lookup misses.
    private(set) var notesVersion = 0
    /// Daily notes by day; rebuilt by `dailyNoteIndex` after `notes` change.
    var dailyNoteIndexCache: DailyNoteIndex?
    /// The pick among several "Daily Notes" notebooks, for `notesVersion` and those notebooks.
    var dailyNotebookChoiceCache: (notesVersion: Int, named: [UUID], choice: UUID?)?
    /// How often that pick scanned the notes (tests).
    var dailyNotebookChoiceScans = 0
    private var noteIndexVersion = -1
    private var noteIndexByID: [UUID: Int] = [:]
    /// Editor snapshots taken during a view update and handed to `updateBody` on the next main-queue turn.
    private var stagedEditorBodies: [UUID: NSAttributedString] = [:]
    /// Titles changed by typing in an editor; not by sync, Restore Version, link rewrites or the API.
    let editorTitleCommits = PassthroughSubject<(id: UUID, title: String), Never>()
    /// Set while `editBody` saves its own change through the open editor, which isn't a rename the user typed.
    var savingProgrammaticEdit = false

    /// Read failures for note bodies, keyed by note ID (message suitable for UI).
    private var loadErrors: [UUID: String] = [:]
    /// File to reveal for a load error: the backup, or the original when it couldn't be backed up.
    private var loadErrorFiles: [UUID: URL] = [:]
    /// Metadata as last written to library.json; used for notes whose newer body failed to save,
    /// so the library never describes a body that isn't on disk.
    private var persistedMeta: [UUID: NoteMeta] = [:]
    /// Bodies whose last write attempt failed.
    private var failedBodies: Set<UUID> = []
    /// Notes whose body on disk may hold local edits not kept as a version yet. Unknown at launch, so
    /// every note starts here.
    private var unversionedLocalBodies: Set<UUID> = []
    /// Set once the app is terminating: failed bodies are then written to `recovery/` as a last resort.
    private var isTerminating = false
    /// Snapshots already written to `recovery/` (avoids duplicate copies across terminate-time flushes).
    private var recoveredSnapshots: [UUID: ObjectIdentifier] = [:]
    /// Bodies whose unreadable original could not be backed up, or whose body-extras sidecar is unreadable:
    /// never overwrite them.
    private var bodyWriteBlocked: Set<UUID> = []
    /// Why a readable body is read-only (`StoredBody.readOnlyReason`); shown like a load error.
    private var bodyReadOnlyReasons: [UUID: String] = [:]
    /// The extras of each loaded body, keyed by note ID (Task 4.1). Set from every body read (on an RTFD store from
    /// the body-extras sidecar) and from sync apply once its body is installed; passed to every body write; dropped
    /// when the note is purged. Written only via `setBodyExtras(_:for:)` and by NoteStore+BodyEdits.swift.
    var bodyExtras: [UUID: ContainerExtras] = [:]
    /// Test hook: stops every body write after that step and throws (see NoteStore+BodyExtras.swift).
    var bodyWriteInterruption: BodyWriteStep?
    /// Test hook: makes step 3 of the body-extras sidecar write fail.
    var failsBodyExtrasFinish = false
    /// Test hook: when set, `editBody` calls it instead of `history.record` to keep the current body.
    var recordVersionOverride: ((NSAttributedString, UUID) -> NoteVersion?)?
    /// Where the daily-note preferences live (foundations Task 4.6); tests pass their own suite.
    var preferences: UserDefaults = .standard
    /// Called with every body-extras problem that is logged while reading a sidecar.
    var bodyExtrasNoticeHandler: ((UUID, BodyExtrasNotice) -> Void)?
    /// Set when library.json was unreadable and could not be backed up: never overwrite it.
    private var libraryWriteBlocked = false
    /// Deleted notes whose bodies are moved to `.trash` once the library deletion is persisted.
    /// Mirrored to `tombstones.json`; an ID leaves it only once its body is gone AND a saved
    /// library.json is known not to list it, so an interrupted deletion is finished (not resurrected).
    private var pendingTrash: Set<UUID> = []
    /// Purged notes whose files (body, raw meta, sidecar, Version History) are not deleted yet.
    var notesAwaitingFileDeletion: Set<UUID> { pendingTrash }
    /// Note IDs in library.json as last read or written; nil when unknown (missing/unreadable/unsaved).
    private(set) var libraryNoteIDsOnDisk: Set<UUID>?
    /// Notebook IDs in library.json as last read or written; nil when unknown.
    private(set) var libraryNotebookIDsOnDisk: Set<UUID>?
    /// The revision of the last remote meta applied per record, saved in library.json (see NoteStore+RawMeta).
    var appliedRemoteRevisions = AppliedRemoteRevisions()
    /// Raw meta files of removed records (other than notes), deleted once the removal is saved; mirrored to
    /// `sync-meta-raw/pending-deletions.json` with the tombstones.
    var rawMetaDeletionQueue: [RawMetaKind: Set<UUID>] = [:]
    /// Registered derived indexes in registration order (Task 4.4). Appended only by `registerDerivedIndex`.
    var derivedIndexes: [DerivedIndex] = []
    /// Note the user is currently typing in; selection reconciliation won't yank it.
    private var editingNoteID: UUID?
    /// Local deletions not yet pushed by sync, mirrored to `sync-deletions.json`.
    private(set) var syncDeletionJournal: [UUID: LocalDeletion] = [:]
    /// A user mutation happened since the last save; the save posts `noteItLocalChange`.
    private var hasUnannouncedLocalChange = false

    /// A library at `rootURL` that may be seeded if empty (self-tests, scratch stores).
    convenience init(rootURL: URL) {
        self.init(location: LibraryLocation(url: rootURL, seedsFreshLibrary: true))
    }

    /// `bodyStorage` nil: `RTFDBodyStorage(rootURL:)`. Tests pass another storage.
    init(location: LibraryLocation, bodyStorage: NoteBodyStorage? = nil) {
        rootURL = location.url
        self.bodyStorage = bodyStorage ?? RTFDBodyStorage(rootURL: location.url)
        seedsFreshLibrary = location.seedsFreshLibrary
        history = VersionHistory(rootURL: location.url.appendingPathComponent("history", isDirectory: true))
        searchIndexer = OrganiseIndexer(fileURL: location.url.appendingPathComponent(OrganiseIndexer.fileName))
        searchIndexer.store = self
        registerDerivedIndex(searchIndexer)
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

    private static var resolvedDefaultLocation: LibraryLocation?

    /// Settles the library location, migration included, before SwiftUI builds any scene: asking
    /// Inkwell to quit shows a modal alert, which mustn't run inside a SwiftUI update.
    static func prepareDefaultLocation() {
        _ = defaultLocation()
    }

    /// Resolved once per launch by `LibraryLauncher`. If the user chose to quit NoteIt rather than
    /// Inkwell, the process exits here, before anything is opened or written.
    static func defaultLocation() -> LibraryLocation {
        if let resolvedDefaultLocation { return resolvedDefaultLocation }
        guard let location = LibraryLauncher.live.launch(open: { $0 }, quit: { exit(0) }) else { exit(0) }
        resolvedDefaultLocation = location
        return location
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
        guard let id, let index = noteIndex(id) else { return nil }
        return notes[index]
    }

    func noteIndex(_ id: UUID) -> Int? {
        let current = notes
        if let i = noteIndexByID[id], i < current.count, current[i].id == id { return i }
        if noteIndexVersion == notesVersion { return nil }
        noteIndexByID = Dictionary(current.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        noteIndexVersion = notesVersion
        return noteIndexByID[id]
    }

    /// Pinned first, then most recently updated.
    func notes(for selection: SidebarSelection?, search: String) -> [NoteMeta] {
        searchResults(for: selection, search: search, order: .dateEdited, decorated: false).map(\.note)
    }

    func count(for selection: SidebarSelection) -> Int {
        LibraryQuery.count(notes, for: selection, now: Date())
    }

    /// Unique tags (lowercased, without `#`) across notes not in Recently Deleted, sorted.
    var allTags: [String] {
        Array(Set(activeNotes.flatMap(\.tags))).sorted()
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
        var loaded = NSAttributedString()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let stored = try readStoredBody(id)
                loaded = stored.text
                setBodyExtras(stored.extras, for: id)
                if let reason = stored.readOnlyReason { blockBodyWrites(id, reason: reason) }
            } catch {
                handleUnreadableBody(id, at: url, error: error)
            }
        }
        bodyCache[id] = loaded
        touchBody(id)
        if loadErrors[id] == nil, let meta = note(with: id) {
            searchIndexer.indexIfMissing(meta, body: loaded)
        }
        trimBodyCache()
        return loaded
    }

    func plainText(for id: UUID) -> String {
        BodyCodec.plainText(of: body(for: id))
    }

    /// Non-nil when the note's body file exists but could not be read. The original was backed up
    /// (unless the message says otherwise) and the note opens empty.
    func loadError(for id: UUID) -> String? {
        loadErrors[id] ?? bodyReadOnlyReasons[id]
    }

    /// True when the note's body file couldn't be read, so it loaded as empty (not for a read-only reason).
    func hasUnreadableBody(_ id: UUID) -> Bool {
        loadErrors[id] != nil
    }

    /// True while the note has edits not yet written to its body file.
    func isBodyDirty(_ id: UUID) -> Bool {
        dirtyBodies.contains(id)
    }

    /// The backup of an unreadable body (or the original, if it couldn't be backed up).
    func loadErrorFile(for id: UUID) -> URL? {
        loadErrorFiles[id]
    }

    /// True when edits to the note can't be saved (its unreadable original couldn't be backed up).
    func isBodyWriteBlocked(_ id: UUID) -> Bool {
        bodyWriteBlocked.contains(id)
    }

    /// Stores a local edit. A non-nil `extras` replaces `bodyExtras[id]` in the same body write (only NoteStore's own
    /// code passes it); a change of extras alone is a stored change too.
    func updateBody(_ id: UUID, _ text: NSAttributedString, extras: ContainerExtras? = nil) {
        // A direct commit is newer than any snapshot still waiting for its turn.
        stagedEditorBodies[id] = nil
        // Notes in Recently Deleted are read-only.
        guard let index = noteIndex(id), notes[index].deletedAt == nil else { return }
        let textUnchanged = body(for: id).isEqual(to: text)
        let extrasChanged = extras.map { $0 != (bodyExtras[id] ?? .empty) } ?? false
        if textUnchanged, !extrasChanged { return }
        if let extras, extrasChanged { setBodyExtras(extras, for: id) }

        let snapshot = text.copy() as? NSAttributedString ?? NSAttributedString(attributedString: text)
        bodyCache[id] = snapshot
        touchBody(id)
        dirtyBodies.insert(id)
        editingNoteID = id

        var meta = notes[index]
        Self.applyDerivedFields(to: &meta, from: snapshot)
        meta.updatedAt = Date()
        meta.revision = UUID()
        meta.conflictSource = nil
        meta.conflictOriginalID = nil
        notes[index] = meta
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        dispatchDerivedIndexes(.changed(meta, snapshot))
        postLocalNoteChange(id, .edited)
    }

    /// For editor commits made inside a SwiftUI view update. Sync calls `commitStagedEditorBody` before it
    /// compares revisions, so a snapshot still waiting for its turn can never be overwritten by a pull.
    func stageEditorCommit(_ id: UUID, _ snapshot: NSAttributedString) {
        stagedEditorBodies[id] = snapshot
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { _ = self?.commitStagedEditorBody(id) }
        }
    }

    @discardableResult
    func commitStagedEditorBody(_ id: UUID) -> Bool {
        guard let snapshot = stagedEditorBodies.removeValue(forKey: id) else { return false }
        commitEditorBody(id, snapshot)
        return true
    }

    /// `updateBody` for the editor's own commits; reports a changed title on `editorTitleCommits`.
    func commitEditorBody(_ id: UUID, _ snapshot: NSAttributedString) {
        let before = note(with: id)?.title
        updateBody(id, snapshot)
        guard !savingProgrammaticEdit else { return }
        if let after = note(with: id)?.title, after != before { editorTitleCommits.send((id, after)) }
    }

    func hasStagedEditorBody(_ id: UUID) -> Bool {
        stagedEditorBodies[id] != nil
    }

    #if DEBUG
    var debugCachedBodyCount: Int { bodyCache.count }
    func markSearchIndexDirtyForDebug() { searchIndexer.markDirty() }
    #endif

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
        let backup = Self.uniqueURL(url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(Self.timestamp())"))
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            loadErrorFiles[id] = backup
            loadErrors[id] = "This note couldn’t be read (\(error.localizedDescription)). The original was backed up to \(backup.lastPathComponent)."
            NSLog("NoteIt: failed to read note \(id) (\(error)); backed up to \(backup.path)")
        } catch let copyError {
            bodyWriteBlocked.insert(id)
            loadErrorFiles[id] = url
            loadErrors[id] = "This note couldn’t be read (\(error.localizedDescription)) or backed up; edits to it won’t be saved."
            NSLog("NoteIt: failed to read note \(id) (\(error)) and to back it up (\(copyError)); writes disabled")
        }
        // body(for:) can run during a view update; publish the error on the next turn.
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    /// A readable body that must not be overwritten (its body-extras sidecar is unreadable). Nothing is deleted.
    private func blockBodyWrites(_ id: UUID, reason: String) {
        guard !bodyWriteBlocked.contains(id) || bodyReadOnlyReasons[id] == nil else { return }
        bodyWriteBlocked.insert(id)
        bodyReadOnlyReasons[id] = reason
        if loadErrorFiles[id] == nil { loadErrorFiles[id] = bodyExtrasFileURL(id) }
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: - Search index

    nonisolated static func fold(_ string: String) -> String { TextFold.fold(string) }

    /// The folded search text of `ids` that have one; locked notes are left out.
    func foldedSearchText(of ids: [UUID]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for id in ids {
            guard let text = searchIndexer.text(for: id), note(with: id)?.isLocked == false else { continue }
            result[id] = text
        }
        return result
    }

    /// Indexes notes lacking a (fresh) search entry and rebuilds every other registered derived index.
    func scheduleIndexRebuild() {
        rebuildDerivedIndexes()
    }

    /// The search indexer merged rebuilt entries: refresh lists and save them.
    func searchIndexDidRebuild() {
        objectWillChange.send()
        scheduleSave()
    }

    /// Saves the (rebuildable) search index if anything changed; sync calls this once per pass.
    func saveSearchIndexIfDirty() {
        indexSaveWorkItem?.cancel()
        indexSaveWorkItem = nil
        searchIndexer.flush()
    }

    /// Coalesces index saves during a burst of remote applies.
    private func scheduleIndexSave(after delay: TimeInterval = 3) {
        guard indexSaveWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSearchIndexIfDirty() }
        }
        indexSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Notes

    @discardableResult
    /// An `id` already used by a note, live or in Recently Deleted, is replaced by a new one.
    func createNote(in notebookID: UUID?, initial: NSAttributedString? = nil, postsLocalChange: Bool = true,
                    id: UUID? = nil) -> NoteMeta {
        let now = Date()
        let body = initial ?? NSAttributedString()
        var meta = NoteMeta(
            id: id.flatMap { note(with: $0) == nil ? $0 : nil } ?? UUID(),
            notebookID: notebookID,
            title: "",
            preview: "",
            isPinned: false,
            createdAt: now,
            updatedAt: now,
            tags: [],
            revision: UUID()
        )
        Self.applyDerivedFields(to: &meta, from: body)
        bodyCache[meta.id] = body
        touchBody(meta.id)
        dirtyBodies.insert(meta.id)
        notes.append(meta)
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        dispatchDerivedIndexes(.changed(meta, body))
        if postsLocalChange { postLocalNoteChange(meta.id, .created) }
        return meta
    }

    /// Creates a note in the notebook implied by the current sidebar selection and selects it.
    @discardableResult
    func createNoteInCurrentContext(initial: NSAttributedString? = nil) -> NoteMeta {
        let notebookID = prepareCurrentContextForNewNote()
        let template = initial == nil ? defaultTemplateID(for: notebookID) : nil
        let meta = template.map { createNote(fromTemplate: $0, title: "", in: notebookID) }
            ?? createNote(in: notebookID, initial: initial)
        selectedNoteID = meta.id
        return meta
    }

    /// The selected notebook, if any; leaves a selection the new note would be hidden in, and clears the search.
    func prepareCurrentContextForNewNote() -> UUID? {
        var notebookID: UUID?
        switch selection {
        case .notebook(let id):
            notebookID = id
        case .pinned, .conflicts, .recentlyDeleted, .tag, .none:
            selection = .allNotes
        case .allNotes, .recent, .today, .tasks, .smartFolder:
            break
        }
        searchText = ""
        return notebookID
    }

    /// Persists the metadata removal first, then moves the body into `.trash` (never deleted outright).
    func deleteNote(_ id: UUID) {
        deleteNotes([id])
    }

    /// Removes notes for good like `deleteNote`, journaling and saving once for all of them.
    func deleteNotes(_ ids: [UUID]) {
        var seen = Set<UUID>()
        let existing = ids.filter { note(with: $0) != nil && seen.insert($0).inserted }
        guard !existing.isEmpty else { return }
        journalSyncDeletions(existing, kind: .note)
        hasUnannouncedLocalChange = true
        removeNotes(existing)
    }

    /// Shared by local and remote deletions (only local ones are journaled). Remote removals skip the
    /// search-index save (see `persistRemoteApply`).
    func removeNote(_ id: UUID, remote: Bool = false) {
        removeNotes([id], remote: remote)
    }

    private func removeNotes(_ ids: [UUID], remote: Bool = false) {
        let removed = Set(ids.filter { noteIndex($0) != nil })
        guard !removed.isEmpty else { return }
        if let selected = selectedNoteID, removed.contains(selected) { selectNeighbor(of: selected, skipping: removed) }
        notes.removeAll { removed.contains($0.id) }
        for id in removed {
            stagedEditorBodies[id] = nil
            bodyCache[id] = nil
            dirtyBodies.remove(id)
            loadErrors[id] = nil
            loadErrorFiles[id] = nil
            failedBodies.remove(id)
            unversionedLocalBodies.remove(id)
            setBodyExtras(nil, for: id)
            bodyReadOnlyReasons[id] = nil
            appliedRemoteRevisions.notes[id.uuidString] = nil
            pendingTrash.insert(id)
            dispatchDerivedIndexes(.removed(id))
        }
        bodyAccessOrder.removeAll { removed.contains($0) }
        saveTombstones()
        resolveConflictCopies(of: removed, remote: remote)
        libraryDirty = true
        if remote { persistRemoteApply() } else { flush() }
        reconcileSelection()
    }

    /// Moves the selection to the next (or else previous) note in the visible list.
    func selectNeighbor(of id: UUID, skipping skipped: Set<UUID> = []) {
        let visible = notes(for: selection, search: searchText)
        guard let pos = visible.firstIndex(where: { $0.id == id }) else {
            selectedNoteID = nil
            return
        }
        let after = visible[(pos + 1)...].first { !skipped.contains($0.id) }
        let before = visible[..<pos].last { !skipped.contains($0.id) }
        selectedNoteID = (after ?? before)?.id
    }

    /// An open editor and any staged snapshot commit their edits now, before the note becomes read-only.
    func handOverPendingEdits(_ id: UUID) {
        NotificationCenter.default.post(name: .noteItSyncWillApplyRemote, object: id)
        commitStagedEditorBody(id)
    }

    /// Saves a user change to note metadata; syncs like any edit.
    func commitUserMetadataChange() {
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        reconcileSelectionAfterUserAction()
    }

    /// Conflict copies of a deleted note no longer conflict with anything. A local deletion is a user change;
    /// a remote one only updates this Mac (the deleting Mac pushes the cleared copies).
    private func resolveConflictCopies(of ids: Set<UUID>, remote: Bool) {
        for i in notes.indices where notes[i].conflictSource != nil {
            guard let original = notes[i].conflictOriginalID, ids.contains(original) else { continue }
            notes[i].conflictSource = nil
            notes[i].conflictOriginalID = nil
            if !remote {
                notes[i].revision = UUID()
                hasUnannouncedLocalChange = true
            }
            dispatchDerivedIndexes(.metadata(notes[i]))
        }
    }

    /// Clears a note's conflict badge; syncs as a normal edit.
    func markConflictResolved(_ id: UUID) {
        guard let index = noteIndex(id), notes[index].conflictSource != nil else { return }
        notes[index].conflictSource = nil
        notes[index].conflictOriginalID = nil
        notes[index].revision = UUID()
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        dispatchDerivedIndexes(.metadata(notes[index]))
        reconcileSelectionAfterUserAction()
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].deletedAt == nil else { return }
        notes[index].isPinned.toggle()
        notes[index].revision = UUID()
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        dispatchDerivedIndexes(.metadata(notes[index]))
        reconcileSelectionAfterUserAction()
    }

    func moveNote(_ id: UUID, to notebookID: UUID?) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].deletedAt == nil,
              notes[index].notebookID != notebookID else { return }
        notes[index].notebookID = notebookID
        notes[index].revision = UUID()
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        dispatchDerivedIndexes(.metadata(notes[index]))
        reconcileSelectionAfterUserAction()
    }

    func reconcileSelectionAfterUserAction() {
        guard !isLoading else { return }
        editingNoteID = nil
        reconcileSelection()
    }

    // MARK: - Notebooks

    @discardableResult
    func createNotebook(name: String, symbol: String, colorHex: String) -> Notebook {
        let nextIndex = (notebooks.map(\.sortIndex).max() ?? -1) + 1
        let notebook = Notebook(id: UUID(), name: name, symbol: symbol, colorHex: colorHex, sortIndex: nextIndex,
                                revision: UUID(), modifiedAt: Date())
        notebooks.append(notebook)
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        return notebook
    }

    func updateNotebook(_ nb: Notebook) {
        guard let index = notebooks.firstIndex(where: { $0.id == nb.id }) else { return }
        var updated = nb
        updated.revision = notebooks[index].revision
        updated.modifiedAt = notebooks[index].modifiedAt
        guard updated != notebooks[index] else { return }
        updated.revision = UUID()
        updated.modifiedAt = Date()
        notebooks[index] = updated
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
    }

    /// Deletes the notebook and moves its notes to Recently Deleted. They keep the notebook ID, so
    /// recovering them falls back to Inbox.
    func deleteNotebook(_ id: UUID, at date: Date = Date()) {
        let affected = notes.filter { $0.notebookID == id && $0.deletedAt == nil }.map(\.id)
        for noteID in affected { handOverPendingEdits(noteID) }
        if notebook(with: id) != nil {
            journalSyncDeletion(id, kind: .notebook)
            appliedRemoteRevisions.notebooks[id.uuidString] = nil
            queueRawMetaDeletion(id, kind: .notebooks)
        }
        notebooks.removeAll { $0.id == id }
        for index in notes.indices where notes[index].notebookID == id && notes[index].deletedAt == nil {
            notes[index].deletedAt = date
            notes[index].revision = UUID()
            dispatchDerivedIndexes(.metadata(notes[index]))
        }
        if selection == .notebook(id) { selection = .allNotes }
        reindexNotebooks(sortedNotebooks)
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        reconcileSelectionAfterUserAction()
    }

    /// Offsets refer to `sortedNotebooks` order.
    func moveNotebooks(from source: IndexSet, to destination: Int) {
        var ordered = sortedNotebooks
        ordered.move(fromOffsets: source, toOffset: destination)
        reindexNotebooks(ordered)
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
    }

    /// Notebooks whose position changes get a new revision.
    private func reindexNotebooks(_ ordered: [Notebook]) {
        let now = Date()
        notebooks = ordered.enumerated().map { offset, nb in
            var copy = nb
            if copy.sortIndex != offset {
                copy.sortIndex = offset
                copy.revision = UUID()
                copy.modifiedAt = now
            }
            return copy
        }
    }

    // MARK: - Derived fields

    nonisolated static func applyDerivedFields(to meta: inout NoteMeta, from string: String) {
        applyTitleAndPreview(to: &meta, from: string)
        meta.tags = parseTags(string)
    }

    /// Like the string variant, but ignores hashtags inside code (monospaced) and links.
    nonisolated static func applyDerivedFields(to meta: inout NoteMeta, from text: NSAttributedString) {
        applyTitleAndPreview(to: &meta, lines: previewLines(of: text))
        meta.tags = parseTags(text)
    }

    /// Paragraphs as display lines, with each table collapsed into one line: cells of a row joined
    /// by " · ", rows by two spaces, and a header row (shaded or bold) left out.
    nonisolated static func previewLines(of text: NSAttributedString) -> [String] {
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

    nonisolated private static func applyTitleAndPreview(to meta: inout NoteMeta, from string: String) {
        applyTitleAndPreview(to: &meta, lines: string.components(separatedBy: .newlines))
    }

    nonisolated private static func applyTitleAndPreview(to meta: inout NoteMeta, lines: [String]) {
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

    /// Trims whitespace and invisible characters (attachment glyphs, list markers' tabs, pasted control characters).
    nonisolated private static func clean(_ line: String) -> String {
        let visible = line.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\t", with: " ")
            .unicodeScalars.filter { $0.properties.generalCategory != .control }
        return String(String.UnicodeScalarView(visible))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func parseTags(_ string: String) -> [String] {
        TokenGrammar.tags(inMasked: string.precomposedStringWithCanonicalMapping)
    }

    nonisolated static func parseTags(_ text: NSAttributedString) -> [String] {
        parseTags(maskedForTokens(text))
    }

    /// The text with code (monospaced font) and link ranges blanked out, keeping UTF-16 offsets intact; tags, due
    /// dates and reminders are read from it.
    nonisolated static func maskedForTokens(_ text: NSAttributedString) -> String {
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
        return masked as String
    }

    // MARK: - Persistence

    nonisolated func bodyURL(for id: UUID) -> URL {
        bodyStorage.fileURL(for: id)
    }

    nonisolated static var encoder: JSONEncoder { LibraryCoding.encoder }
    nonisolated static var decoder: JSONDecoder { LibraryCoding.decoder }

    /// Kept for VersionHistory and tests; forwards to RTFDBodyStorage.
    nonisolated static func readBody(at url: URL) throws -> NSAttributedString {
        try RTFDBodyStorage.readBody(at: url)
    }

    nonisolated private static func timestamp() -> String {
        RTFDBodyStorage.timestamp()
    }

    nonisolated private static func uniqueURL(_ url: URL) -> URL {
        RTFDBodyStorage.uniqueURL(url)
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let fm = FileManager.default
        try? fm.createDirectory(at: notesURL, withIntermediateDirectories: true)
        // Tombstoned notes are filtered from the library below; their bodies are trashed by flush()
        // only after a library save (or the library just read) confirms they're gone.
        loadTombstones()
        loadRawMetaDeletionQueue()
        loadSyncDeletionJournal()

        if fm.fileExists(atPath: libraryURL.path) {
            var data: Data?
            do {
                let raw = try Data(contentsOf: libraryURL)
                data = raw
                let library = try LibraryCoding.decode(raw)
                notebooks = library.notebooks
                notes = library.notes
                appliedRemoteRevisions = library.appliedRemoteRevisions ?? AppliedRemoteRevisions()
                libraryNoteIDsOnDisk = Set(library.notes.map(\.id))
                libraryNotebookIDsOnDisk = Set(library.notebooks.map(\.id))
                let undeleted = Set(notes.map(\.id).filter(tombstoned))
                if !undeleted.isEmpty {
                    // A deletion whose library save didn't land: complete it (tombstones stay until it's saved).
                    notes.removeAll { undeleted.contains($0.id) }
                    libraryDirty = true
                    debugCrashPoint("after-library-filter")
                }
                markInitialized()
                finishLoad()
                if libraryDirty || hasPendingAuxDeletions { flush() }
                return
            } catch {
                NSLog("NoteIt: failed to read library.json (\(error))")
                backUpUnreadableLibrary()
                let partial = data.flatMap(LibraryCoding.salvage)
                rebuildFromBodies(recovered: partial)
                libraryDirty = true
                markInitialized()
                finishLoad()
                flush()
                return
            }
        }

        if !bodyStorage.idsOnDisk().isEmpty {
            NSLog("NoteIt: library.json missing; rebuilding from note bodies")
            rebuildFromBodies(recovered: nil)
        } else if seedsFreshLibrary, !fm.fileExists(atPath: firstLaunchMarkerURL.path) {
            SeedData.seed(into: self)
            recordSeedManifest()
        }
        libraryDirty = true
        markInitialized()
        finishLoad()
        flush()
    }

    private func finishLoad() {
        for meta in notes { persistedMeta[meta.id] = meta }
        unversionedLocalBodies = Set(notes.map(\.id))
        searchIndexer.load(notes: notes)
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
            NSLog("NoteIt: backed up unreadable library.json to \(backup.path)")
        } catch {
            libraryWriteBlocked = true
            NSLog("NoteIt: could not back up unreadable library.json (\(error)); it will not be overwritten")
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
        for id in bodyStorage.idsOnDisk() where !tombstoned(id) {
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
            if let text = try? bodyStorage.read(id).text {
                Self.applyDerivedFields(to: &meta, from: text)
                searchIndexer.noteChanged(meta, body: text)
            } else {
                meta.title = "Recovered Note"
            }
            rebuilt.append(meta)
        }
        notes = rebuilt
        NSLog("NoteIt: rebuilt library with \(rebuilt.count) note(s) from bodies")
    }

    func scheduleSave(after delay: TimeInterval = 0.5) {
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
        for id in Array(stagedEditorBodies.keys) { commitStagedEditorBody(id) }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: notesURL, withIntermediateDirectories: true)

        for id in dirtyBodies {
            if bodyWriteBlocked.contains(id) {
                NSLog("NoteIt: not saving note \(id): its files on disk couldn’t be read and are kept as they are")
                continue
            }
            writePendingBody(id)
        }

        if libraryDirty || !fm.fileExists(atPath: libraryURL.path) {
            saveLibrary()
        }
        // Bodies (and raw meta files) of deleted records go only once their removal is persisted.
        if !libraryDirty, hasPendingAuxDeletions { trashPendingBodies() }
        indexSaveWorkItem?.cancel()
        indexSaveWorkItem = nil
        if isTerminating { writeRecoveryCopies() }
        dispatchDerivedIndexes(.flush)
        trimBodyCache()
        if hasUnannouncedLocalChange, !libraryDirty {
            hasUnannouncedLocalChange = false
            NotificationCenter.default.post(name: .noteItLocalChange, object: self)
        }

        let retryable = dirtyBodies.subtracting(bodyWriteBlocked)
        if !retryable.isEmpty || libraryDirty || hasPendingAuxDeletions {
            scheduleSave(after: 5)
        }
    }

    /// flush's and persistNow's per-note body write: keeps a version of the saved body, then writes the cached text
    /// with its extras (on an RTFD store through the two-phase body-extras sidecar). Returns false when it failed;
    /// the note then stays dirty and is retried.
    @discardableResult
    private func writePendingBody(_ id: UUID) -> Bool {
        guard let text = bodyCache[id], let meta = note(with: id) else {
            dirtyBodies.remove(id)
            recoveredSnapshots[id] = nil
            return true
        }
        do {
            history.recordSavedBody(at: bodyURL(for: id), extras: savedBodyVersionEntry(id), of: id)
            let extras = bodyExtras[id] ?? .empty
            let temp = try bodyStorage.prepareTemp(text, extras: extras, meta: meta)
            try installPreparedBody(temp, text: text, extras: extras, for: meta)
            dirtyBodies.remove(id)
            recoveredSnapshots[id] = nil
            unversionedLocalBodies.insert(id)
            if failedBodies.remove(id) != nil {
                // The library and index held back this note's new metadata/text; persist them now.
                libraryDirty = true
                searchIndexer.markDirty()
            }
            // A library save while the body was dirty wrote this note's old metadata.
            if persistedMeta[id] != meta { libraryDirty = true }
            return true
        } catch {
            let episodeStart = failedBodies.insert(id).inserted
            NSLog("NoteIt: failed to save note \(id): \(error)")
            if case BodyExtrasError.unreadableSidecar = error {
                blockBodyWrites(id, reason: StoredBody.bodyExtrasUnreadable)
            }
            // A note with no body on disk has nothing to fall back on: keep a copy right away
            // (once per failure episode) instead of only at quit.
            if episodeStart, !FileManager.default.fileExists(atPath: bodyURL(for: id).path) {
                writeRecoveryCopy(id, text)
            }
            return false
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
            copy.revision = old.revision
            return copy
        }
        let noteKeys = Set(persisted.map(\.id.uuidString))
        let notebookKeys = Set(notebooks.map(\.id.uuidString))
        var applied = appliedRemoteRevisions
        applied.notes = applied.notes.filter { noteKeys.contains($0.key) }
        applied.notebooks = applied.notebooks.filter { notebookKeys.contains($0.key) }
        do {
            let file = LibraryFile(version: 1, notebooks: notebooks, notes: persisted,
                                   appliedRemoteRevisions: applied.isEmpty ? nil : applied)
            let data = try Self.encoder.encode(file)
            try data.write(to: libraryURL, options: .atomic)
            appliedRemoteRevisions = applied
            persistedMeta = Dictionary(persisted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            libraryNoteIDsOnDisk = Set(persisted.map(\.id))
            libraryNotebookIDsOnDisk = Set(notebooks.map(\.id))
            libraryDirty = false
            debugCrashPoint("after-library-save")
            return true
        } catch {
            NSLog("NoteIt: failed to save library: \(error)")
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
            let url = try bodyStorage.recoveryCopy(text, for: id, in: recoveryURL)
            recoveredSnapshots[id] = ObjectIdentifier(text)
            NSLog("NoteIt: note \(id) couldn’t be saved; wrote a recovery copy to \(url.path)")
        } catch {
            NSLog("NoteIt: note \(id) couldn’t be saved, and writing a recovery copy failed too: \(error)")
        }
    }

    /// Moves tombstoned bodies to `.trash` and deletes their raw meta, body-extras files and Version History, then drops tombstones
    /// whose files are gone and which the saved library.json is known not to list. Also drains the raw meta
    /// deletion queue of other record kinds.
    private func trashPendingBodies() {
        let before = pendingTrash
        for id in pendingTrash {
            do {
                try bodyStorage.moveToTrash(id)
            } catch {
                NSLog("NoteIt: failed to move deleted note \(id) to trash: \(error)")
                continue
            }
            guard let listed = libraryNoteIDsOnDisk, !listed.contains(id) else { continue }
            do {
                try removeRawMetaFile(id, kind: .notes)
            } catch {
                NSLog("NoteIt: failed to delete the sync meta copy of deleted note \(id): \(error)")
                continue
            }
            do {
                try removeBodyExtrasFile(id)
            } catch {
                NSLog("NoteIt: failed to delete the body-extras file of deleted note \(id): \(error)")
                continue
            }
            do {
                try history.deleteHistory(of: id)
            } catch {
                NSLog("NoteIt: failed to delete the version history of deleted note \(id): \(error)")
                continue
            }
            pendingTrash.remove(id)
        }
        debugCrashPoint("after-trash")
        if pendingTrash != before { saveTombstones() }
        drainRawMetaDeletionQueue()
    }

    /// Records that still owe a deletion on disk after their removal is saved.
    private var hasPendingAuxDeletions: Bool {
        !pendingTrash.isEmpty || !rawMetaDeletionQueue.isEmpty
    }

    // MARK: Tombstones

    private func tombstoned(_ id: UUID) -> Bool {
        pendingTrash.contains(id)
    }

    private func loadTombstones() {
        guard let data = try? Data(contentsOf: tombstonesURL) else { return }
        guard let ids = try? Self.decoder.decode([UUID].self, from: data) else {
            NSLog("NoteIt: tombstones.json is unreadable; ignoring it")
            return
        }
        pendingTrash.formUnion(ids)
    }

    /// Debug-only crash simulation: `NOTEIT_STORE_CRASHPOINT=<name>` exits immediately (no further
    /// saves, no terminate handlers) when execution reaches that point.
    private func debugCrashPoint(_ name: String) {
        #if DEBUG
        guard AppEnvironment.value("STORE_CRASHPOINT") == name else { return }
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
            NSLog("NoteIt: failed to save tombstones: \(error)")
        }
        saveRawMetaDeletionQueue()
    }

    // MARK: - Sync support

    enum SyncApplyError: Error {
        case bodyWriteBlocked(UUID)
    }

    /// Gives records created before sync existed a revision and persists it. Not a user change.
    func assignMissingRevisions() {
        let inputs = missingRevisionInputs()
        guard !inputs.isEmpty else { return }
        assignRevisions(Self.contentRevisions(for: inputs), inputs: inputs)
    }

    /// What a missing revision is derived from: identical records on two Macs (a copied library) get equal
    /// revisions, so the first sync adopts them instead of producing conflict copies.
    struct RevisionInput: Sendable {
        var id: UUID
        var fields: [String]
        var bodyURL: URL?
    }

    /// The revision input of one note still lacking a revision, or nil.
    func missingRevisionInput(forNote id: UUID) -> RevisionInput? {
        guard let meta = note(with: id), meta.revision == nil else { return nil }
        return RevisionInput(id: id, fields: Self.revisionFields(meta), bodyURL: bodyStorage.revisionInputURL(for: id))
    }

    func missingRevisionInputs() -> [RevisionInput] {
        let noteInputs = notes.filter { $0.revision == nil }.map { meta in
            RevisionInput(id: meta.id, fields: Self.revisionFields(meta), bodyURL: bodyStorage.revisionInputURL(for: meta.id))
        }
        let notebookInputs = notebooks.filter { $0.revision == nil }.map { nb in
            RevisionInput(id: nb.id, fields: Self.revisionFields(nb), bodyURL: nil)
        }
        return noteInputs + notebookInputs
    }

    /// Sets revisions computed by `contentRevisions` on records still lacking one and unchanged since.
    func assignRevisions(_ revisions: [UUID: UUID], inputs: [RevisionInput]) {
        let expected = Dictionary(inputs.map { ($0.id, $0.fields) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for i in notes.indices where notes[i].revision == nil {
            guard expected[notes[i].id] == Self.revisionFields(notes[i]), let revision = revisions[notes[i].id] else { continue }
            notes[i].revision = revision
            changed = true
        }
        for i in notebooks.indices where notebooks[i].revision == nil {
            guard expected[notebooks[i].id] == Self.revisionFields(notebooks[i]), let revision = revisions[notebooks[i].id] else { continue }
            notebooks[i].revision = revision
            changed = true
        }
        guard changed else { return }
        libraryDirty = true
        flush()
    }

    nonisolated private static func revisionFields(_ meta: NoteMeta) -> [String] {
        var fields = ["note", meta.title, meta.notebookID?.uuidString ?? "", meta.isPinned ? "pinned" : ""]
        // Appended only when set, so revisions derived before Recently Deleted existed stay the same.
        if let deletedAt = meta.deletedAt { fields.append("deleted \(deletedAt.timeIntervalSince1970)") }
        if let lock = meta.lock { fields.append("lock \(lock.keyID) \(lock.sealedID.uuidString)") }
        return fields
    }

    nonisolated static func revisionFields(_ nb: Notebook) -> [String] {
        let fields = ["notebook", nb.name, nb.symbol, nb.colorHex, String(nb.sortIndex)]
        guard let template = nb.defaultTemplateID else { return fields }
        return fields + ["template \(template.uuidString)"]
    }

    /// SHA-256 over the id, the stable fields and the body package's files (sorted by path), as a v8 UUID.
    nonisolated static func contentRevisions(for inputs: [RevisionInput]) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for input in inputs {
            var hasher = SHA256()
            func feed(_ data: Data) {
                var length = UInt64(data.count).bigEndian
                hasher.update(data: Data(bytes: &length, count: 8))
                hasher.update(data: data)
            }
            feed(Data(RemoteLayout.revisionHashSeed.utf8))
            feed(withUnsafeBytes(of: input.id.uuid) { Data($0) })
            for field in input.fields { feed(Data(field.utf8)) }
            if let url = input.bodyURL {
                for (path, data) in bodyPackageFiles(url) {
                    feed(Data(path.utf8))
                    feed(data)
                }
            }
            var bytes = Array(hasher.finalize().prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x80
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            result[input.id] = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        return result
    }

    nonisolated private static func bodyPackageFiles(_ url: URL) -> [(String, Data)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [("", (try? Data(contentsOf: url)) ?? Data())] }
        let base = url.standardizedFileURL.path
        var files: [(String, Data)] = []
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = String(item.standardizedFileURL.path.dropFirst(base.count))
            files.append((path, (try? Data(contentsOf: item)) ?? Data()))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    /// A remote note decoded, parsed and written to a temp package off the main actor; see `applyPreparedRemoteNote`.
    struct PreparedRemoteNote: @unchecked Sendable {
        var meta: NoteMeta
        var body: NSAttributedString
        var searchEntry: SearchIndexEntry
        var tempBody: URL
        /// The incoming body's extras (`.empty` for an RTFD body); written with it, and kept in `bodyExtras` once
        /// it is installed.
        var extras: ContainerExtras = .empty
        /// The body came as RTFD, which carries no front matter: the note's current unknown keys are kept.
        var bodyIsRTFD: Bool
        /// The extras `tempBody` was written with. For an RTFD body on a non-RTFD store, they hold the unknown keys
        /// read from the note's file when it was prepared.
        var tempExtras: ContainerExtras = .empty
        /// The decrypted meta, kept in sync-meta-raw/ so fields this build doesn't know survive a re-export.
        var rawMeta: RawMeta
        /// The body on disk differs from the incoming one, so it may be kept as a version before being replaced.
        var replacesDifferentBody = false

        func discard() {
            try? FileManager.default.removeItem(at: tempBody)
        }
    }

    nonisolated static func prepareRemoteNote(_ payload: RecordPayload, storage: NoteBodyStorage,
                                              extras: ContainerExtras = .empty,
                                              bodyIsRTFD: Bool = true) throws -> PreparedRemoteNote {
        var meta = try decodeMeta(NoteMeta.self, payload)
        meta.revision = payload.revision
        guard let data = payload.body else { throw NoteStoreSyncError.missingBody(payload.id) }
        let body = try deserializeBody(data)
        applyDerivedFields(to: &meta, from: body)
        var tempExtras = extras
        if bodyIsRTFD, storage.kind != .rtfd {
            tempExtras.frontMatter = (try? BodyCodec.markdownFrontMatterExtra(at: storage.fileURL(for: payload.id))) ?? nil
        }
        let temp = try storage.prepareTemp(body, extras: tempExtras, meta: meta)
        var replaces = false
        if FileManager.default.fileExists(atPath: storage.fileURL(for: payload.id).path) {
            replaces = (try? storage.read(payload.id)).map { !$0.text.isEqual(to: body) } ?? true
        }
        return PreparedRemoteNote(meta: meta, body: body, searchEntry: OrganiseIndexer.makeEntry(body, updatedAt: meta.updatedAt), tempBody: temp, extras: extras,
                                  bodyIsRTFD: bodyIsRTFD, tempExtras: tempExtras,
                                  rawMeta: RawMeta(sourceRevision: payload.revision, meta: payload.meta),
                                  replacesDifferentBody: replaces)
    }

    /// Inserts or replaces a note from sync, keeping its revision. The prepared body package is swapped in
    /// first; nothing changes in memory if that fails. library.json is saved before returning; the search
    /// index is saved later (it is rebuildable).
    func applyPreparedRemoteNote(_ prepared: PreparedRemoteNote) throws {
        var prepared = prepared
        let id = prepared.meta.id
        if bodyWriteBlocked.contains(id) {
            prepared.discard()
            throw SyncApplyError.bodyWriteBlocked(id)
        }
        // An RTFD body carries no front matter, so the unknown keys stay on this Mac (spec §3.3). Other stores read
        // them from the file while preparing; only keys changed in memory since then need a rebuilt temp.
        var extras = prepared.extras
        if prepared.bodyIsRTFD {
            extras.frontMatter = bodyStorage.kind == .rtfd ? storedFrontMatter(id)
                : bodyExtras[id].map(\.frontMatter) ?? prepared.tempExtras.frontMatter
        }
        if bodyStorage.kind != .rtfd, extras != prepared.tempExtras {
            do {
                let temp = try bodyStorage.prepareTemp(prepared.body, extras: extras, meta: prepared.meta)
                prepared.discard()
                prepared.tempBody = temp
            } catch {
                prepared.discard()
                throw error
            }
        }
        // The raw copy goes first; if it can't be written the record isn't applied, and the next pass retries.
        do {
            try setLastRemoteMeta(prepared.rawMeta, for: id, kind: .notes)
        } catch {
            prepared.discard()
            throw error
        }
        if prepared.replacesDifferentBody {
            history.recordSavedBody(at: bodyURL(for: id), extras: savedBodyVersionEntry(id), of: id,
                                    force: unversionedLocalBodies.contains(id))
        }
        do {
            try installPreparedBody(prepared.tempBody, text: prepared.body, extras: extras, for: prepared.meta)
        } catch {
            prepared.discard()
            throw error
        }
        setBodyExtras(extras, for: id)
        if prepared.replacesDifferentBody { unversionedLocalBodies.remove(id) }
        let wasTombstoned = pendingTrash.remove(id) != nil

        stagedEditorBodies[id] = nil
        if bodyCache[id] != nil || selectedNoteID == id {
            bodyCache[id] = prepared.body
            touchBody(id)
        }
        dirtyBodies.remove(id)
        failedBodies.remove(id)
        recoveredSnapshots[id] = nil
        loadErrors[id] = nil
        loadErrorFiles[id] = nil
        bodyReadOnlyReasons[id] = nil
        if let index = noteIndex(id) {
            notes[index] = prepared.meta
        } else {
            notes.append(prepared.meta)
        }
        if !prepared.meta.isLocked { searchIndexer.prime(id, body: prepared.body, entry: prepared.searchEntry) }
        dispatchDerivedIndexes(.changed(prepared.meta, prepared.body))
        appliedRemoteRevisions.notes[id.uuidString] = prepared.rawMeta.sourceRevision
        clearSyncDeletion(id)
        libraryDirty = true
        persistRemoteApply()
        // The tombstone goes only after a library listing the note is saved (see trashPendingBodies).
        if wasTombstoned { saveTombstones() }
        externallyUpdatedNoteID = id
        if selectedNoteID == nil { reconcileSelection() }
    }

    /// `remote.revision` is recorded as applied; its raw meta must already be written (see `applyRemote`).
    func applyRemoteNotebook(_ remote: Notebook) {
        if let index = notebooks.firstIndex(where: { $0.id == remote.id }) {
            notebooks[index] = remote
        } else {
            notebooks.append(remote)
        }
        appliedRemoteRevisions.notebooks[remote.id.uuidString] = remote.revision
        clearSyncDeletion(remote.id)
        libraryDirty = true
        persistRemoteApply()
    }

    /// Removes a notebook deleted on another device. Its notes move to "no notebook" without new revisions;
    /// deleted ones keep the notebook ID, so recovering them falls back to Inbox.
    func removeNotebookForRemote(_ id: UUID) {
        clearSyncDeletion(id)
        guard notebook(with: id) != nil else { return }
        notebooks.removeAll { $0.id == id }
        appliedRemoteRevisions.notebooks[id.uuidString] = nil
        queueRawMetaDeletion(id, kind: .notebooks)
        for index in notes.indices where notes[index].notebookID == id && notes[index].deletedAt == nil {
            notes[index].notebookID = nil
            dispatchDerivedIndexes(.metadata(notes[index]))
        }
        libraryDirty = true
        persistRemoteApply()
        if selection == .notebook(id) {
            selection = .allNotes
            reconcileSelection()
        }
    }

    /// True while library.json lags behind memory (its last save failed); sync must not record a base then.
    var hasUnsavedLibrary: Bool { libraryDirty }

    /// Durable part of a remote apply: library.json (plus deferred trash moves). Pending user edits keep
    /// their own debounced save; the search index save is coalesced.
    private func persistRemoteApply() {
        if libraryDirty || !FileManager.default.fileExists(atPath: libraryURL.path) { saveLibrary() }
        if !libraryDirty, hasPendingAuxDeletions { trashPendingBodies() }
        if searchIndexer.isDirty { scheduleIndexSave() }
        trimBodyCache()
        if libraryDirty, saveWorkItem == nil { scheduleSave(after: 5) }
    }

    /// Body to export without loading it into the cache: the cached (possibly unsaved) text, or the file.
    enum ExportBody: @unchecked Sendable {
        case text(NSAttributedString)
        case file(URL)
    }

    func exportBodySource(_ id: UUID) -> ExportBody {
        if let cached = bodyCache[id] {
            return .text(cached.copy() as? NSAttributedString ?? NSAttributedString(attributedString: cached))
        }
        return .file(bodyStorage.fileURL(for: id))
    }

    /// Adjusts metadata of a note just created by sync (e.g. a conflict copy); counts as a local change.
    func updateSyncCreatedNote(_ id: UUID, _ change: (inout NoteMeta) -> Void) {
        guard let index = noteIndex(id) else { return }
        change(&notes[index])
        dispatchDerivedIndexes(.metadata(notes[index]))
        libraryDirty = true
        hasUnannouncedLocalChange = true
        flush()
    }

    private struct SyncDeletionEntry: Codable {
        var kind: RecordKind
        var deletedAt: Date
    }

    private func journalSyncDeletion(_ id: UUID, kind: RecordKind) {
        journalSyncDeletions([id], kind: kind)
    }

    private func journalSyncDeletions(_ ids: [UUID], kind: RecordKind) {
        guard Self.syncJournalEnabled, !ids.isEmpty else { return }
        let date = Date()
        for id in ids { syncDeletionJournal[id] = LocalDeletion(kind: kind, deletedAt: date) }
        saveSyncDeletionJournal()
    }

    func clearSyncDeletion(_ id: UUID) {
        guard syncDeletionJournal.removeValue(forKey: id) != nil else { return }
        saveSyncDeletionJournal()
    }

    func clearAllSyncDeletions() {
        syncDeletionJournal = [:]
        saveSyncDeletionJournal()
    }

    private func loadSyncDeletionJournal() {
        guard let data = try? Data(contentsOf: syncDeletionsURL) else { return }
        guard let entries = try? Self.decoder.decode([String: SyncDeletionEntry].self, from: data) else {
            NSLog("NoteIt: sync-deletions.json is unreadable; ignoring it")
            return
        }
        for (key, entry) in entries {
            guard let id = UUID(uuidString: key) else { continue }
            syncDeletionJournal[id] = LocalDeletion(kind: entry.kind, deletedAt: entry.deletedAt)
        }
    }

    private func saveSyncDeletionJournal() {
        do {
            if syncDeletionJournal.isEmpty {
                if FileManager.default.fileExists(atPath: syncDeletionsURL.path) {
                    try FileManager.default.removeItem(at: syncDeletionsURL)
                }
            } else {
                let entries = Dictionary(uniqueKeysWithValues: syncDeletionJournal.map {
                    ($0.key.uuidString, SyncDeletionEntry(kind: $0.value.kind, deletedAt: $0.value.deletedAt))
                })
                try Self.encoder.encode(entries).write(to: syncDeletionsURL, options: .atomic)
            }
        } catch {
            NSLog("NoteIt: failed to save sync deletions: \(error)")
        }
    }

    /// Kept for VersionHistory and tests; forwards to RTFDBodyStorage.
    nonisolated static func writeTempBody(_ text: NSAttributedString, in directory: URL) throws -> URL {
        try RTFDBodyStorage.writeTempBody(text, in: directory)
    }

    /// Kept for VersionHistory and tests; forwards to RTFDBodyStorage.
    nonisolated static func installBody(_ temp: URL, at url: URL) throws {
        try RTFDBodyStorage.installBody(temp, at: url)
    }
}

/// Why `persistNow` couldn't make the note durable. Owned by the foundations plan (Task 4.1; program §6).
enum PersistNowError: Error, Equatable {
    case noteMissing, writeBlocked, bodyNotSaved, libraryNotSaved
}

extension NoteStore {
    /// Synchronously writes this note's pending body (through flush's per-note step, so on an RTFD store with its
    /// two-phase sidecar) and then library.json, and returns only after both are installed by atomic rename.
    /// Throws PersistNowError on any failure; the note then stays pending and the next flush retries it.
    /// Other notes, the search index and pending trash moves are left to the scheduled flush. For capture paths
    /// that remove their source once the note is on disk (foundations Task 4.1; program §6).
    func persistNow(_ id: UUID) throws {
        commitStagedEditorBody(id)
        guard note(with: id) != nil else { throw PersistNowError.noteMissing }
        if dirtyBodies.contains(id) {
            if bodyWriteBlocked.contains(id) { throw PersistNowError.writeBlocked }
            try? FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
            guard writePendingBody(id) else { throw PersistNowError.bodyNotSaved }
        }
        if libraryDirty || !FileManager.default.fileExists(atPath: libraryURL.path) {
            guard saveLibrary() else { throw PersistNowError.libraryNotSaved }
        }
    }
}
