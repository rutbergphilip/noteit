import AppKit
import CoreSpotlight
import Foundation
import NoteItCore
import NoteItSync
import os

/// Where Spotlight items go. The app uses `CoreSpotlightIndex`; tests pass a fake.
protocol SpotlightIndexing: AnyObject, Sendable {
    func index(_ items: [SpotlightItem]) async throws
    func delete(_ ids: [String]) async throws
    func deleteAll() async throws
}

final class CoreSpotlightIndex: SpotlightIndexing, @unchecked Sendable {
    private lazy var index = CSSearchableIndex(name: "notes")
    private let lock = NSLock()

    private var searchableIndex: CSSearchableIndex {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func index(_ items: [SpotlightItem]) async throws {
        try await searchableIndex.indexSearchableItems(items.map(SpotlightItemBuilder.searchableItem))
    }

    func delete(_ ids: [String]) async throws {
        try await searchableIndex.deleteSearchableItems(withIdentifiers: ids)
    }

    func deleteAll() async throws {
        try await searchableIndex.deleteAllSearchableItems()
    }
}

/// Whether Spotlight has every change, shared with the Core Spotlight queue, which records failures and clears
/// `spotlightIndexDirty` in queue order.
private final class SpotlightIndexHealth: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var changes = 0
    private var failures = 0
    private var failuresAtRebuildStart = 0
    /// A failed call since the last good rebuild: the dirty flag stays set until a rebuild succeeds.
    private var failedSinceRebuild = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var changeCount: Int { lock.withLock { changes } }

    // Defaults are written outside the lock: writing posts a notification that observers on the main queue receive
    // while the writer waits, and the main thread takes the lock.
    func markDirty() {
        lock.withLock { changes += 1 }
        if !defaults.bool(forKey: PrefKey.spotlightIndexDirty) { defaults.set(true, forKey: PrefKey.spotlightIndexDirty) }
    }

    func recordFailure() {
        lock.withLock {
            failures += 1
            failedSinceRebuild = true
        }
    }

    /// Clears the dirty flag when nothing has changed since `change` was taken and nothing has failed.
    func clean(asOf change: Int) {
        guard lock.withLock({ change == changes && !failedSinceRebuild }) else { return }
        removeDirtyFlag(asOf: change)
    }

    func rebuildStarted() {
        lock.withLock { failuresAtRebuildStart = failures }
    }

    /// Writes the index version only when every call since the rebuild started succeeded.
    func rebuildFinished(asOf change: Int, version: Int) {
        let succeeded = lock.withLock { () -> Bool in
            guard failures == failuresAtRebuildStart else { return false }
            failedSinceRebuild = false
            return true
        }
        guard succeeded else { return }
        defaults.set(version, forKey: PrefKey.spotlightIndexVersion)
        if lock.withLock({ change == changes }) { removeDirtyFlag(asOf: change) }
    }

    /// A change or failure that came while the flag was removed sets it again.
    private func removeDirtyFlag(asOf change: Int) {
        defaults.removeObject(forKey: PrefKey.spotlightIndexDirty)
        if lock.withLock({ change != changes || failedSinceRebuild }) { defaults.set(true, forKey: PrefKey.spotlightIndexDirty) }
    }
}

/// Keeps the notes in Spotlight. A `DerivedIndex`: every change arrives through the registry hooks. It stays
/// registered while Spotlight is turned off and then ignores every hook; turning it back on rebuilds.
@MainActor
final class SpotlightIndexer: DerivedIndex {
    static let indexVersion = 1
    static let batchSize = 100
    static let shared = SpotlightIndexer(store: .shared, index: CoreSpotlightIndex())

    let indexID = "spotlight"
    private weak var store: NoteStore?
    private let defaults: UserDefaults
    private let index: SpotlightIndexing
    private let isSupported: Bool
    private let flushDelay: TimeInterval
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "Spotlight")
    private let health: SpotlightIndexHealth

    private var pendingItems: [String: SpotlightItem] = [:]
    private var pendingDeletes: Set<String> = []
    private var flushScheduled = false
    private var queue: Task<Void, Never>?
    private var rebuildGeneration = 0
    private var isRebuilding = false
    /// Items a running rebuild has read but not handed over; a hook for one of them drops it from here.
    private var rebuildBatch: [SpotlightItem] = []
    /// Bumped by every staged change to a note; a text read that finished after a newer change is dropped.
    private var stagedVersions: [String: Int] = [:]
    /// Notes whose text is read off the main thread before they are staged, in order.
    private var textReads: [UUID] = []
    private var textReader: Task<Void, Never>?
    private var lastEnabled = false
    private var lastIncludesText = true
    private var observer: NSObjectProtocol?
    private var folderObserver: NSObjectProtocol?
    /// A rebuild waits for the Markdown folder, or read a note's text while it didn't answer: once the folder
    /// answers, the index is rebuilt.
    private var rebuildWhenFolderAnswers = false

    /// `isSupported` is false for unbundled runs (`swift run`), where Spotlight stays off.
    init(store: NoteStore, defaults: UserDefaults = .standard, index: SpotlightIndexing,
         isSupported: Bool = Bundle.main.bundleIdentifier != nil, flushDelay: TimeInterval = 0.5) {
        self.store = store
        self.defaults = defaults
        self.index = index
        self.isSupported = isSupported
        self.flushDelay = flushDelay
        health = SpotlightIndexHealth(defaults: defaults)
    }

    var isEnabled: Bool {
        isSupported && (defaults.object(forKey: PrefKey.spotlightEnabled) as? Bool ?? true)
    }

    var includesText: Bool {
        defaults.object(forKey: PrefKey.spotlightIncludesText) as? Bool ?? true
    }

    /// Registers with the store's derived-index registry (once per store open) and rebuilds when the stored index
    /// version is out of date or the last run left changes Spotlight may not have. Notes the launch scan found
    /// changed while NoteIt was closed are updated one by one.
    func start() {
        guard let store, store.canRegisterDerivedIndex(indexID) else { return }
        store.registerDerivedIndex(self)
        lastEnabled = isEnabled
        lastIncludesText = includesText
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.preferencesChanged() }
        }
        folderObserver = NotificationCenter.default.addObserver(forName: NoteStore.markdownFolderAnswered, object: store,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markdownFolderAnswered() }
        }
        let dirty = defaults.bool(forKey: PrefKey.spotlightIndexDirty)
        if isEnabled, dirty || defaults.integer(forKey: PrefKey.spotlightIndexVersion) != Self.indexVersion {
            rebuildNow()
        } else if isSupported, !isEnabled, dirty {
            removeAll()
        } else if isEnabled {
            for id in store.notesChangedBeforeDerivedIndexes.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let meta = store.note(with: id) { metadataChanged(meta) } else { noteRemoved(id) }
            }
        }
    }

    /// Follows Show notes in Spotlight and Include note text: off removes every item, on (or a text change) rebuilds.
    func preferencesChanged() {
        let enabled = isEnabled
        let text = includesText
        guard enabled != lastEnabled || text != lastIncludesText else { return }
        let wasEnabled = lastEnabled
        lastEnabled = enabled
        lastIncludesText = text
        if enabled {
            rebuildNow()
        } else if wasEnabled {
            removeAll()
        }
    }

    private func removeAll() {
        rebuildGeneration += 1
        isRebuilding = false
        rebuildBatch.removeAll()
        pendingItems.removeAll()
        pendingDeletes.removeAll()
        textReads.removeAll()
        health.markDirty()
        defaults.removeObject(forKey: PrefKey.spotlightIndexVersion)
        enqueue { try await $0.deleteAll() }
        enqueueClean()
    }

    /// Rebuild Spotlight Index, and the rebuilds the indexer schedules itself.
    func rebuildNow() {
        guard isEnabled, let store else { return }
        // Every note would be indexed without its text while the folder is checked or doesn't answer.
        if store.markdownFolderUnavailable {
            rebuildWhenFolderAnswers = true
            health.markDirty()
            return
        }
        rebuildWhenFolderAnswers = false
        let notes = store.notes
        Task { @MainActor [weak self] in
            await self?.performRebuild(notes: notes) { [weak store] id in await store?.indexText(id) ?? .text(nil) }
        }
    }

    private func markdownFolderAnswered() {
        guard rebuildWhenFolderAnswers else { return }
        rebuildWhenFolderAnswers = false
        rebuildNow()
    }

    /// Hands pending changes to Core Spotlight and waits up to `timeout` for them, so a change made just before
    /// quitting isn't lost.
    func finishBeforeQuit(timeout: TimeInterval = 2) {
        handOverPending()
        guard let current = queue else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await current.value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// Waits for every hand-over to Core Spotlight queued so far.
    func settle() async {
        while let current = queue {
            await current.value
            if queue == current { return }
        }
    }

    // MARK: DerivedIndex

    func noteChanged(_ note: NoteMeta, body: NSAttributedString) {
        guard isEnabled else { return }
        if SpotlightItemBuilder.shouldIndex(note) {
            stage(SpotlightItemBuilder.item(for: note, text: includesText ? BodyCodec.plainText(of: body) : nil,
                                            includeText: includesText))
        } else {
            stageDelete(note.id)
        }
    }

    func noteRemoved(_ noteID: UUID) {
        guard isEnabled else { return }
        stageDelete(noteID)
    }

    /// A note whose body isn't cached gets its text read off the main thread first.
    func metadataChanged(_ note: NoteMeta) {
        guard isEnabled else { return }
        guard SpotlightItemBuilder.shouldIndex(note) else { return stageDelete(note.id) }
        guard includesText, store?.cachedBody(note.id) == nil else {
            let text = includesText ? store?.cachedBody(note.id).map(BodyCodec.plainText(of:)) : nil
            return stage(SpotlightItemBuilder.item(for: note, text: text, includeText: includesText))
        }
        health.markDirty()
        textReads.removeAll { $0 == note.id }
        textReads.append(note.id)
        readTexts()
    }

    /// Reads the queued notes' text one after another; a note changed again meanwhile is left to that change.
    private func readTexts() {
        guard textReader == nil else { return }
        textReader = Task { @MainActor [weak self] in
            while let self, let id = self.textReads.first {
                self.textReads.removeFirst()
                let version = self.stagedVersions[id.uuidString, default: 0]
                let read = await self.store?.indexText(id) ?? .text(nil)
                guard self.isEnabled, self.stagedVersions[id.uuidString, default: 0] == version,
                      let meta = self.store?.note(with: id) else { continue }
                guard SpotlightItemBuilder.shouldIndex(meta) else {
                    self.stageDelete(id)
                    continue
                }
                let text: String?
                switch read {
                case .text(let read): text = read
                case .unavailable:
                    // Kept by title until a rebuild once the folder answers again.
                    self.health.recordFailure()
                    self.rebuildWhenFolderAnswers = true
                    text = nil
                }
                self.stage(SpotlightItemBuilder.item(for: meta, text: text, includeText: self.includesText))
            }
            self?.textReader = nil
        }
    }

    func rebuild(notes: [NoteMeta], body: @escaping (UUID) -> NSAttributedString?) async {
        guard isEnabled else { return }
        let read = { (id: UUID) in body(id).map { BodyCodec.plainText(of: $0) } }
        await performRebuild(notes: notes) { id in
            .text(await Task.detached(priority: .utility) { read(id) }.value)
        }
    }

    func flush() {
        handOverPending()
    }

    // MARK: Batches

    /// Removes every item, then re-adds every note in batches. Text is read one note at a time, off the main
    /// thread unless it is cached. The index version is written once Core Spotlight has taken every batch.
    private func performRebuild(notes: [NoteMeta], text: @MainActor (UUID) async -> NoteStore.IndexText) async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        isRebuilding = true
        defer { if generation == rebuildGeneration { isRebuilding = false } }
        pendingItems.removeAll()
        pendingDeletes.removeAll()
        rebuildBatch.removeAll()
        health.markDirty()
        defaults.removeObject(forKey: PrefKey.spotlightIndexVersion)
        let includeText = includesText
        let health = health
        enqueue { _ in health.rebuildStarted() }
        enqueue { try await $0.deleteAll() }
        for original in notes {
            guard generation == rebuildGeneration, isEnabled else { return }
            var meta = original
            if let store {
                guard let live = store.note(with: original.id) else { continue }
                meta = live
            }
            guard SpotlightItemBuilder.shouldIndex(meta) else { continue }
            var read: String?
            if includeText {
                let version = stagedVersions[meta.id.uuidString, default: 0]
                switch await text(meta.id) {
                case .text(let text): read = text
                case .unavailable:
                    health.recordFailure()
                    rebuildWhenFolderAnswers = true
                }
                guard generation == rebuildGeneration, isEnabled else { return }
                // A hook for the note while its text was read already staged a newer item.
                if stagedVersions[meta.id.uuidString, default: 0] != version { continue }
                guard let live = store?.note(with: meta.id) ?? (store == nil ? meta : nil),
                      SpotlightItemBuilder.shouldIndex(live) else { continue }
                meta = live
            }
            rebuildBatch.append(SpotlightItemBuilder.item(for: meta, text: read, includeText: includeText))
            await Task.yield()
            guard generation == rebuildGeneration else { return }
            if rebuildBatch.count >= Self.batchSize { handOverRebuildBatch() }
        }
        guard generation == rebuildGeneration, isEnabled else { return }
        handOverRebuildBatch()
        handOverPending()
        let change = health.changeCount
        let version = Self.indexVersion
        enqueue { _ in health.rebuildFinished(asOf: change, version: version) }
    }

    private func handOverRebuildBatch() {
        guard !rebuildBatch.isEmpty else { return }
        let items = rebuildBatch
        rebuildBatch.removeAll()
        enqueue { try await $0.index(items) }
    }

    private func stage(_ item: SpotlightItem) {
        health.markDirty()
        stagedVersions[item.id, default: 0] += 1
        rebuildBatch.removeAll { $0.id == item.id }
        pendingDeletes.remove(item.id)
        pendingItems[item.id] = item
        scheduleHandOver()
    }

    private func stageDelete(_ id: UUID) {
        health.markDirty()
        stagedVersions[id.uuidString, default: 0] += 1
        rebuildBatch.removeAll { $0.id == id.uuidString }
        pendingItems[id.uuidString] = nil
        pendingDeletes.insert(id.uuidString)
        scheduleHandOver()
    }

    private func scheduleHandOver() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDelay) { [weak self] in
            MainActor.assumeIsolated { self?.handOverPending() }
        }
    }

    private func handOverPending() {
        flushScheduled = false
        if !pendingDeletes.isEmpty {
            let ids = pendingDeletes.sorted()
            pendingDeletes.removeAll()
            enqueue { try await $0.delete(ids) }
        }
        if !pendingItems.isEmpty {
            let items = pendingItems.values.sorted { $0.id < $1.id }
            pendingItems.removeAll()
            for start in stride(from: 0, to: items.count, by: Self.batchSize) {
                let batch = Array(items[start..<min(items.count, start + Self.batchSize)])
                enqueue { try await $0.index(batch) }
            }
        }
        // A running rebuild clears the flag itself when it finishes.
        if !isRebuilding, defaults.bool(forKey: PrefKey.spotlightIndexDirty) { enqueueClean() }
    }

    /// Clears the dirty flag once everything queued so far has reached Core Spotlight without an error.
    private func enqueueClean() {
        let health = health
        let change = health.changeCount
        enqueue { _ in health.clean(asOf: change) }
    }

    /// Runs Core Spotlight calls one after another, off the main actor. A failure leaves the index dirty.
    private func enqueue(_ work: @escaping @Sendable (SpotlightIndexing) async throws -> Void) {
        let previous = queue
        let index = index
        let logger = logger
        let health = health
        queue = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try await work(index)
            } catch {
                health.recordFailure()
                logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
