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
        didSet {
            if selectedNoteID != editingNoteID { editingNoteID = nil }
            if selectedNoteID != oldValue, markdownStorage != nil { markdownSelectionChanged(from: oldValue) }
        }
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
    var tagTreeCache: (notesVersion: Int, tree: [TagNode])?
    var notebookTreeCache: (notebooksVersion: Int, tree: NotebookTree)?
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
    private var recoveredSnapshots: [UUID: WeakSnapshot] = [:]
    /// Bodies whose unreadable original could not be backed up, or whose body-extras sidecar is unreadable:
    /// never overwrite them.
    private var bodyWriteBlocked: Set<UUID> = []
    /// While set, `updateBody` dates the edit with it instead of now (a file edited outside NoteIt).
    var externalEditDate: Date?
    /// The idle rename's clock; tests inject one.
    var markdownClock: () -> Date = Date.init
    var hasPendingMarkdownRenames = false
    var markdownScanRunning = false
    var markdownScanAgain = false
    /// Callers waiting for a scan that starts after they asked and is applied; true when it was.
    var markdownScanWaiters: [(Bool) -> Void] = []
    /// **Move to Recently Deleted** was chosen; the next scan that is applied deletes the held notes still missing.
    var markdownConfirmingHeldDeletions = false
    /// How a rescan reads the content folder; tests inject one that hangs like a dead network volume.
    var markdownFolderScan: @Sendable (URL, MarkdownPathIndex, WriteLedger) -> FolderScanResult = {
        FolderScanner.scan(contentRoot: $0, index: $1, ledger: $2)
    }
    /// A rescan that takes longer means the folder is unavailable; notes are then read-only until it responds.
    var markdownScanTimeout: TimeInterval = 20
    var markdownUnavailableRetryInterval: TimeInterval = 15
    /// How long a note whose Markdown file failed to read waits before a view's `body(for:)` reads it again.
    var markdownFailedReadRetryInterval: TimeInterval = 15
    /// When a note whose file failed to read may be read again; until then `body(for:)` doesn't touch the file.
    private var markdownFailedReadRetryAt: [UUID: Date] = [:]
    /// Notes whose Markdown file was missing when read (with no held body): never cached as empty, so neither a
    /// later sync pass nor an edit treats nothing as their text; read again after the same pause as a failed read.
    private var markdownMissingRetryAt: [UUID: Date] = [:]
    /// The path each of those notes was missing at: once the note's entry points elsewhere (moved, or its last text
    /// put in `.trash/` when the scan removed it) it's read again at once.
    private var markdownMissingPaths: [UUID: String] = [:]
    private enum MarkdownPlaceholder { case lastKnown, failed, missing }
    /// What `body(for:)` last gave instead of a note's text; an editor showing it is reloaded once that changes,
    /// whichever caller took the read that changed it.
    private var markdownPlaceholdersGiven: [UUID: MarkdownPlaceholder] = [:]
    var markdownUnavailableRetryScheduled = false
    /// Set while the content folder doesn't respond (a network volume that hangs): the editor is read-only and
    /// nothing is read from or written to the folder.
    @Published var markdownFolderUnavailable = false
    /// The library opened from `library.json` and the first scan of the content folder hasn't come back yet; the
    /// folder counts as unavailable meanwhile.
    @Published var markdownFolderChecking = false
    /// Until the first scan is applied, a scan applies with launch semantics (new files take ids right away).
    var markdownLaunchScanPending = false
    /// The first scan reads every changed file, so it may take longer than a rescan.
    var markdownLaunchScanTimeout: TimeInterval = 60
    /// The scan running off the main thread, if any.
    var markdownScanJob: MarkdownIOJob?
    var markdownWatcher: MarkdownFolderWatcher?
    /// The app asked for the watcher; it starts after the first scan that succeeds.
    var markdownWatchWanted = false
    var markdownWatcherStarting: MarkdownFolderWatcher?
    var attachmentSweepTimer: Timer?
    /// Called once when the content folder goes away while the library is open; the app asks the user to locate it.
    var onMarkdownFolderMissing: ((URL) -> Void)?
    var markdownFolderReportedMissing = false
    /// Every write, folder change, listing and deletion in a Markdown library's content folder runs here, in order;
    /// the main thread only queues work and applies results (`MarkdownIOJob`).
    let markdownIO = DispatchQueue(label: "NoteIt.markdown-io", qos: .userInitiated)
    var markdownIOJobs: [MarkdownIOJob] = []
    /// A flush came while a write pass was queued; it runs again once that pass is applied.
    var markdownFlushAgain = false
    /// A background scan came back while writes were queued; it runs again once they are applied.
    var markdownScanAfterWrites = false
    /// IO queued this long without finishing makes the folder unavailable.
    var markdownWriteTimeout: TimeInterval = 20
    /// How long a caller that needs the folder right now (a sync apply, a capture's `persistNow`, a read) waits.
    var markdownBlockingTimeout: TimeInterval = 5
    /// How long `flush()` waits for its Markdown writes. 0 in the app, where the main thread never waits for the
    /// folder; tests and the self-test wait. A flush at quit waits `markdownQuitWait` either way.
    var markdownFlushWait: TimeInterval = 0
    var markdownQuitWait: TimeInterval = 5
    /// Recovery copies of edits waiting for an unavailable folder, one per note, removed once the edit is written.
    var markdownWaitingCopies: [UUID: URL] = [:]
    /// Every `recovery/` copy of a Markdown note made (or restored) this session, removed once a newer body is written.
    private var markdownRecoveryCopies: [UUID: [URL]] = [:]
    /// Notes whose body couldn't be read because the folder didn't answer; they are read again once it does.
    var markdownBodiesNotRead: Set<UUID> = [] {
        didSet { if markdownBodiesNotRead != oldValue { publishMarkdownBodiesNotRead() } }
    }
    private var markdownBodiesNotReadPublishScheduled = false
    /// The longest `body(for:)` waits for a note's file; a slower read goes on off the main thread and the note shows
    /// as loading until it ends (up to `markdownBlockingTimeout`).
    var markdownBodyMainWait: TimeInterval = 1
    /// Reads of note files still running, or ended and not yet taken, by note.
    private var markdownReads: [UUID: MarkdownReadJob] = [:]
    /// Notes not read because another note's read was still running; they are offered again when it ends.
    private var markdownReadsDeferred: Set<UUID> = []
    /// Notes shown as loading: `body(for:)` stopped waiting for their file, or it waits for another note's read.
    @Published private(set) var markdownBodiesLoading: Set<UUID> = []
    /// Notes the launch scan changed, added or removed; persistent indexes (Spotlight) that start after it update
    /// these rather than trust what they kept from the last run.
    var notesChangedBeforeDerivedIndexes: Set<UUID> = []
    /// Called when the mass-deletion guard holds a batch, with the number of held notes.
    var onManyNotesDisappeared: ((Int) -> Void)?
    /// Called with a message when a template couldn't be used because its file wasn't read; nothing was created.
    var onTemplateNotRead: ((String) -> Void)?
    /// New files wait until they have been unchanged this long before they become notes (spec §3.5).
    var newFileSettleDelay: TimeInterval = 2
    /// Notes whose files disappeared in a batch the mass-deletion guard holds.
    var heldMarkdownDeletions: Set<UUID> = [] {
        didSet { markdownStorage?.setKeepsMissingFolders(!heldMarkdownDeletions.isEmpty) }
    }
    /// Why a readable body is read-only (`StoredBody.readOnlyReason`); shown like a load error.
    private var bodyReadOnlyReasons: [UUID: String] = [:]
    private var bodySaveNotices: [UUID: String] = [:]
    /// Bodies that failed to save because of an attachment over 25 MB; not tried again until the body changes.
    private var oversizedBodies: [UUID: WeakSnapshot] = [:]
    /// The extras of each loaded body, keyed by note ID (Task 4.1). Set from every body read (on an RTFD store from
    /// the body-extras sidecar) and from sync apply once its body is installed; passed to every body write; dropped
    /// when the note is purged. Written only via `setBodyExtras(_:for:)` and by NoteStore+BodyEdits.swift.
    var bodyExtras: [UUID: ContainerExtras] = [:]
    /// Set while a library conversion runs: the editor is read-only and shows "Converting your library…".
    @Published var libraryConversionInProgress = false
    /// Set once a conversion has switched the library: this store never writes to disk again.
    private(set) var isClosedForLibrarySwitch = false
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
    /// Sidebar saved searches, kept in `smart-folders.json` (see NoteStore+SmartFolders).
    @Published private(set) var smartFolders: [SmartFolder] = [] {
        didSet { smartFoldersVersion &+= 1 }
    }
    private(set) var smartFoldersVersion = 0
    var smartFolderState = SmartFolderState()
    /// A user mutation happened since the last save; the save posts `noteItLocalChange`.
    private var hasUnannouncedLocalChange = false

    /// A library at `rootURL` that may be seeded if empty (self-tests, scratch stores).
    convenience init(rootURL: URL) {
        self.init(location: LibraryLocation(url: rootURL, seedsFreshLibrary: true))
    }

    /// `bodyStorage` nil: `MarkdownBodyStorage` for a Markdown location, else `RTFDBodyStorage(rootURL:)`. Tests pass
    /// another storage.
    init(location: LibraryLocation, bodyStorage: NoteBodyStorage? = nil) {
        rootURL = location.url
        if let bodyStorage {
            self.bodyStorage = bodyStorage
        } else if location.format == .markdown, let content = location.contentRootURL {
            self.bodyStorage = MarkdownBodyStorage(contentRoot: content, dataDir: location.url,
                                                   renameFilesOnTitleChange: location.renameFilesOnTitleChange)
        } else {
            self.bodyStorage = RTFDBodyStorage(rootURL: location.url)
        }
        seedsFreshLibrary = location.seedsFreshLibrary && self.bodyStorage.kind == .rtfd
        history = VersionHistory(rootURL: location.url.appendingPathComponent("history", isDirectory: true),
                                 format: self.bodyStorage.kind == .rtfd ? .rtfd : .noteItDoc)
        searchIndexer = OrganiseIndexer(fileURL: location.url.appendingPathComponent(OrganiseIndexer.fileName))
        searchIndexer.store = self
        registerDerivedIndex(searchIndexer)
        load()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushBeforeQuit()
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

    /// Every notebook in sidebar order: each one followed by the notebooks inside it.
    var sortedNotebooks: [Notebook] {
        notebookTree.flattened(expanded: nil).compactMap { notebook(with: $0.id) }
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
        if case .smartFolder = selection { return notes(for: selection, search: "").count }
        return LibraryQuery.count(notes, for: selection, now: Date(), notebookScope: notebookIDsIncludingDescendants)
    }

    /// Unique tags (lowercased, without `#`) across notes not in Recently Deleted, sorted.
    var allTags: [String] {
        Array(Set(activeNotes.flatMap(\.tags))).sorted()
    }

    // MARK: - Selection

    /// Ensures `selectedNoteID` refers to a note in the visible list (current sidebar selection + search).
    /// Keeps the note the user is actively typing in, even if their edit hid it (e.g. removed its tag).
    func reconcileSelection() {
        if selection == .tasks {
            // The Tasks view lists lines, not notes: keep the note opened from it while it exists.
            if let id = selectedNoteID, note(with: id)?.deletedAt == nil, note(with: id) != nil { return }
            if selectedNoteID != nil { selectedNoteID = nil }
            return
        }
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
        body(for: id, wait: nil)
    }

    /// `wait` is how long the main thread waits for a Markdown read it starts (`markdownBodyMainWait` when nil).
    func body(for id: UUID, wait: TimeInterval?) -> NSAttributedString {
        if let cached = bodyCache[id] {
            touchBody(id)
            gaveMarkdownBody(id, nil)
            return cached
        }
        let url = bodyURL(for: id)
        var loaded = NSAttributedString()
        if let markdownStorage {
            var wait = wait
            if loadErrors[id] != nil, let retry = markdownFailedReadRetryAt[id] {
                // Views and indexes ask again and again; a failed file is read again only after a pause, a change
                // the scan saw, or Retry, and then without a main-thread wait.
                guard Date() >= retry else {
                    gaveMarkdownBody(id, .failed)
                    return NSAttributedString()
                }
                wait = 0
            }
            if markdownMissingRetryAt[id] != nil {
                guard !isWaitingToRetryMissingBody(id) else {
                    gaveMarkdownBody(id, .missing)
                    return NSAttributedString()
                }
                wait = 0
            }
            switch takeMarkdownRead(id, readMarkdownBody(id, from: markdownStorage, wait: wait), from: markdownStorage) {
            case .text(let text): loaded = text
            case .placeholder(let placeholder): return placeholder
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            do {
                let stored = try readStoredBody(id)
                loaded = stored.text
                setBodyExtras(stored.extras, for: id)
                if let reason = stored.readOnlyReason { blockBodyWrites(id, reason: reason) }
            } catch {
                handleUnreadableBody(id, at: url, error: error)
            }
        } else if let held = heldMarkdownBody(id) {
            loaded = held.text
            setBodyExtras(held.extras, for: id)
        }
        cacheLoadedBody(id, loaded)
        return loaded
    }

    private enum TakenMarkdownRead {
        /// The note's text, to cache.
        case text(NSAttributedString)
        /// Shown instead of the note's text; never cached, so never written or built on.
        case placeholder(NSAttributedString)
    }

    /// The state a read's outcome leaves the note in, the same for every caller that takes a read (`body(for:)`,
    /// sync's `exportBodySource`), since the read's own end does nothing once it was taken.
    private func takeMarkdownRead(_ id: UUID, _ outcome: MarkdownBodyRead, from storage: MarkdownBodyStorage) -> TakenMarkdownRead {
        switch outcome {
        case .read(let stored):
            clearUnreadableMarkdownBody(id)
            markdownMissingRetryAt[id] = nil
            setBodyExtras(stored.extras, for: id)
            if let reason = stored.readOnlyReason { blockBodyWrites(id, reason: reason) }
            return .text(stored.text)
        case .missing:
            clearUnreadableMarkdownBody(id)
            // A note whose body was never written has no file yet: it's empty, and its next write creates the file.
            guard storage.index.entry(id) != nil else {
                markdownMissingRetryAt[id] = nil
                return .text(NSAttributedString())
            }
            guard let held = heldMarkdownBody(id) else {
                // Shown empty and read-only until the file is back, or the scan this starts finds it gone and moves
                // the note to Recently Deleted with its last text.
                markdownMissingPaths[id] = storage.index.entry(id)?.path
                if markdownMissingRetryAt.updateValue(Date().addingTimeInterval(markdownFailedReadRetryInterval),
                                                      forKey: id) == nil {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.objectWillChange.send()
                            self?.markdownFolderNeedsScan()
                        }
                    }
                }
                gaveMarkdownBody(id, .missing)
                return .placeholder(NSAttributedString())
            }
            markdownMissingRetryAt[id] = nil
            setBodyExtras(held.extras, for: id)
            return .text(held.text)
        case .failed(let error):
            // Shown empty and read-only, never output or built on, and read again after a pause.
            handleUnreadableMarkdownBody(id, at: bodyURL(for: id), error: error)
            markdownFailedReadRetryAt[id] = Date().addingTimeInterval(markdownFailedReadRetryInterval)
            gaveMarkdownBody(id, .failed)
            return .placeholder(NSAttributedString())
        case .unanswered:
            // Shown as last known and read again once the folder answers.
            gaveMarkdownBody(id, .lastKnown)
            return .placeholder(storage.lastKnownBody(id)?.text ?? heldMarkdownBody(id)?.text ?? NSAttributedString())
        }
    }

    private func cacheLoadedBody(_ id: UUID, _ loaded: NSAttributedString) {
        bodyCache[id] = loaded
        touchBody(id)
        gaveMarkdownBody(id, nil)
        if loadErrors[id] == nil, let meta = note(with: id) {
            searchIndexer.indexIfMissing(meta, body: loaded)
        }
        trimBodyCache()
    }

    /// The content folder's name while the note's Markdown file hasn't been read (the folder is being checked or
    /// doesn't answer), so `body(for:)` only gave a placeholder that nothing may be built on; nil once it's read.
    func unreadMarkdownFolder(of id: UUID) -> String? {
        guard let markdownStorage, bodyCache[id] == nil, loadErrors[id] == nil, markdownMissingRetryAt[id] == nil else { return nil }
        return markdownStorage.contentRootURL.lastPathComponent
    }

    /// The note's body for export, print, copy, share or the API; nil while it's a placeholder for a file that
    /// wasn't read, which is never output as the note's content.
    func bodyForOutput(_ id: UUID) -> NSAttributedString? {
        bodyForOutput(id, wait: nil)
    }

    func bodyForOutput(_ id: UUID, wait: TimeInterval?) -> NSAttributedString? {
        let text = body(for: id, wait: wait)
        return bodyNotReadError(id) == nil ? text : nil
    }

    /// Why the note's body is only a placeholder: its Markdown file wasn't read yet (`folderNotAvailable`) or reading
    /// it failed (`writeBlocked`); nil when it's the note's content.
    func bodyNotReadError(_ id: UUID) -> BodyEditError? {
        if isMarkdownBodyMissing(id) { return .writeBlocked }
        if let folder = unreadMarkdownFolder(of: id) { return .folderNotAvailable(folder) }
        if markdownStorage != nil, loadErrors[id] != nil { return .writeBlocked }
        return nil
    }

    /// `bodyForOutput`, but while a read of the folder is still running (this note's or another's) it waits for it,
    /// suspended rather than blocking, and tries again: nil only once the read failed to answer or the folder is
    /// unavailable. Reads start without a main-thread wait; nil as soon as `isCancelled` says so.
    func bodyForOutputWhenRead(_ id: UUID, isCancelled: () -> Bool = { false }) async -> NSAttributedString? {
        let deadline = Date().addingTimeInterval(2 * markdownBlockingTimeout)
        while true {
            if let body = bodyForOutput(id, wait: 0) { return body }
            guard !isCancelled(), markdownStorage != nil, !markdownFolderUnavailable, Date() < deadline,
                  markdownReads[id] != nil || markdownReads.values.contains(where: { !$0.isFinished }) else { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func plainText(for id: UUID) -> String {
        BodyCodec.plainText(of: body(for: id))
    }

    /// Non-nil when the note's body file exists but could not be read. The original was backed up
    /// (unless the message says otherwise) and the note opens empty.
    /// Why the note's edits can't be saved yet, while it stays editable (an attachment over 25 MB).
    func bodySaveNotice(for id: UUID) -> String? { bodySaveNotices[id] }
    /// Bodies handed to the Markdown IO queue so far.
    private(set) var markdownBodyWritesStarted = 0

    static func attachmentTooLargeToSave(_ name: String) -> String {
        "“\(name)” is over 25 MB, so this note can’t be saved to its Markdown file. Remove it to save your changes; until then they’re kept in NoteIt’s recovery folder."
    }

    nonisolated static func attachmentTooLargeToSync(_ name: String) -> String {
        "“\(name)” is over 25 MB, so this note can’t be kept in this Markdown library. It syncs again once the attachment is removed on the other device."
    }

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

    /// Unsaved edits whose last write failed (an attachment over 25 MB, an error), or that wait for a Markdown
    /// folder that doesn't answer.
    func hasBodyThatCantBeSaved(_ id: UUID) -> Bool {
        dirtyBodies.contains(id) && (failedBodies.contains(id) || (markdownStorage != nil && markdownFolderUnavailable))
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
    /// `basedOnPlaceholder`: an editor's text that started from a placeholder (the last known text or nothing,
    /// shown while the file wasn't read), which is never saved, even once the file has been read.
    func updateBody(_ id: UUID, _ text: NSAttributedString, extras: ContainerExtras? = nil, basedOnPlaceholder: Bool = false) {
        // A direct commit is newer than any snapshot still waiting for its turn.
        stagedEditorBodies[id] = nil
        // Notes in Recently Deleted are read-only.
        guard let index = noteIndex(id), notes[index].deletedAt == nil else { return }
        guard !basedOnPlaceholder else { return refuseEditOnPlaceholder(id) }
        let textUnchanged = body(for: id).isEqual(to: text)
        if bodyNotReadError(id) != nil {
            NSLog("NoteIt: not changing note \(id): its Markdown file hasn't been read")
            return
        }
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
        meta.updatedAt = externalEditDate ?? Date()
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
    func stageEditorCommit(_ id: UUID, _ snapshot: NSAttributedString, basedOnPlaceholder: Bool = false) {
        guard !basedOnPlaceholder else { return refuseEditOnPlaceholder(id) }
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
    func commitEditorBody(_ id: UUID, _ snapshot: NSAttributedString, basedOnPlaceholder: Bool = false) {
        let before = note(with: id)?.title
        updateBody(id, snapshot, basedOnPlaceholder: basedOnPlaceholder)
        guard !savingProgrammaticEdit else { return }
        if let after = note(with: id)?.title, after != before { editorTitleCommits.send((id, after)) }
    }

    /// Whether the body `body(for:)` just gave is a placeholder rather than the note's text.
    func isShowingMarkdownPlaceholder(_ id: UUID) -> Bool {
        markdownStorage != nil && bodyCache[id] == nil
    }

    private func refuseEditOnPlaceholder(_ id: UUID) {
        NSLog("NoteIt: not saving an edit to note \(id) made before its Markdown file was read")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.externallyUpdatedNoteID = id }
        }
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

    enum MarkdownBodyRead {
        case read(StoredBody)
        case missing
        case failed(Error)
        /// The folder didn't answer within `markdownBlockingTimeout`, or is known not to.
        case unanswered
    }

    /// Reads a note's file off the main thread, waiting at most `wait` (default `markdownBodyMainWait`). A read
    /// that takes longer goes on, up to `markdownBlockingTimeout`; the note is `.unanswered` and shows as loading
    /// meanwhile, and the next call takes the ended read.
    func readMarkdownBody(_ id: UUID, from storage: MarkdownBodyStorage, wait: TimeInterval? = nil) -> MarkdownBodyRead {
        guard let entry = storage.index.entry(id) else { return .missing }
        guard !markdownFolderUnavailable else {
            markdownBodiesNotRead.insert(id)
            return .unanswered
        }
        let inFlight = markdownReads.filter { !$0.value.isFinished }
        // A read past its whole timeout whose end hasn't reached the main thread yet (a loop that never yields).
        if inFlight.values.contains(where: { $0.age > markdownBlockingTimeout })
            || markdownReads.values.contains(where: { $0.timedOut }) {
            markdownBodiesNotRead.insert(id)
            markdownFolderBecameUnavailable()
            return .unanswered
        }
        let job: MarkdownReadJob
        if let running = markdownReads[id], running.entry == entry {
            job = running
        } else {
            // The main thread waits for one read at a time, so a read still running outlived its wait: the folder
            // is slow or hung, and the next notes aren't read (or waited for) until it ends.
            let root = storage.contentRootURL.path
            guard inFlight.isEmpty,
                  let key = (0..<Self.markdownReadThreads).lazy.map({ "markdown-read:\(root):\($0)" })
                      .first(where: { !BoundedFileAccess.shared.isRunning($0) }) else {
                guard inFlight.isEmpty else {
                    deferMarkdownRead(id)
                    return .unanswered
                }
                // Both readers are held by reads that timed out and haven't ended: the folder isn't answering, and
                // it's tried again (a scan, then this read) until one ends.
                markdownBodiesNotRead.insert(id)
                markdownFolderBecameUnavailable()
                return .unanswered
            }
            job = MarkdownReadJob(entry: entry)
            markdownReads[id] = job
            // A small fixed set of keys: a dead mount holds at most that many threads, even after reads time out.
            BoundedFileAccess.shared.run(key: key, timeout: markdownBlockingTimeout, { () -> MarkdownBodyRead in
                guard let url = storage.revisionInputURL(for: id), FileManager.default.fileExists(atPath: url.path) else {
                    return .missing
                }
                do { return .read(try storage.read(id)) } catch { return .failed(error) }
            }, completion: { [weak self] outcome in
                job.finish(outcome)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.markdownReadEnded(id, job) } }
            })
        }
        // A read the main thread already waited for once isn't waited for again.
        let mainWait = job.waitedFor ? 0 : min(wait ?? markdownBodyMainWait, markdownBlockingTimeout)
        job.waitedFor = true
        guard job.wait(upTo: mainWait) else {
            // A read can run during a view update; publish on the next turn.
            if !markdownBodiesLoading.contains(id) {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.markdownReads[id] === job { self?.markdownBodiesLoading.insert(id) }
                    }
                }
            }
            return .unanswered
        }
        if markdownReads[id] === job { markdownReads[id] = nil }
        if !markdownReadsDeferred.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.readDeferredMarkdownBodies() }
        }
        if markdownBodiesLoading.contains(id) {
            DispatchQueue.main.async { [weak self] in self?.markdownBodiesLoading.remove(id) }
        }
        guard let outcome = job.outcome else {
            markdownBodiesNotRead.insert(id)
            DispatchQueue.main.async { [weak self] in self?.markdownFolderBecameUnavailable() }
            return .unanswered
        }
        markdownBodiesNotRead.remove(id)
        return outcome
    }

    static let markdownReadThreads = 2

    private func deferMarkdownRead(_ id: UUID) {
        markdownBodiesNotRead.insert(id)
        guard markdownReadsDeferred.insert(id).inserted else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.markdownReadsDeferred.contains(id) else { return }
                self.markdownBodiesLoading.insert(id)
            }
        }
    }

    /// Notes that waited for another read: once no read runs and a reader is free, the open one is read and the
    /// editor reloaded; the others stay unread until opened. While a read runs its end calls this again; with no
    /// reader free the folder isn't answering, and they wait for it to answer.
    func readDeferredMarkdownBodies() {
        guard !markdownReadsDeferred.isEmpty, !markdownFolderUnavailable else { return }
        guard let storage = markdownStorage else {
            markdownBodiesLoading.subtract(markdownReadsDeferred)
            markdownReadsDeferred = []
            return
        }
        guard !markdownReads.values.contains(where: { !$0.isFinished }) else { return }
        let root = storage.contentRootURL.path
        guard (0..<Self.markdownReadThreads).contains(where: { !BoundedFileAccess.shared.isRunning("markdown-read:\(root):\($0)") }) else {
            markdownFolderBecameUnavailable()
            return
        }
        let deferred = markdownReadsDeferred
        markdownReadsDeferred = []
        markdownBodiesLoading.subtract(deferred)
        guard let selected = selectedNoteID, deferred.contains(selected), cachedBody(selected) == nil,
              note(with: selected) != nil else { return }
        _ = body(for: selected)
        if cachedBody(selected) != nil { externallyUpdatedNoteID = selected }
    }

    /// The note shows a placeholder (its last known text, or nothing) because its file wasn't read: never editable.
    func isMarkdownBodyUnread(_ id: UUID) -> Bool {
        markdownBodiesNotRead.contains(id) && cachedBody(id) == nil
    }

    /// Views read `markdownBodiesNotRead` directly; this publishes a change on the next turn, as it can change
    /// during a view update.
    private func publishMarkdownBodiesNotRead() {
        guard !markdownBodiesNotReadPublishScheduled else { return }
        markdownBodiesNotReadPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.markdownBodiesNotReadPublishScheduled = false
                self.objectWillChange.send()
            }
        }
    }

    func isMarkdownBodyLoading(_ id: UUID) -> Bool {
        markdownBodiesLoading.contains(id)
    }

    /// A read `body(for:)` stopped waiting for ended: an editor showing the note gets it, a folder that didn't answer
    /// becomes unavailable. A read of a file that changed meanwhile is dropped.
    private func markdownReadEnded(_ id: UUID, _ job: MarkdownReadJob) {
        // Whichever read ended (or was taken already), notes waiting for one are read once a reader is free.
        defer { readDeferredMarkdownBodies() }
        let wasLoading = markdownBodiesLoading.remove(id) != nil
        guard markdownReads[id] === job else { return }
        markdownReads[id] = nil
        guard let outcome = job.outcome else {
            markdownBodiesNotRead.insert(id)
            markdownFolderBecameUnavailable()
            return
        }
        if case .unanswered = outcome { return }
        guard wasLoading, bodyCache[id] == nil, note(with: id) != nil, !markdownFolderUnavailable,
              let storage = markdownStorage, storage.index.entry(id) == job.entry else { return }
        markdownReads[id] = job
        _ = body(for: id)
        // Also after a failure, so editors drop the last known text; their reload doesn't read the file again
        // before markdownFailedReadRetryAt.
        externallyUpdatedNoteID = id
    }

    /// `placeholder` is what `body(for:)` gives for the note now (nil: its text). Called from every path that
    /// takes a read, so an editor still showing an earlier placeholder is reloaded on the next turn (it can be
    /// called during a view update).
    private func gaveMarkdownBody(_ id: UUID, _ placeholder: MarkdownPlaceholder?) {
        let earlier: MarkdownPlaceholder?
        if let placeholder {
            earlier = markdownPlaceholdersGiven.updateValue(placeholder, forKey: id)
        } else {
            earlier = markdownPlaceholdersGiven.removeValue(forKey: id)
        }
        guard let earlier, earlier != placeholder else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.selectedNoteID == id || OpenEditorRegistry.shared.textView(for: id) != nil
                    || OpenEditorRegistry.shared.hasObservers(for: id) else { return }
                self.externallyUpdatedNoteID = id
            }
        }
    }

    /// Retry in the load-error banner, or a change the scan saw: the next read of a note whose file failed to read
    /// happens now, off the main thread.
    func retryReadingBody(_ id: UUID) {
        if markdownMissingRetryAt[id] != nil {
            markdownMissingRetryAt[id] = .distantPast
        } else {
            guard loadErrors[id] != nil, markdownFailedReadRetryAt[id] != nil else { return }
            markdownFailedReadRetryAt[id] = .distantPast
        }
        guard selectedNoteID == id || OpenEditorRegistry.shared.textView(for: id) != nil
            || OpenEditorRegistry.shared.hasObservers(for: id) else { return }
        _ = body(for: id)
        externallyUpdatedNoteID = id
    }

    private func isWaitingToRetryMissingBody(_ id: UUID) -> Bool {
        guard let retry = markdownMissingRetryAt[id], Date() < retry else { return false }
        return markdownStorage?.index.entry(id)?.path == markdownMissingPaths[id]
    }

    /// The note's Markdown file was missing when last read: shown empty and read-only, never output or synced.
    func isMarkdownBodyMissing(_ id: UUID) -> Bool {
        markdownMissingRetryAt[id] != nil && bodyCache[id] == nil
    }

    func canRetryReadingBody(_ id: UUID) -> Bool {
        isMarkdownBodyMissing(id) || (markdownStorage != nil && loadErrors[id] != nil && markdownFailedReadRetryAt[id] != nil)
    }

    /// A Markdown file that exists but can't be read: shown empty and never written, so it needs no backup.
    private func handleUnreadableMarkdownBody(_ id: UUID, at url: URL, error: Error) {
        guard loadErrors[id] == nil else { return }
        bodyWriteBlocked.insert(id)
        loadErrorFiles[id] = url
        loadErrors[id] = "This note couldn’t be read (\(error.localizedDescription)); edits to it won’t be saved."
        NSLog("NoteIt: failed to read note \(id) (\(error)); writes disabled")
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    /// A body that must not be overwritten, shown read-only with `reason`.
    func blockMarkdownBodyWrites(_ id: UUID, reason: String) {
        blockBodyWrites(id, reason: reason)
    }

    /// A Markdown file that failed to read and has now been read (or is gone): the note is usable again.
    private func clearUnreadableMarkdownBody(_ id: UUID) {
        markdownFailedReadRetryAt[id] = nil
        guard loadErrors[id] != nil else { return }
        loadErrors[id] = nil
        loadErrorFiles[id] = nil
        if bodyReadOnlyReasons[id] == nil { bodyWriteBlocked.remove(id) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            if self.selectedNoteID == id, self.cachedBody(id) != nil { self.externallyUpdatedNoteID = id }
        }
    }

    /// Lets a note whose file came back be edited again.
    func unblockMarkdownBodyWrites(_ id: UUID, reason: String) {
        guard bodyReadOnlyReasons[id] == reason else { return }
        bodyWriteBlocked.remove(id)
        bodyReadOnlyReasons[id] = nil
        loadErrorFiles[id] = nil
        objectWillChange.send()
    }

    /// Edits not saved yet: a dirty body or an editor snapshot waiting for its turn.
    func hasUnsavedBody(_ id: UUID) -> Bool {
        dirtyBodies.contains(id) || stagedEditorBodies[id] != nil
    }

    func cachedBody(_ id: UUID) -> NSAttributedString? {
        bodyCache[id]
    }

    enum IndexText {
        case text(String?)
        /// The content folder didn't answer.
        case unavailable
    }

    /// A note's plain text for an index, read off the main thread when it isn't cached: never waits for the
    /// content folder on the main thread.
    func indexText(_ id: UUID) async -> IndexText {
        if let cached = cachedBody(id) { return .text(BodyCodec.plainText(of: cached)) }
        guard let meta = note(with: id), !meta.isLocked else { return .text(nil) }
        let storage = bodyStorage
        let read = { (try? storage.read(id)).map { BodyCodec.plainText(of: $0.text) } }
        guard let markdownStorage else { return .text(await Task.detached(priority: .utility) { read() }.value) }
        guard !markdownFolderUnavailable else { return .unavailable }
        guard let text = await BoundedFileAccess.shared.run(key: "markdown-index-read:" + markdownStorage.contentRootURL.path,
                                                            timeout: markdownScanTimeout, read) else { return .unavailable }
        return .text(text)
    }

    /// Puts `text` in the body cache as the saved body, when nothing is cached.
    func seedCachedBody(_ id: UUID, _ text: NSAttributedString) {
        guard bodyCache[id] == nil else { return }
        bodyCache[id] = text
        touchBody(id)
    }

    /// Keeps `text` as an unsaved body when nothing newer is cached, so the next write stores it.
    func keepUnsavedBody(_ id: UUID, _ text: NSAttributedString) {
        seedCachedBody(id, text)
        dirtyBodies.insert(id)
        scheduleSave()
    }

    /// Drops a clean cached body so the next read loads the file.
    func dropCachedBody(_ id: UUID) {
        guard !hasUnsavedBody(id) else { return }
        bodyCache[id] = nil
        bodyAccessOrder.removeAll { $0 == id }
    }

    /// Adds notes read from files at load or by the folder watcher; they are saved like any change.
    func addLoadedNotes(_ metas: [NoteMeta], bodies: [UUID: NSAttributedString]) {
        guard !metas.isEmpty else { return }
        notes.append(contentsOf: metas)
        for meta in metas {
            unversionedLocalBodies.insert(meta.id)
            if let text = bodies[meta.id] { dispatchDerivedIndexes(.changed(meta, text)) }
        }
        libraryDirty = true
        hasUnannouncedLocalChange = true
    }

    /// Notes moved, renamed or changed outside NoteIt in their metadata only: saved and announced like a user change.
    func commitOutsideMetadataChange() {
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
    }

    /// Keeps the saved body as a version before a write replaces it.
    private func recordSavedBodyVersion(_ id: UUID, force: Bool = false) {
        if bodyStorage.kind == .rtfd {
            history.recordSavedBody(at: bodyURL(for: id), extras: savedBodyVersionEntry(id), of: id, force: force)
        } else {
            // The body as NoteIt last read or wrote the file; nothing is read from the content folder here.
            history.recordSavedBody(reading: { [markdownStorage] in markdownStorage?.lastKnownBody(id) }, of: id, force: force)
        }
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
    /// Nil, and nothing created, when the notebook's template hasn't been read from its folder yet.
    @discardableResult
    func createNoteInCurrentContext(initial: NSAttributedString? = nil) -> NoteMeta? {
        let notebookID = prepareCurrentContextForNewNote()
        let template = initial == nil ? defaultTemplateID(for: notebookID) : nil
        let meta: NoteMeta
        do {
            meta = try template.map { template throws(BodyEditError) in try createNote(fromTemplate: template, title: "", in: notebookID) }
                ?? createNote(in: notebookID, initial: initial)
        } catch {
            reportTemplateNotRead(error)
            return nil
        }
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
            clearOversizedBody(id)
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

    /// The one way to change `smartFolders`. `local` marks a user edit that sync should push.
    func changeSmartFolders(local: Bool, _ change: (inout [SmartFolder]) -> Void) {
        change(&smartFolders)
        smartFolderState.dirty = true
        searchResultCache.removeAll()
        if local {
            hasUnannouncedLocalChange = true
            scheduleSave()
        }
    }

    /// Saves a user change to note metadata; syncs like any edit.
    /// A local notebook change: saves and lets sync know, without touching the note selection.
    func commitNotebookChange() {
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
    }

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
    func createNotebook(name: String, symbol: String, colorHex: String, parentID: UUID? = nil) -> Notebook {
        let parent = parentID.flatMap { notebookTree.depth(of: $0) < NotebookTree.maxDepth ? $0 : nil }
        let siblings = notebooks.filter { $0.parent == parent }
        let nextIndex = (siblings.map(\.sortIndex).max() ?? -1) + 1
        let notebook = Notebook(id: UUID(), name: name, symbol: symbol, colorHex: colorHex, sortIndex: nextIndex,
                                revision: UUID(), modifiedAt: Date(), parent: parent)
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
        let oldPath = notebookTree.path(of: nb.id)
        notebooks[index] = updated
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        rewriteSmartFoldersForNotebookRename(oldPath: oldPath, newPath: notebookTree.path(of: nb.id))
    }

    /// Deletes the notebook and its sub-notebooks and moves their notes to Recently Deleted. They keep the
    /// notebook ID, so recovering them falls back to Inbox.
    func deleteNotebook(_ id: UUID, at date: Date = Date()) {
        let tree = notebookTree
        let ids = tree.contains(id) ? notebookIDsIncludingDescendants(id) : [id]
        let parent = tree.effectiveParent(of: id)
        let affected = notes.filter { $0.notebookID.map(ids.contains) == true && $0.deletedAt == nil }.map(\.id)
        for noteID in affected { handOverPendingEdits(noteID) }
        for removed in ids where notebook(with: removed) != nil {
            journalSyncDeletion(removed, kind: .notebook)
            appliedRemoteRevisions.notebooks[removed.uuidString] = nil
            queueRawMetaDeletion(removed, kind: .notebooks)
        }
        notebooks.removeAll { ids.contains($0.id) }
        for index in notes.indices where notes[index].notebookID.map(ids.contains) == true && notes[index].deletedAt == nil {
            notes[index].deletedAt = date
            notes[index].revision = UUID()
            dispatchDerivedIndexes(.metadata(notes[index]))
        }
        if case .notebook(let selected) = selection, ids.contains(selected) { selection = .allNotes }
        reindexNotebooks(notebookTree.siblings(under: parent))
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
        reconcileSelectionAfterUserAction()
    }

    /// Reorders the children of `parent` (top level when nil); offsets refer to their display order.
    func moveNotebooks(from source: IndexSet, to destination: Int, parent: UUID? = nil) {
        var ordered = notebookTree.siblings(under: parent)
        ordered.move(fromOffsets: source, toOffset: destination)
        reindexNotebooks(ordered)
        libraryDirty = true
        hasUnannouncedLocalChange = true
        scheduleSave()
    }

    /// Numbers one sibling group in order; notebooks whose position changes get a new revision.
    func reindexNotebooks(_ ordered: [UUID], now: Date = Date()) {
        for (offset, id) in ordered.enumerated() {
            guard let index = notebooks.firstIndex(where: { $0.id == id }), notebooks[index].sortIndex != offset else { continue }
            notebooks[index].sortIndex = offset
            notebooks[index].revision = UUID()
            notebooks[index].modifiedAt = now
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
        try? fm.createDirectory(at: bodyStorage.kind == .rtfd ? notesURL : rootURL, withIntermediateDirectories: true)
        // Tombstoned notes are filtered from the library below; their bodies are trashed by flush()
        // only after a library save (or the library just read) confirms they're gone.
        loadTombstones()
        loadRawMetaDeletionQueue()
        loadSyncDeletionJournal()
        loadSmartFolders()

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
        if markdownStorage != nil { loadMarkdownFolder() }
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
        if markdownStorage != nil {
            // The folder scan at the end of the load adds every note file with its front matter and folder.
            notes = (recovered?.notes ?? []).filter { !tombstoned($0.id) }
            return
        }
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
        guard !isClosedForLibrarySwitch else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Writes all pending changes to disk. On an RTFD store synchronously; on a Markdown store the content folder's
    /// writes go to the IO queue and their results come back later (`markdownFlushWait`). Failed body writes stay
    /// dirty and are retried; meanwhile the library keeps their last persisted title/preview/date. At termination,
    /// bodies that still can't be saved are written to `recovery/` instead.
    func flush() {
        guard !isClosedForLibrarySwitch else { return }
        for id in Array(stagedEditorBodies.keys) { commitStagedEditorBody(id) }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let fm = FileManager.default
        var markdownPass: MarkdownWritePass?
        let wait = isTerminating ? markdownQuitWait : markdownFlushWait
        let waitDeadline = wait > 0 ? Date().addingTimeInterval(wait) : nil
        if let markdownStorage {
            markdownPass = planMarkdownWrites(markdownStorage, waitingUntil: waitDeadline)
        } else {
            try? fm.createDirectory(at: notesURL, withIntermediateDirectories: true)
            for id in dirtyBodies {
                if bodyWriteBlocked.contains(id) {
                    NSLog("NoteIt: not saving note \(id): its files on disk couldn’t be read and are kept as they are")
                    continue
                }
                writePendingBody(id)
            }
        }
        if libraryDirty || !fm.fileExists(atPath: libraryURL.path) {
            saveLibrary()
        }
        if smartFolderState.dirty { saveSmartFolders() }
        // Bodies (and raw meta files) of deleted records go only once their removal is persisted.
        if !libraryDirty, hasPendingAuxDeletions {
            if markdownPass != nil {
                markdownPass?.trash = Array(pendingTrash)
                drainRawMetaDeletionQueue()
            } else if markdownStorage == nil {
                trashPendingBodies()
            }
        }
        if let markdownStorage, let markdownPass {
            startMarkdownWritePass(markdownPass, on: markdownStorage, waitingUntil: waitDeadline)
        }
        indexSaveWorkItem?.cancel()
        indexSaveWorkItem = nil
        if isTerminating { writeRecoveryCopies() }
        dispatchDerivedIndexes(.flush)
        trimBodyCache()
        if hasUnannouncedLocalChange, !libraryDirty, !smartFolderState.dirty {
            hasUnannouncedLocalChange = false
            NotificationCenter.default.post(name: .noteItLocalChange, object: self)
        }
        scheduleRetryIfNeeded()
    }

    private func scheduleRetryIfNeeded() {
        guard !markdownWritePassQueued || !markdownFlushAgain else { return }
        let retryable = dirtyBodies.subtracting(bodyWriteBlocked).filter { !isWaitingForSmallerAttachment($0) }
        if !retryable.isEmpty || libraryDirty || smartFolderState.dirty || hasPendingAuxDeletions || hasPendingMarkdownRenames {
            scheduleSave(after: 5)
        }
    }

    // MARK: Markdown writes

    /// The writes a flush hands to the IO queue, or nil when none may start now: while the folder doesn't answer
    /// edits wait in memory (with a copy in `recovery/`), and while an earlier pass is queued the flush runs again
    /// after it.
    private func planMarkdownWrites(_ storage: MarkdownBodyStorage, waitingUntil deadline: Date?) -> MarkdownWritePass? {
        if let deadline {
            for job in markdownIOJobs { _ = job.wait(upTo: deadline.timeIntervalSinceNow) }
        }
        if markdownFolderUnavailable {
            for id in dirtyBodies.subtracting(bodyWriteBlocked) { keepWaitingCopy(id) }
            return nil
        }
        guard !markdownWritePassQueued else {
            markdownFlushAgain = true
            return nil
        }
        markdownFlushAgain = false
        var pass = MarkdownWritePass()
        for id in dirtyBodies {
            if bodyWriteBlocked.contains(id) {
                NSLog("NoteIt: not saving note \(id): its files on disk couldn’t be read and are kept as they are")
                continue
            }
            guard let text = bodyCache[id], let meta = note(with: id) else {
                dirtyBodies.remove(id)
                recoveredSnapshots[id] = nil
                continue
            }
            if isWaitingForSmallerAttachment(id) { continue }
            recordSavedBodyVersion(id)
            markdownBodyWritesStarted += 1
            pass.bodies.append(.init(meta: meta, text: text, extras: bodyExtras[id] ?? .empty, notebook: notebook(with: meta.notebookID)))
        }
        planMarkdownLayout(&pass)
        return pass
    }

    private func startMarkdownWritePass(_ pass: MarkdownWritePass, on storage: MarkdownBodyStorage, waitingUntil deadline: Date? = nil) {
        let job = enqueueMarkdownIO(storage, { pass.run(on: $0) }) { [weak self] result in
            self?.finishMarkdownWritePass(pass, result)
        }
        job.isWritePass = true
        if let deadline, job.wait(upTo: deadline.timeIntervalSinceNow), libraryDirty { saveLibrary() }
    }

    /// Flushes and waits up to `seconds` for the queued Markdown writes without blocking the main thread.
    func flushAndWaitForWrites(upTo seconds: TimeInterval) async {
        flush()
        let deadline = Date() + seconds
        while !markdownIOJobs.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// Waits up to `seconds` for the queued Markdown writes and applies their results.
    func waitForMarkdownWrites(upTo seconds: TimeInterval) {
        let deadline = Date() + seconds
        while let job = markdownIOJobs.first, job.wait(upTo: deadline.timeIntervalSinceNow), markdownIOJobs.first !== job {}
    }

    /// The app's last flush: waits at most `markdownQuitWait` for the content folder, then keeps whatever is still
    /// unsaved in `recovery/`.
    func flushBeforeQuit() {
        guard !isTerminating else { return }
        isTerminating = true
        flush()
    }

    /// Queues `work` on the IO queue; `apply` gets its result on the main thread. Work that doesn't finish within
    /// `markdownWriteTimeout` makes the folder unavailable, and its result is still applied when it comes.
    @discardableResult
    func enqueueMarkdownIO<T>(_ storage: MarkdownBodyStorage, _ work: @escaping (MarkdownBodyStorage) -> T,
                              then apply: @escaping (T) -> Void) -> MarkdownIOJob {
        let job = MarkdownIOJob()
        markdownIOJobs.append(job)
        nonisolated(unsafe) let work = work
        nonisolated(unsafe) let apply = apply
        markdownIO.async { [weak self] in
            let value = work(storage)
            job.finished {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.markdownIOJobs.removeAll { $0 === job }
                    apply(value)
                    self.markdownIOFinished()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + markdownWriteTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !job.isApplied, self.markdownStorage === storage else { return }
                self.markdownFolderBecameUnavailable()
            }
        }
        return job
    }

    /// Runs `work` on the IO queue and waits at most `markdownBlockingTimeout` for it, for callers that need the
    /// folder before they return. Throws `.unresponsive` at once while the folder doesn't answer.
    func runMarkdownIONow<T>(_ storage: MarkdownBodyStorage, _ work: @escaping (MarkdownBodyStorage) throws -> T) throws -> T {
        guard !markdownFolderUnavailable else { throw MarkdownStorageError.unresponsive }
        var outcome: Swift.Result<T, Error>?
        let job = enqueueMarkdownIO(storage, { storage in Swift.Result { try work(storage) } }) { outcome = $0 }
        guard job.wait(upTo: markdownBlockingTimeout), let outcome else {
            markdownFolderBecameUnavailable()
            throw MarkdownStorageError.unresponsive
        }
        return try outcome.get()
    }

    /// A flush's writes are queued; the next flush waits for them instead of queuing the same bodies again.
    private var markdownWritePassQueued: Bool { markdownIOJobs.contains { $0.isWritePass } }

    private func markdownIOFinished() {
        guard markdownIOJobs.isEmpty else { return }
        if markdownScanAfterWrites {
            markdownScanAfterWrites = false
            markdownFolderNeedsScan()
        }
        if markdownFlushAgain {
            markdownFlushAgain = false
            scheduleSave(after: 0.05)
        }
    }

    private func finishMarkdownWritePass(_ pass: MarkdownWritePass, _ result: MarkdownWritePass.Result) {
        guard !isClosedForLibrarySwitch else { return }
        for body in pass.bodies {
            if let error = result.failedBodies[body.meta.id] {
                bodyWriteFailed(body.meta.id, text: body.text, error: error)
            } else {
                bodyWritten(body.meta.id, text: body.text, extras: body.extras)
            }
        }
        for (id, error) in result.failedUpdates { handleMarkdownWriteError(error, for: id) }
        if !pass.trash.isEmpty {
            let before = pendingTrash
            for id in result.trashed { finishTrashing(id) }
            debugCrashPoint("after-trash")
            if pendingTrash != before { saveTombstones() }
        }
        markdownStorage?.attachments.scheduleSweep()
        if libraryDirty { scheduleSave() } else { scheduleRetryIfNeeded() }
    }

    /// Keeps a copy of an edit that waits for an unavailable folder in `recovery/`, replacing the copy kept
    /// earlier for the same note.
    private func keepWaitingCopy(_ id: UUID) {
        guard let text = bodyCache[id], recoveredSnapshots[id]?.text !== text else { return }
        let earlier = markdownWaitingCopies[id]
        guard let url = writeRecoveryCopy(id, text) else { return }
        markdownWaitingCopies[id] = url
        if let earlier, earlier != url { try? FileManager.default.removeItem(at: earlier) }
    }

    /// Whether the note's body is stored: a file in the RTFD store, an entry in `markdown-files.json`.
    private func hasStoredBody(_ id: UUID) -> Bool {
        if let markdownStorage { return markdownStorage.index.entry(id) != nil }
        return FileManager.default.fileExists(atPath: bodyURL(for: id).path)
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
        recordSavedBodyVersion(id)
        let extras = bodyExtras[id] ?? .empty
        do {
            if let markdownStorage {
                let notebook = notebook(with: meta.notebookID)
                try runMarkdownIONow(markdownStorage) { storage in
                    let temp = try storage.prepareTemp(text, extras: extras, meta: meta)
                    try storage.installTemp(temp, for: meta, notebook: notebook)
                }
            } else {
                let temp = try bodyStorage.prepareTemp(text, extras: extras, meta: meta)
                try installPreparedBody(temp, text: text, extras: extras, for: meta)
            }
        } catch {
            bodyWriteFailed(id, text: text, error: error)
            return false
        }
        bodyWritten(id, text: text, extras: extras)
        return true
    }

    private func isWaitingForSmallerAttachment(_ id: UUID) -> Bool {
        guard let failed = oversizedBodies[id], let text = bodyCache[id] else { return false }
        return failed.text === text
    }

    private func clearOversizedBody(_ id: UUID) {
        oversizedBodies[id] = nil
        if bodySaveNotices.removeValue(forKey: id) != nil { objectWillChange.send() }
    }

    /// A body write of `text` succeeded; an edit made while it ran keeps the note dirty.
    private func bodyWritten(_ id: UUID, text: NSAttributedString, extras: ContainerExtras) {
        clearOversizedBody(id)
        if bodyCache[id] == nil || (bodyCache[id] === text && (bodyExtras[id] ?? .empty) == extras) {
            dirtyBodies.remove(id)
            recoveredSnapshots[id] = nil
            if let copy = markdownWaitingCopies.removeValue(forKey: id) { try? FileManager.default.removeItem(at: copy) }
            if bodyCache[id] != nil {
                for copy in markdownRecoveryCopies.removeValue(forKey: id) ?? [] { try? FileManager.default.removeItem(at: copy) }
            }
        }
        unversionedLocalBodies.insert(id)
        if failedBodies.remove(id) != nil {
            // The library and index held back this note's new metadata/text; persist them now.
            libraryDirty = true
            searchIndexer.markDirty()
        }
        // A library save while the body was dirty wrote this note's old metadata.
        if let meta = note(with: id), persistedMeta[id] != meta { libraryDirty = true }
    }

    private func bodyWriteFailed(_ id: UUID, text: NSAttributedString, error: Error) {
        let episodeStart = failedBodies.insert(id).inserted
        NSLog("NoteIt: failed to save note \(id): \(error)")
        if case BodyExtrasError.unreadableSidecar = error {
            blockBodyWrites(id, reason: StoredBody.bodyExtrasUnreadable)
        }
        if case AttachmentStore.StoreError.tooLarge(let name) = error {
            if bodyCache[id] === text { oversizedBodies[id] = WeakSnapshot(text) }
            bodySaveNotices[id] = Self.attachmentTooLargeToSave(name)
            objectWillChange.send()
            keepWaitingCopy(id)
            return
        }
        switch error as? MarkdownStorageError {
        case .unreadable: blockBodyWrites(id, reason: MarkdownBodyStorage.unreadableReason)
        case .externallyChanged: markdownFolderNeedsScan()
        case .unresponsive: keepWaitingCopy(id)
        case .folderMissing, nil: break
        }
        // A note with no body on disk has nothing to fall back on: keep a copy right away
        // (once per failure episode) instead of only at quit.
        if episodeStart, !hasStoredBody(id) {
            writeRecoveryCopy(id, text)
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
            guard let old = persistedMeta[meta.id], hasStoredBody(meta.id) else { return meta }
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

    static let recoveredEditSource = "an unsaved edit"

    /// The notes with a Markdown copy in `recovery/` (a local folder in the data directory).
    func markdownRecoveryCopyIDs() -> Set<UUID> {
        let files = (try? FileManager.default.contentsOfDirectory(at: recoveryURL, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "md" }.compactMap { UUID(uuidString: String($0.lastPathComponent.prefix(36))) })
    }

    /// At launch, once the folder answered: edits kept in `recovery/` because they couldn't be written before the app
    /// quit go back into their notes. A copy replaces its note's text only when the note's file is still exactly what
    /// the edit was based on (the sha256 in the copy's name; no file then and now for a note never written), and the
    /// text it replaces is kept as a version. Otherwise (the file changed, whatever its date says; a copy that
    /// doesn't say what it was based on; a note that can't be written or is held) the file is left as it is and the
    /// edit becomes a note of its own beside it. Copies are removed once their text is written; copies of notes that
    /// are deleted or locked are left in `recovery/`.
    func restoreMarkdownRecoveryCopies(reads: MarkdownScanReads) {
        guard let storage = markdownStorage else { return }
        let key = URLResourceKey.contentModificationDateKey
        let files = (try? FileManager.default.contentsOfDirectory(at: recoveryURL, includingPropertiesForKeys: [key])) ?? []
        var copies: [UUID: [(url: URL, date: Date)]] = [:]
        for url in files where url.pathExtension == "md" {
            guard let id = UUID(uuidString: String(url.lastPathComponent.prefix(36))),
                  let date = try? url.resourceValues(forKeys: [key]).contentModificationDate else { continue }
            copies[id, default: []].append((url, date))
        }
        for (id, found) in copies.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let newest = found.max(by: { $0.date < $1.date }) else { continue }
            guard let index = noteIndex(id), notes[index].deletedAt == nil, !notes[index].isLocked else {
                NSLog("NoteIt: left the recovery copy \(newest.url.path): its note is deleted or locked")
                continue
            }
            let restored: StoredBody
            do {
                restored = try storage.readRecoveryCopy(newest.url)
            } catch {
                NSLog("NoteIt: couldn't read the recovery copy \(newest.url.path): \(error)")
                continue
            }
            let target: UUID
            if !bodyWriteBlocked.contains(id), !heldMarkdownDeletions.contains(id),
               let replaced = recoveryBaseMatches(id, base: MarkdownBodyStorage.recoveryBase(of: newest.url), reads: reads, storage: storage) {
                if let replaced { history.record(replaced.text, extras: replaced.extras, of: id) }
                restoreRecoveredBody(id, restored.text, date: newest.date, storage: storage)
                target = id
            } else {
                let meta = notes[index]
                let copy = createNote(in: meta.notebookID, initial: Self.appendingToTitleLine(restored.text, " (Recovered)"))
                if let copyIndex = noteIndex(copy.id) {
                    notes[copyIndex].conflictSource = Self.recoveredEditSource
                    notes[copyIndex].conflictOriginalID = id
                    notes[copyIndex].updatedAt = newest.date
                    dispatchDerivedIndexes(.metadata(notes[copyIndex]))
                }
                target = copy.id
            }
            markdownRecoveryCopies[target, default: []] += found.map(\.url)
            NSLog("NoteIt: restored note \(id) from \(newest.url.path)\(target == id ? "" : " as a note of its own")")
        }
    }

    /// Whether the note's file is still what a recovery copy's edit was based on: `.some(text it replaces)` (nil
    /// text for a note that has no file), or nil when it isn't, or can't be told.
    private func recoveryBaseMatches(_ id: UUID, base: MarkdownBodyStorage.RecoveryBase?, reads: MarkdownScanReads,
                                     storage: MarkdownBodyStorage) -> StoredBody?? {
        switch base {
        case nil:
            return nil
        case .noFile:
            return storage.index.entry(id) == nil ? .some(nil) : nil
        case .file(let sha):
            guard let entry = storage.index.entry(id), entry.sha256 == sha, let file = reads.files[entry.path],
                  AttachmentStore.sha256(file.data) == sha, file.read.body.readOnlyReason == nil else { return nil }
            return .some(file.read.body)
        }
    }

    private func restoreRecoveredBody(_ id: UUID, _ text: NSAttributedString, date: Date, storage: MarkdownBodyStorage) {
        guard let index = noteIndex(id) else { return }
        // The copy holds only the text; the file's own front matter keys stay.
        if bodyExtras[id] == nil, let extra = storage.index.entry(id)?.frontMatterExtra {
            setBodyExtras(ContainerExtras(frontMatter: extra), for: id)
        }
        bodyCache[id] = text
        touchBody(id)
        dirtyBodies.insert(id)
        // Its write failed before the app quit: not synced, and library.json keeps the saved metadata, until it's written.
        failedBodies.insert(id)
        markdownMissingRetryAt[id] = nil
        markdownBodiesNotRead.remove(id)
        var meta = notes[index]
        Self.applyDerivedFields(to: &meta, from: text)
        meta.updatedAt = max(meta.updatedAt, date)
        meta.revision = UUID()
        notes[index] = meta
        libraryDirty = true
        hasUnannouncedLocalChange = true
        dispatchDerivedIndexes(.changed(meta, text))
        postLocalNoteChange(id, .edited)
        if selectedNoteID == id || OpenEditorRegistry.shared.textView(for: id) != nil { externallyUpdatedNoteID = id }
    }

    /// Last resort at quit: copies bodies that couldn't be saved to `recovery/<id>-<timestamp>.rtfd`.
    private func writeRecoveryCopies() {
        for id in dirtyBodies {
            guard let text = bodyCache[id] else { continue }
            writeRecoveryCopy(id, text)
        }
    }

    /// Writes `text` to `recovery/<id>-<timestamp>.rtfd` unless this exact snapshot was already copied.
    @discardableResult
    private func writeRecoveryCopy(_ id: UUID, _ text: NSAttributedString) -> URL? {
        guard recoveredSnapshots[id]?.text !== text else { return nil }
        do {
            let url = try bodyStorage.recoveryCopy(text, for: id, in: recoveryURL)
            recoveredSnapshots[id] = WeakSnapshot(text)
            if markdownStorage != nil { markdownRecoveryCopies[id, default: []].append(url) }
            NSLog("NoteIt: note \(id) couldn’t be saved; wrote a recovery copy to \(url.path)")
            return url
        } catch {
            NSLog("NoteIt: note \(id) couldn’t be saved, and writing a recovery copy failed too: \(error)")
            return nil
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
            finishTrashing(id)
        }
        debugCrashPoint("after-trash")
        if pendingTrash != before { saveTombstones() }
        drainRawMetaDeletionQueue()
    }

    /// After a deleted note's body went: its raw meta, body-extras file and Version History, then its tombstone.
    private func finishTrashing(_ id: UUID) {
        guard let listed = libraryNoteIDsOnDisk, !listed.contains(id) else { return }
        do {
            try removeRawMetaFile(id, kind: .notes)
        } catch {
            return NSLog("NoteIt: failed to delete the sync meta copy of deleted note \(id): \(error)")
        }
        do {
            try removeBodyExtrasFile(id)
        } catch {
            return NSLog("NoteIt: failed to delete the body-extras file of deleted note \(id): \(error)")
        }
        do {
            try history.deleteHistory(of: id)
        } catch {
            return NSLog("NoteIt: failed to delete the version history of deleted note \(id): \(error)")
        }
        pendingTrash.remove(id)
    }

    /// Records that still owe a deletion on disk after their removal is saved.
    private var hasPendingAuxDeletions: Bool {
        !pendingTrash.isEmpty || !rawMetaDeletionQueue.isEmpty
    }

    // MARK: Tombstones

    func isTombstoned(_ id: UUID) -> Bool {
        tombstoned(id)
    }

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
        var fields = ["notebook", nb.name, nb.symbol, nb.colorHex, String(nb.sortIndex)]
        if let template = nb.defaultTemplateID { fields.append("template \(template.uuidString)") }
        // Appended only when set, so revisions of top-level notebooks stay the same.
        if let parent = nb.parent { fields.append("parent \(parent.uuidString)") }
        return fields
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
        /// The temp lies in the content folder, which may stop responding.
        var discardsInBackground = false

        func discard() {
            let temp = tempBody
            guard discardsInBackground else { try? FileManager.default.removeItem(at: temp); return }
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: temp) }
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
        if let markdown = storage as? MarkdownBodyStorage {
            replaces = markdown.revisionInputURL(for: payload.id) != nil && !markdown.tempHasSameBody(temp, as: payload.id)
        } else if FileManager.default.fileExists(atPath: storage.fileURL(for: payload.id).path) {
            replaces = (try? storage.read(payload.id)).map { !$0.text.isEqual(to: body) } ?? true
        }
        return PreparedRemoteNote(meta: meta, body: body, searchEntry: OrganiseIndexer.makeEntry(body, updatedAt: meta.updatedAt), tempBody: temp, extras: extras,
                                  bodyIsRTFD: bodyIsRTFD, tempExtras: tempExtras,
                                  rawMeta: RawMeta(sourceRevision: payload.revision, meta: payload.meta),
                                  replacesDifferentBody: replaces, discardsInBackground: storage is MarkdownBodyStorage)
    }

    /// Inserts or replaces a note from sync, keeping its revision. The prepared body package is swapped in
    /// first; nothing changes in memory if that fails. library.json is saved before returning; the search
    /// index is saved later (it is rebuildable).
    func applyPreparedRemoteNote(_ prepared: PreparedRemoteNote) throws {
        var prepared = prepared
        let id = prepared.meta.id
        let restoresHeldFile = heldMarkdownDeletions.contains(id) && bodyReadOnlyReasons[id] == Self.missingFileReason
        if restoresHeldFile {
            markdownStorage?.allowRecreatingMissingFile(id)
        } else if bodyWriteBlocked.contains(id) {
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
                let body = prepared.body, meta = prepared.meta
                let temp = try markdownStorage.map { storage in
                    try runMarkdownIONow(storage) { try $0.prepareTemp(body, extras: extras, meta: meta) }
                } ?? bodyStorage.prepareTemp(body, extras: extras, meta: meta)
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
            recordSavedBodyVersion(id, force: unversionedLocalBodies.contains(id))
        }
        do {
            if let markdownStorage {
                let temp = prepared.tempBody, meta = prepared.meta
                let notebook = notebook(with: meta.notebookID)
                try runMarkdownIONow(markdownStorage) { try $0.installTemp(temp, for: meta, notebook: notebook) }
            } else {
                try installPreparedBody(prepared.tempBody, text: prepared.body, extras: extras, for: prepared.meta)
            }
        } catch {
            prepared.discard()
            throw error
        }
        if restoresHeldFile { releaseHeldDeletion(id) }
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
        clearOversizedBody(id)
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
    /// A record without a `parent` key comes from NoteIt 0.2 or earlier: the local parent stays, and a nested
    /// notebook gets a new revision so the next pass pushes the parent back.
    func applyRemoteNotebook(_ remote: Notebook, hasParentKey: Bool = true) {
        var applied = remote
        var repairs = false
        if let index = notebooks.firstIndex(where: { $0.id == remote.id }) {
            if !hasParentKey, let local = notebooks[index].parent {
                applied.parent = local
                repairs = true
            }
            notebooks[index] = applied
        } else {
            notebooks.append(applied)
        }
        appliedRemoteRevisions.notebooks[remote.id.uuidString] = remote.revision
        clearSyncDeletion(remote.id)
        if repairs, let index = notebooks.firstIndex(where: { $0.id == remote.id }) {
            notebooks[index].revision = UUID()
            notebooks[index].modifiedAt = Date()
            hasUnannouncedLocalChange = true
        }
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
        guard !isClosedForLibrarySwitch else { return }
        // Notes arrive at their path; only a notebook change moves folders and other notes' files.
        var pass = MarkdownWritePass()
        if let storage = markdownStorage, libraryDirty, Set(storage.knownNotebooks) != Set(notebooks) { planMarkdownLayout(&pass) }
        if libraryDirty || !FileManager.default.fileExists(atPath: libraryURL.path) { saveLibrary() }
        if !libraryDirty, hasPendingAuxDeletions {
            if markdownStorage == nil {
                trashPendingBodies()
            } else {
                pass.trash = Array(pendingTrash)
                drainRawMetaDeletionQueue()
            }
        }
        if let storage = markdownStorage, !pass.isEmpty {
            if markdownWritePassQueued {
                markdownFlushAgain = true
            } else if !markdownFolderUnavailable {
                startMarkdownWritePass(pass, on: storage, waitingUntil: markdownFlushWait > 0 ? Date() + markdownFlushWait : nil)
            }
        }
        if searchIndexer.isDirty { scheduleIndexSave() }
        trimBodyCache()
        if libraryDirty, saveWorkItem == nil { scheduleSave(after: 5) }
    }

    /// Body to export: the cached (possibly unsaved) text, or the RTFD file (not loaded into the cache).
    enum ExportBody: @unchecked Sendable {
        case text(NSAttributedString)
        case file(URL)
    }

    /// A Markdown file is parsed here, because `completeExport` only reads RTFD. A known file that is missing or
    /// can't be read throws rather than sending an empty body.
    func exportBodySource(_ id: UUID) throws -> ExportBody {
        if let cached = bodyCache[id] {
            return .text(cached.copy() as? NSAttributedString ?? NSAttributedString(attributedString: cached))
        }
        guard bodyStorage.kind != .rtfd else { return .file(bodyStorage.fileURL(for: id)) }
        guard let markdownStorage, markdownStorage.revisionInputURL(for: id) != nil else { return .text(NSAttributedString()) }
        // A note whose file failed to read isn't read again before its retry time, as in body(for:).
        if loadErrors[id] != nil, let retry = markdownFailedReadRetryAt[id], Date() < retry {
            throw NoteStoreSyncError.unreadableBody(id)
        }
        if isWaitingToRetryMissingBody(id) { throw NoteStoreSyncError.unreadableBody(id) }
        // Taken as body(for:) takes it, so the note (and an editor waiting for this read) ends in the same state.
        let outcome = readMarkdownBody(id, from: markdownStorage, wait: markdownBlockingTimeout)
        guard case .text(let text) = takeMarkdownRead(id, outcome, from: markdownStorage) else {
            throw NoteStoreSyncError.unreadableBody(id)
        }
        cacheLoadedBody(id, text)
        // A missing file is cached as body(for:) does, but never synced as an empty note.
        guard case .read = outcome else { throw NoteStoreSyncError.unreadableBody(id) }
        return .text(text.copy() as? NSAttributedString ?? NSAttributedString(attributedString: text))
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
        clearSmartFolderDeletion(id)
        guard syncDeletionJournal.removeValue(forKey: id) != nil else { return }
        saveSyncDeletionJournal()
    }

    func clearAllSyncDeletions() {
        clearAllSmartFolderDeletions()
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
    /// Whether a body or the library still has changes `flush()` hasn't written.
    var hasUnsavedChanges: Bool {
        !dirtyBodies.isEmpty || libraryDirty || !stagedEditorBodies.isEmpty
    }

    /// After a conversion's commit point: the files this store used have moved, so it stops writing.
    func closeForLibrarySwitch() {
        isClosedForLibrarySwitch = true
        saveWorkItem?.cancel()
        saveWorkItem = nil
        stopWatchingMarkdownFolder()
    }

    func persistNow(_ id: UUID) throws {
        guard !isClosedForLibrarySwitch else { throw PersistNowError.libraryNotSaved }
        commitStagedEditorBody(id)
        guard note(with: id) != nil else { throw PersistNowError.noteMissing }
        if dirtyBodies.contains(id) {
            if bodyWriteBlocked.contains(id) { throw PersistNowError.writeBlocked }
            if markdownStorage == nil { try? FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true) }
            guard writePendingBody(id) else { throw PersistNowError.bodyNotSaved }
        }
        if libraryDirty || !FileManager.default.fileExists(atPath: libraryURL.path) {
            guard saveLibrary() else { throw PersistNowError.libraryNotSaved }
        }
    }
}

/// A body snapshot compared by identity. Weak, so a freed snapshot never matches a newer one at the same address.
final class WeakSnapshot {
    weak var text: NSAttributedString?
    init(_ text: NSAttributedString) { self.text = text }
}

/// A read of a note's Markdown file running off the main thread, for the index entry it was started with.
final class MarkdownReadJob: @unchecked Sendable {
    let entry: MarkdownFileEntry
    private let started = DispatchTime.now()
    /// Set on the main thread once it has waited for this read.
    var waitedFor = false
    private let lock = NSLock()
    private let done = DispatchGroup()
    /// nil while running; then the outcome, nil inside when the folder didn't answer.
    private var result: NoteStore.MarkdownBodyRead??

    init(entry: MarkdownFileEntry) {
        self.entry = entry
        done.enter()
    }

    func finish(_ outcome: NoteStore.MarkdownBodyRead?) {
        lock.withLock { result = .some(outcome) }
        done.leave()
    }

    func wait(upTo timeout: TimeInterval) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }

    var isFinished: Bool { lock.withLock { result != nil } }

    /// Finished without an answer: the read outlived its whole timeout.
    var timedOut: Bool { lock.withLock { result.map { $0 == nil } ?? false } }

    /// Seconds since the read started.
    var age: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000 }

    var outcome: NoteStore.MarkdownBodyRead? {
        lock.withLock { result ?? nil }
    }
}
