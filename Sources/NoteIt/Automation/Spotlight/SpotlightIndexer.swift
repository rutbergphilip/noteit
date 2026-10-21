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

    private var pendingItems: [String: SpotlightItem] = [:]
    private var pendingDeletes: Set<String> = []
    private var flushScheduled = false
    private var queue: Task<Void, Never>?
    private var rebuildGeneration = 0
    /// Items a running rebuild has read but not handed over; a hook for one of them drops it from here.
    private var rebuildBatch: [SpotlightItem] = []
    private var lastEnabled = false
    private var lastIncludesText = true
    private var observer: NSObjectProtocol?

    /// `isSupported` is false for unbundled runs (`swift run`), where Spotlight stays off.
    init(store: NoteStore, defaults: UserDefaults = .standard, index: SpotlightIndexing,
         isSupported: Bool = Bundle.main.bundleIdentifier != nil, flushDelay: TimeInterval = 0.5) {
        self.store = store
        self.defaults = defaults
        self.index = index
        self.isSupported = isSupported
        self.flushDelay = flushDelay
    }

    var isEnabled: Bool {
        isSupported && (defaults.object(forKey: PrefKey.spotlightEnabled) as? Bool ?? true)
    }

    var includesText: Bool {
        defaults.object(forKey: PrefKey.spotlightIncludesText) as? Bool ?? true
    }

    /// Registers with the store's derived-index registry (once per store open) and rebuilds when the stored index
    /// version is out of date.
    func start() {
        guard let store, store.canRegisterDerivedIndex(indexID) else { return }
        store.registerDerivedIndex(self)
        lastEnabled = isEnabled
        lastIncludesText = includesText
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.preferencesChanged() }
        }
        if isEnabled, defaults.integer(forKey: PrefKey.spotlightIndexVersion) != Self.indexVersion {
            rebuildNow()
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
            rebuildGeneration += 1
            rebuildBatch.removeAll()
            pendingItems.removeAll()
            pendingDeletes.removeAll()
            defaults.removeObject(forKey: PrefKey.spotlightIndexVersion)
            enqueue { try await $0.deleteAll() }
        }
    }

    /// Rebuild Spotlight Index, and the rebuilds the indexer schedules itself.
    func rebuildNow() {
        guard isEnabled, let store else { return }
        let notes = store.notes
        Task { @MainActor [weak self] in
            await self?.performRebuild(notes: notes) { [weak store] id in store?.plainText(for: id) }
        }
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

    func metadataChanged(_ note: NoteMeta) {
        guard isEnabled else { return }
        if SpotlightItemBuilder.shouldIndex(note) {
            let text = includesText ? store?.plainText(for: note.id) : nil
            stage(SpotlightItemBuilder.item(for: note, text: text, includeText: includesText))
        } else {
            stageDelete(note.id)
        }
    }

    func rebuild(notes: [NoteMeta], body: @escaping (UUID) -> NSAttributedString?) async {
        guard isEnabled else { return }
        await performRebuild(notes: notes) { id in body(id).map(BodyCodec.plainText(of:)) }
    }

    func flush() {
        handOverPending()
    }

    // MARK: Batches

    /// Re-adds every note in batches. Text is read on the main actor one note at a time, yielding between notes.
    private func performRebuild(notes: [NoteMeta], text: @MainActor (UUID) -> String?) async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        pendingItems.removeAll()
        pendingDeletes.removeAll()
        rebuildBatch.removeAll()
        defaults.removeObject(forKey: PrefKey.spotlightIndexVersion)
        let includeText = includesText
        enqueue { try await $0.deleteAll() }
        for original in notes {
            guard generation == rebuildGeneration, isEnabled else { return }
            var meta = original
            if let store {
                guard let live = store.note(with: original.id) else { continue }
                meta = live
            }
            guard SpotlightItemBuilder.shouldIndex(meta) else { continue }
            rebuildBatch.append(SpotlightItemBuilder.item(for: meta, text: includeText ? text(meta.id) : nil,
                                                          includeText: includeText))
            await Task.yield()
            guard generation == rebuildGeneration else { return }
            if rebuildBatch.count >= Self.batchSize { handOverRebuildBatch() }
        }
        guard generation == rebuildGeneration, isEnabled else { return }
        handOverRebuildBatch()
        defaults.set(Self.indexVersion, forKey: PrefKey.spotlightIndexVersion)
    }

    private func handOverRebuildBatch() {
        guard !rebuildBatch.isEmpty else { return }
        let items = rebuildBatch
        rebuildBatch.removeAll()
        enqueue { try await $0.index(items) }
    }

    private func stage(_ item: SpotlightItem) {
        rebuildBatch.removeAll { $0.id == item.id }
        pendingDeletes.remove(item.id)
        pendingItems[item.id] = item
        scheduleHandOver()
    }

    private func stageDelete(_ id: UUID) {
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
        guard !pendingItems.isEmpty else { return }
        let items = pendingItems.values.sorted { $0.id < $1.id }
        pendingItems.removeAll()
        for start in stride(from: 0, to: items.count, by: Self.batchSize) {
            let batch = Array(items[start..<min(items.count, start + Self.batchSize)])
            enqueue { try await $0.index(batch) }
        }
    }

    /// Runs Core Spotlight calls one after another, off the main actor.
    private func enqueue(_ work: @escaping @Sendable (SpotlightIndexing) async throws -> Void) {
        let previous = queue
        let index = index
        let logger = logger
        queue = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try await work(index)
            } catch {
                logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
