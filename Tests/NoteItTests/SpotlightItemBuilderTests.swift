import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

final class FakeSpotlightIndex: SpotlightIndexing, @unchecked Sendable {
    enum Call: Equatable {
        case index([String])
        case delete([String])
        case deleteAll
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var stored: [String: SpotlightItem] = [:]

    var calls: [Call] { lock.withLock { recorded } }
    var items: [String: SpotlightItem] { lock.withLock { stored } }

    func reset() { lock.withLock { recorded.removeAll() } }

    func index(_ items: [SpotlightItem]) async throws {
        lock.withLock {
            recorded.append(.index(items.map(\.id)))
            for item in items { stored[item.id] = item }
        }
    }

    func delete(_ ids: [String]) async throws {
        lock.withLock {
            recorded.append(.delete(ids))
            for id in ids { stored[id] = nil }
        }
    }

    func deleteAll() async throws {
        lock.withLock {
            recorded.append(.deleteAll)
            stored.removeAll()
        }
    }
}

@MainActor
final class SpotlightItemBuilderTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-spotlight-\(UUID().uuidString)")
        suiteName = "noteit-spotlight-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func meta(title: String = "Groceries", notebook: UUID? = UUID(), tags: [String] = ["home"]) -> NoteMeta {
        NoteMeta(id: UUID(), notebookID: notebook, title: title, preview: "Milk and eggs", isPinned: false,
                 createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200), tags: tags)
    }

    private func makeIndexer() -> (NoteStore, SpotlightIndexer, FakeSpotlightIndex) {
        let store = NoteStore(location: LibraryLocation(url: root.appendingPathComponent("lib"), seedsFreshLibrary: false))
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: store, defaults: defaults, index: fake, isSupported: true, flushDelay: 60)
        return (store, indexer, fake)
    }

    private func settle(_ indexer: SpotlightIndexer) async {
        indexer.flush()
        await indexer.settle()
    }

    /// Waits for the rebuild the indexer schedules itself to reach the fake index.
    private func settleRebuild(_ indexer: SpotlightIndexer, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        for _ in 0..<20 { await Task.yield() }
        while defaults.object(forKey: PrefKey.spotlightIndexVersion) == nil {
            guard Date() < deadline else { return XCTFail("The rebuild didn't finish", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await indexer.settle()
    }

    private func create(_ store: NoteStore, _ text: String) -> UUID {
        store.createNote(in: nil, initial: NSAttributedString(string: text)).id
    }

    func testShouldIndexSkipsRecentlyDeleted() {
        var note = meta()
        XCTAssertTrue(SpotlightItemBuilder.shouldIndex(note))
        note.deletedAt = Date()
        XCTAssertFalse(SpotlightItemBuilder.shouldIndex(note))
    }

    func testShouldIndexSkipsLocked() {
        var note = meta()
        note.lock = NoteLock(keyID: "k1", sealedID: UUID())
        XCTAssertFalse(SpotlightItemBuilder.shouldIndex(note))
    }

    func testItemAttributes() {
        let note = meta()
        let item = SpotlightItemBuilder.item(for: note, text: "Groceries\nMilk and eggs", includeText: true)
        XCTAssertEqual(item.id, note.id.uuidString)
        XCTAssertEqual(item.domain, note.notebookID?.uuidString)
        XCTAssertEqual(item.title, "Groceries")
        XCTAssertEqual(item.contentDescription, "Milk and eggs")
        XCTAssertEqual(item.textContent, "Groceries\nMilk and eggs")
        XCTAssertEqual(item.keywords, ["home"])
        XCTAssertEqual(item.created, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(item.modified, Date(timeIntervalSince1970: 200))

        let searchable = SpotlightItemBuilder.searchableItem(item)
        XCTAssertEqual(searchable.uniqueIdentifier, note.id.uuidString)
        XCTAssertEqual(searchable.domainIdentifier, note.notebookID?.uuidString)
        XCTAssertEqual(searchable.attributeSet.title, "Groceries")
        XCTAssertEqual(searchable.attributeSet.textContent, "Groceries\nMilk and eggs")
        XCTAssertEqual(searchable.attributeSet.keywords, ["home"])
        XCTAssertEqual(searchable.attributeSet.contentType, "public.text")
        XCTAssertEqual(SpotlightItemBuilder.item(for: meta(title: ""), text: nil, includeText: true).title, "New Note")
    }

    func testTextIsTruncated() {
        let text = String(repeating: "a", count: 25_000)
        let item = SpotlightItemBuilder.item(for: meta(), text: text, includeText: true)
        XCTAssertEqual(item.textContent?.count, 20_000)
    }

    func testTextOmittedWhenSettingOff() {
        XCTAssertNil(SpotlightItemBuilder.item(for: meta(), text: "Secret", includeText: false).textContent)
    }

    func testDomainForNoNotebook() {
        XCTAssertEqual(SpotlightItemBuilder.item(for: meta(notebook: nil), text: nil, includeText: true).domain, "none")
    }

    func testRegistersAsDerivedIndex() async {
        let (store, indexer, fake) = makeIndexer()
        defaults.set(SpotlightIndexer.indexVersion, forKey: PrefKey.spotlightIndexVersion)
        indexer.start()
        indexer.start()
        XCTAssertEqual(store.derivedIndexes.filter { $0.indexID == "spotlight" }.count, 1)

        let id = create(store, "Hello Spotlight")
        await settle(indexer)
        XCTAssertEqual(fake.items[id.uuidString]?.textContent, "Hello Spotlight")
    }

    func testStaleIndexVersionRebuildsAtStart() async {
        let (store, indexer, fake) = makeIndexer()
        let id = create(store, "Before start")
        defaults.set(0, forKey: PrefKey.spotlightIndexVersion)
        indexer.start()
        defaults.removeObject(forKey: PrefKey.spotlightIndexVersion)
        await settleRebuild(indexer)
        XCTAssertEqual(fake.calls.first, .deleteAll)
        XCTAssertNotNil(fake.items[id.uuidString])
        XCTAssertEqual(defaults.integer(forKey: PrefKey.spotlightIndexVersion), SpotlightIndexer.indexVersion)
    }

    func testNoteRemovedDeletesItem() async {
        let (store, indexer, fake) = makeIndexer()
        defaults.set(SpotlightIndexer.indexVersion, forKey: PrefKey.spotlightIndexVersion)
        indexer.start()
        let id = create(store, "Doomed")
        await settle(indexer)
        XCTAssertNotNil(fake.items[id.uuidString])

        fake.reset()
        indexer.noteRemoved(id)
        await settle(indexer)
        XCTAssertEqual(fake.calls, [.delete([id.uuidString])])
        XCTAssertNil(fake.items[id.uuidString])

        let locked = create(store, "Private")
        await settle(indexer)
        store.notes[store.noteIndex(locked)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
        store.refreshDerivedIndexes(for: locked)
        await settle(indexer)
        XCTAssertNil(fake.items[locked.uuidString])
    }

    func testMetadataChangedReindexesOrRemoves() async {
        let (store, indexer, fake) = makeIndexer()
        defaults.set(SpotlightIndexer.indexVersion, forKey: PrefKey.spotlightIndexVersion)
        indexer.start()
        let id = create(store, "Pinned note\nBody text")
        await settle(indexer)

        fake.reset()
        store.togglePin(id)
        await settle(indexer)
        XCTAssertEqual(fake.calls, [.index([id.uuidString])])
        XCTAssertEqual(fake.items[id.uuidString]?.textContent, "Pinned note\nBody text")

        store.moveToRecentlyDeleted([id])
        await settle(indexer)
        XCTAssertNil(fake.items[id.uuidString])

        store.recover([id])
        await settle(indexer)
        XCTAssertEqual(fake.items[id.uuidString]?.title, "Pinned note")
    }

    func testDormantWhileOffAndRebuildsWhenTurnedOn() async {
        let (store, indexer, fake) = makeIndexer()
        defaults.set(SpotlightIndexer.indexVersion, forKey: PrefKey.spotlightIndexVersion)
        indexer.start()
        let kept = create(store, "Kept")
        await settle(indexer)

        defaults.set(false, forKey: PrefKey.spotlightEnabled)
        indexer.preferencesChanged()
        await indexer.settle()
        XCTAssertEqual(fake.calls.last, .deleteAll)
        XCTAssertTrue(fake.items.isEmpty)
        XCTAssertTrue(store.derivedIndexes.contains { $0.indexID == "spotlight" })

        fake.reset()
        let added = create(store, "Written while off")
        store.togglePin(kept)
        indexer.noteRemoved(kept)
        await settle(indexer)
        XCTAssertEqual(fake.calls, [])

        defaults.set(true, forKey: PrefKey.spotlightEnabled)
        indexer.preferencesChanged()
        await settleRebuild(indexer)
        XCTAssertEqual(fake.calls.first, .deleteAll)
        XCTAssertEqual(Set(fake.items.keys), [kept.uuidString, added.uuidString])
    }

    func testUnbundledIndexerStaysOff() async {
        let store = NoteStore(location: LibraryLocation(url: root.appendingPathComponent("lib"), seedsFreshLibrary: false))
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: store, defaults: defaults, index: fake, isSupported: false, flushDelay: 60)
        indexer.start()
        _ = create(store, "Not indexed")
        await settle(indexer)
        XCTAssertEqual(fake.calls, [])
    }

    func testRebuildIndexesInBatchesOfAHundred() async {
        let (store, indexer, fake) = makeIndexer()
        for number in 0..<250 { _ = create(store, "Note \(number)") }
        indexer.start()
        await settleRebuild(indexer)
        let sizes = fake.calls.compactMap { call -> Int? in
            if case .index(let ids) = call { return ids.count }
            return nil
        }
        XCTAssertEqual(sizes, [100, 100, 50])
    }
}
