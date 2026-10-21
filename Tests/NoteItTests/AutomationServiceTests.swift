import AppKit
import XCTest
import NoteItAPI
import NoteItCore
@testable import NoteIt

@MainActor
final class AutomationServiceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let fm = FileManager.default
    private let harness = EditorHarness()

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-automation-\(UUID().uuidString)", isDirectory: true)
        suiteName = "noteit-automation-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        harness.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    private func makeService(loading: Bool = false, dailyAvailable: Bool = DailyNotes.isAvailable) -> (AutomationService, NoteStore) {
        let store = NoteStore(location: LibraryLocation(url: root.appendingPathComponent("lib"), seedsFreshLibrary: false))
        store.preferences = defaults
        store.history.now = { [unowned self] in self.clock }
        let staged = StagedUploads(directory: root.appendingPathComponent("staged"), now: { [unowned self] in self.clock })
        let service = AutomationService(store: store, defaults: defaults, staged: staged, now: { [unowned self] in self.clock },
                                        dailyNotesAvailable: { dailyAvailable }, isLoading: { loading })
        return (service, store)
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func assertThrows<T>(_ expected: AutomationError, _ body: () throws -> T, file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? AutomationError, expected, file: file, line: line)
        }
    }

    private func assertThrows<T>(_ expected: AutomationError, _ body: () async throws -> T, file: StaticString = #filePath,
                                 line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("No error thrown", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AutomationError, expected, file: file, line: line)
        }
    }

    private func lock(_ store: NoteStore, _ id: UUID) {
        store.notes[store.noteIndex(id)!].lock = NoteLock(keyID: "k1", sealedID: UUID())
    }

    // MARK: Create

    func testCreateUsesDefaultNotebookAndBoldTitle() throws {
        let (service, store) = makeService()
        let work = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let inbox = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: "#0A84FF")
        let meta = try service.create(title: "Groceries", body: "milk", format: .text, notebook: nil, tags: [], pinned: true)
        XCTAssertEqual(meta.notebookID, inbox.id)
        XCTAssertTrue(meta.isPinned)
        XCTAssertEqual(meta.title, "Groceries")
        let body = store.body(for: meta.id)
        XCTAssertEqual(body.string, "Groceries\nmilk")
        let font = try XCTUnwrap(body.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))

        defaults.set(work.id.uuidString, forKey: PrefKey.defaultNotebookID)
        XCTAssertEqual(try service.create(title: nil, body: "x", format: .text, notebook: nil, tags: [], pinned: false).notebookID,
                       work.id)
    }

    func testCreateByNotebookNameIsCaseInsensitive() throws {
        let (service, store) = makeService()
        let work = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let meta = try service.create(title: "A", body: "", format: .text, notebook: .name("wORK"), tags: [], pinned: false)
        XCTAssertEqual(meta.notebookID, work.id)
        XCTAssertEqual(try service.create(title: "B", body: "", format: .text, notebook: .id(work.id), tags: [], pinned: false)
            .notebookID, work.id)
    }

    func testCreateUnknownNotebookThrows() {
        let (service, _) = makeService()
        assertThrows(.notebookNameNotFound) { try service.create(title: "A", body: "", format: .text, notebook: .name("Nope"), tags: [], pinned: false) }
        assertThrows(.notebookNotFound) { try service.create(title: "A", body: "", format: .text, notebook: .id(UUID()), tags: [], pinned: false) }
    }

    func testCreateAppendsTagsLineAndParsesTags() throws {
        let (service, store) = makeService()
        let meta = try service.create(title: "Trip", body: "Pack bags", format: .text, notebook: nil,
                                      tags: ["#Travel", "work", "travel"], pinned: false)
        XCTAssertEqual(store.body(for: meta.id).string, "Trip\nPack bags\n#travel #work")
        XCTAssertEqual(Set(meta.tags), ["travel", "work"])
    }

    // MARK: Append and replace

    func testAppendEndAndStart() async throws {
        let (service, store) = makeService()
        let id = try service.create(title: "Log", body: "first", format: .text, notebook: nil, tags: [], pinned: false).id
        _ = try await service.append(id, text: "last", format: .text, position: .end, timestamp: false, ifRevision: nil)
        _ = try await service.append(id, text: "top", format: .text, position: .start, timestamp: false, ifRevision: nil)
        XCTAssertEqual(store.body(for: id).string, "Log\ntop\nfirst\nlast")
    }

    func testAppendTimestampIs24HourPOSIX() async throws {
        let (service, store) = makeService()
        clock = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 21, minute: 5)))
        let id = try service.create(title: "Log", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        _ = try await service.append(id, text: "late", format: .text, position: .end, timestamp: true, ifRevision: nil)
        XCTAssertEqual(store.body(for: id).string, "Log\n21:05 late")
    }

    func testReplaceRecordsVersionHistory() async throws {
        let (service, store) = makeService()
        let closed = try service.create(title: "Closed", body: "old", format: .text, notebook: nil, tags: [], pinned: false).id
        store.flush()
        let before = store.versions(of: closed).count
        _ = try await service.patch(closed, title: nil, body: ("new", .text), notebookID: nil, pinned: nil, ifRevision: nil)
        XCTAssertEqual(store.versions(of: closed).count, before + 1)
        XCTAssertEqual(store.body(for: closed).string, "new")

        let open = try service.create(title: "Open", body: "old", format: .text, notebook: nil, tags: [], pinned: false).id
        store.flush()
        let editor = harness.open(store, open)
        let openBefore = store.versions(of: open).count
        _ = try await service.patch(open, title: nil, body: ("fresh", .text), notebookID: nil, pinned: nil, ifRevision: nil)
        EditorHarness.settle(editor.view.undoManager)
        XCTAssertEqual(store.versions(of: open).count, openBefore + 1)
        XCTAssertEqual(editor.view.string, "fresh")
    }

    func testAppendRecordsNoVersion() async throws {
        let (service, store) = makeService()
        let id = try service.create(title: "Log", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        store.flush()
        var recorded = 0
        store.recordVersionOverride = { _, _ in recorded += 1; return nil }
        _ = try await service.append(id, text: "line", format: .text, position: .end, timestamp: false, ifRevision: nil)
        XCTAssertEqual(recorded, 0)
    }

    func testEditsGoThroughEditBody() async throws {
        let (service, store) = makeService()
        let id = try service.create(title: "Title", body: "body", format: .text, notebook: nil, tags: [], pinned: false).id
        store.flush()
        let editor = harness.open(store, id)
        let undo = try XCTUnwrap(editor.view.undoManager)
        _ = try await service.append(id, text: "more", format: .text, position: .end, timestamp: false, ifRevision: nil)
        EditorHarness.settle(undo)
        XCTAssertEqual(editor.view.string, "Title\nbody\nmore")
        XCTAssertEqual(undo.undoActionName, "Append Text")
        undo.undo()
        XCTAssertEqual(editor.view.string, "Title\nbody")
    }

    func testPatchRevisionMismatch() async throws {
        let (service, _) = makeService()
        let meta = try service.create(title: "A", body: "", format: .text, notebook: nil, tags: [], pinned: false)
        await assertThrows(.revisionMismatch(current: meta.revision)) {
            try await service.patch(meta.id, title: "B", body: nil, notebookID: nil, pinned: nil, ifRevision: UUID())
        }
        await assertThrows(.revisionMismatch(current: meta.revision)) {
            try await service.append(meta.id, text: "x", format: .text, position: .end, timestamp: false, ifRevision: UUID())
        }
        let patched = try await service.patch(meta.id, title: "B", body: nil, notebookID: nil, pinned: nil, ifRevision: meta.revision)
        XCTAssertEqual(patched.title, "B")
        XCTAssertNotEqual(patched.revision, meta.revision)
    }

    func testMissingRevisionsAreAssignedOnlyWhenNeeded() async throws {
        let store = NoteStore(location: LibraryLocation(url: root.appendingPathComponent("lib"), seedsFreshLibrary: false))
        let first = store.createNote(in: nil, initial: NSAttributedString(string: "One")).id
        let second = store.createNote(in: nil, initial: NSAttributedString(string: "Two")).id
        let third = store.createNote(in: nil, initial: NSAttributedString(string: "Three")).id
        for id in [first, second, third] { store.notes[store.noteIndex(id)!].revision = nil }
        let service = AutomationService(store: store, defaults: defaults, staged: StagedUploads(directory: root.appendingPathComponent("staged")),
                                        isLoading: { false })
        XCTAssertNil(store.note(with: first)?.revision, "creating the service assigns nothing")

        do {
            _ = try await service.append(first, text: "x", format: .text, position: .end, timestamp: false, ifRevision: UUID())
            XCTFail("No error thrown")
        } catch {
            guard case .revisionMismatch(let current) = error as? AutomationError else { return XCTFail("\(error)") }
            XCTAssertNotNil(current)
        }
        XCTAssertNil(store.note(with: second)?.revision)

        await service.assignMissingRevisionsForLocalAPI()
        XCTAssertNotNil(store.note(with: second)?.revision)
        XCTAssertNotNil(store.note(with: third)?.revision)
    }

    /// The lazy revision is hashed off the main actor; a note changed meanwhile keeps no revision and doesn't match.
    func testLazyRevisionSkipsNoteChangedWhileHashing() async throws {
        let store = NoteStore(location: LibraryLocation(url: root.appendingPathComponent("lib"), seedsFreshLibrary: false))
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "One")).id
        store.notes[store.noteIndex(id)!].revision = nil
        let other = store.createNote(in: nil, initial: NSAttributedString(string: "Two")).id
        store.notes[store.noteIndex(other)!].revision = nil
        let service = AutomationService(store: store, defaults: defaults, staged: StagedUploads(directory: root.appendingPathComponent("staged")),
                                        isLoading: { false })
        let input = try XCTUnwrap(store.missingRevisionInput(forNote: id))
        let expected = try XCTUnwrap(NoteStore.contentRevisions(for: [input])[id])

        let append = Task { try await service.append(id, text: "x", format: .text, position: .end, timestamp: false, ifRevision: expected) }
        await Task.yield()
        store.notes[store.noteIndex(id)!].title = "Changed"
        do {
            _ = try await append.value
            XCTFail("appended to a note changed while its revision was hashed")
        } catch {
            XCTAssertEqual(error as? AutomationError, .revisionMismatch(current: nil))
        }
        XCTAssertNil(store.note(with: id)?.revision)
        XCTAssertNil(store.note(with: other)?.revision, "only the compared note is hashed")
        XCTAssertEqual(store.body(for: id).string, "One")
    }

    func testWritesToRecentlyDeletedNoteThrow() async throws {
        let (service, _) = makeService()
        let id = try service.create(title: "A", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        try service.moveToRecentlyDeleted(id)
        await assertThrows(.noteDeleted) { try await service.append(id, text: "x", format: .text, position: .end, timestamp: false, ifRevision: nil) }
        await assertThrows(.noteDeleted) { try await service.patch(id, title: "B", body: nil, notebookID: nil, pinned: nil, ifRevision: nil) }
        assertThrows(.noteDeleted) { try service.addAttachment(to: id, data: Data([1]), filename: "a.bin", contentType: "") }
        XCTAssertNil(try service.restore(id).deletedAt)
    }

    func testLockedNoteBodyThrowsAndPreviewIsEmpty() async throws {
        let (service, store) = makeService()
        let id = try service.create(title: "Secret plans", body: "hidden words", format: .text, notebook: nil, tags: [], pinned: false).id
        lock(store, id)
        XCTAssertFalse(store.note(with: id)!.preview.isEmpty)
        XCTAssertEqual(try service.note(id).preview, "")
        XCTAssertEqual(try service.note(id).title, "Secret plans")
        for format in [BodyFormatDTO.text, .markdown, .html, .noteitDoc] {
            assertThrows(.noteLocked) { try service.body(id, format: format) }
        }
        await assertThrows(.noteLocked) { try await service.append(id, text: "x", format: .text, position: .end, timestamp: false, ifRevision: nil) }
        await assertThrows(.noteLocked) { try await service.patch(id, title: "New", body: nil, notebookID: nil, pinned: nil, ifRevision: nil) }
        assertThrows(.noteLocked) { try service.attachments(of: id) }
        assertThrows(.noteLocked) { try service.addAttachment(to: id, data: Data([1]), filename: "a", contentType: "") }
        XCTAssertTrue(try service.search("hidden", notebook: nil, tag: nil, limit: 10).isEmpty)
        let hits = try service.search("secret", notebook: nil, tag: nil, limit: 10)
        XCTAssertEqual(hits.map(\.0.id), [id])
        XCTAssertEqual(hits.first?.snippet, "")
        XCTAssertEqual(hits.first?.0.preview, "")
        let listed = try service.list(notebook: nil, tag: nil, query: nil, updatedSince: nil, deleted: .exclude, sort: .list,
                                      limit: 10, cursor: nil)
        XCTAssertEqual(listed.notes.first?.preview, "")
        XCTAssertEqual(store.body(for: id).string, "Secret plans\nhidden words")
    }

    func testNotReadyWhileLoading() {
        let (service, _) = makeService(loading: true)
        assertThrows(.notReady) { try service.create(title: "A", body: "", format: .text, notebook: nil, tags: [], pinned: false) }
        assertThrows(.notReady) { try service.note(UUID()) }
        assertThrows(.notReady) { try service.list(notebook: nil, tag: nil, query: nil, updatedSince: nil, deleted: .exclude,
                                                   sort: .list, limit: 10, cursor: nil) }
        assertThrows(.notReady) { try service.daily(date: Date(), create: true) }
        XCTAssertNil(service.findByTitle("A"))
    }

    func testFindByTitleIgnoresCaseOnly() throws {
        let (service, store) = makeService()
        let cafe = store.createNote(in: nil, initial: NSAttributedString(string: "Café\nbody")).id
        _ = store.createNote(in: nil, initial: NSAttributedString(string: ""))
        XCTAssertEqual(service.findByTitle("CAFÉ")?.id, cafe)
        XCTAssertNil(service.findByTitle("cafe"), "no diacritic folding")
        XCTAssertNil(service.findByTitle("ｃａｆé"), "no width folding")
        XCTAssertNil(service.findByTitle("New Note"), "an untitled note never matches")
    }

    func testSetTitleKeepsAttributes() async throws {
        let (service, store) = makeService()
        let id = try service.create(title: "Old title", body: "body", format: .text, notebook: nil, tags: [], pinned: false).id
        let font = store.body(for: id).attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let meta = try await service.patch(id, title: "New", body: nil, notebookID: nil, pinned: nil, ifRevision: nil)
        XCTAssertEqual(meta.title, "New")
        let body = store.body(for: id)
        XCTAssertEqual(body.string, "New\nbody")
        XCTAssertEqual(body.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
        XCTAssertEqual(body.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, font)
    }

    func testDeletePermanentlyOnlyFromRecentlyDeleted() throws {
        let (service, store) = makeService()
        let id = try service.create(title: "A", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        XCTAssertThrowsError(try service.deletePermanently(id))
        XCTAssertNotNil(store.note(with: id))
        try service.moveToRecentlyDeleted(id)
        try service.deletePermanently(id)
        XCTAssertNil(store.note(with: id))
        assertThrows(.notFound) { try service.deletePermanently(id) }
    }

    // MARK: List and search

    func testListPaginationIsStable() throws {
        let (service, store) = makeService()
        for index in 0..<120 { store.createNote(in: nil, initial: NSAttributedString(string: "Note \(index)")) }
        let pinned = store.notes[5].id
        store.togglePin(pinned)
        var seen: [UUID] = []
        var cursor: String?
        repeat {
            let page = try service.list(notebook: nil, tag: nil, query: nil, updatedSince: nil, deleted: .exclude, sort: .list,
                                        limit: 50, cursor: cursor)
            XCTAssertLessThanOrEqual(page.notes.count, 50)
            seen += page.notes.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(seen.count, 120)
        XCTAssertEqual(Set(seen).count, 120)
        XCTAssertEqual(seen.first, pinned)
        assertThrows(.invalidInput("That cursor isn't valid.")) {
            try service.list(notebook: nil, tag: nil, query: nil, updatedSince: nil, deleted: .exclude, sort: .list, limit: 5,
                             cursor: "%%%")
        }
    }

    private func page(_ service: AutomationService, limit: Int, after cursor: String?) throws -> ([UUID], String?) {
        let page = try service.list(notebook: nil, tag: nil, query: nil, updatedSince: nil, deleted: .exclude, sort: .list,
                                    limit: limit, cursor: cursor)
        return (page.notes.map(\.id), page.nextCursor)
    }

    func testEditingLastNoteOfPageBetweenPagesGivesNoDuplicates() throws {
        let (service, store) = makeService()
        for index in 0..<10 {
            let id = store.createNote(in: nil, initial: NSAttributedString(string: "Note \(index)")).id
            store.notes[store.noteIndex(id)!].updatedAt = clock.addingTimeInterval(-Double(index))
        }
        var (seen, cursor) = try page(service, limit: 4, after: nil)
        store.notes[store.noteIndex(seen[3])!].updatedAt = clock.addingTimeInterval(60)
        while let next = cursor {
            let (ids, after) = try page(service, limit: 4, after: next)
            seen += ids
            cursor = after
        }
        XCTAssertEqual(seen.count, 10)
        XCTAssertEqual(Set(seen).count, 10)
    }

    func testDeletingPinnedCursorNoteSkipsNothing() throws {
        let (service, store) = makeService()
        var pinned: [UUID] = []
        for index in 0..<6 {
            let id = store.createNote(in: nil, initial: NSAttributedString(string: "Note \(index)")).id
            store.notes[store.noteIndex(id)!].updatedAt = clock.addingTimeInterval(-Double(index))
            if index < 3 { store.togglePin(id); pinned.append(id) }
        }
        let (first, cursor) = try page(service, limit: 1, after: nil)
        XCTAssertEqual(first, [pinned[0]])
        try service.moveToRecentlyDeleted(pinned[0])
        let (second, _) = try page(service, limit: 2, after: cursor)
        XCTAssertEqual(second, [pinned[1], pinned[2]])
    }

    func testListUpdatedSince() throws {
        let (service, store) = makeService()
        let old = store.createNote(in: nil, initial: NSAttributedString(string: "Old")).id
        let new = store.createNote(in: nil, initial: NSAttributedString(string: "New")).id
        store.notes[store.noteIndex(old)!].updatedAt = clock.addingTimeInterval(-3600)
        store.notes[store.noteIndex(new)!].updatedAt = clock
        let deleted = store.createNote(in: nil, initial: NSAttributedString(string: "Gone")).id
        store.moveToRecentlyDeleted([deleted])
        let result = try service.list(notebook: nil, tag: nil, query: nil, updatedSince: clock.addingTimeInterval(-60),
                                      deleted: .exclude, sort: .updated, limit: 10, cursor: nil)
        XCTAssertEqual(result.notes.map(\.id), [new])
        let trash = try service.list(notebook: nil, tag: nil, query: nil, updatedSince: nil, deleted: .only, sort: .updated,
                                     limit: 10, cursor: nil)
        XCTAssertEqual(trash.notes.map(\.id), [deleted])
        let all = try service.list(notebook: nil, tag: nil, query: nil, updatedSince: nil, deleted: .include, sort: .updated,
                                   limit: 10, cursor: nil)
        XCTAssertEqual(Set(all.notes.map(\.id)), [old, new, deleted])
    }

    func testSearchSnippetAroundMatch() throws {
        let (service, _) = makeService()
        let before = (0..<30).map { "before\($0)" }.joined(separator: " ")
        let after = (0..<30).map { "after\($0)" }.joined(separator: " ")
        let id = try service.create(title: "Long", body: "\(before) Zebra \(after)", format: .text, notebook: nil, tags: [],
                                    pinned: false).id
        let hits = try service.search("zébra", notebook: nil, tag: nil, limit: 5)
        XCTAssertEqual(hits.map(\.0.id), [id])
        let snippet = try XCTUnwrap(hits.first?.snippet)
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("Zebra"))
        XCTAssertLessThanOrEqual(snippet.count, 165)
        XCTAssertFalse(snippet.dropFirst().hasPrefix(" "))
        XCTAssertTrue(snippet.dropFirst().split(separator: " ").first.map { $0.hasPrefix("before") } ?? false)
    }

    func testTagsWithCounts() throws {
        let (service, _) = makeService()
        _ = try service.create(title: "A", body: "", format: .text, notebook: nil, tags: ["work", "home"], pinned: false)
        _ = try service.create(title: "B", body: "", format: .text, notebook: nil, tags: ["work"], pinned: false)
        let gone = try service.create(title: "C", body: "", format: .text, notebook: nil, tags: ["old"], pinned: false).id
        try service.moveToRecentlyDeleted(gone)
        XCTAssertEqual(service.tags().map(\.name), ["home", "work"])
        XCTAssertEqual(service.tags().map(\.count), [1, 2])
    }

    // MARK: Shortcuts entities

    func testNoteEntityFromMeta() throws {
        let (service, store) = makeService()
        let work = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let meta = try service.create(title: "Plan", body: "steps", format: .text, notebook: .id(work.id), tags: ["q3"],
                                      pinned: false)
        let entity = service.noteEntity(meta)
        XCTAssertEqual(entity.id, meta.id)
        XCTAssertEqual(entity.title, "Plan")
        XCTAssertEqual(entity.notebookName, "Work")
        XCTAssertEqual(entity.tags, ["q3"])
        XCTAssertEqual(entity.createdAt, meta.createdAt)
        XCTAssertEqual(entity.modifiedAt, meta.updatedAt)

        let untitled = store.createNote(in: nil, initial: NSAttributedString(string: ""))
        let bare = service.noteEntity(untitled)
        XCTAssertEqual(bare.title, "New Note")
        XCTAssertNil(bare.notebookName)
    }

    func testEntityQueryExcludesRecentlyDeleted() throws {
        let (service, _) = makeService()
        let kept = try service.create(title: "Keep apples", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        let gone = try service.create(title: "Gone apples", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        try service.moveToRecentlyDeleted(gone)
        XCTAssertEqual(service.noteEntities(for: [gone, kept, UUID()]).map(\.id), [kept])
        XCTAssertEqual(try service.noteEntities(matching: "apples").map(\.id), [kept])
        XCTAssertEqual(service.suggestedNoteEntities().map(\.id), [kept])
    }

    func testSuggestedEntitiesAreTenMostRecent() throws {
        let (service, store) = makeService()
        var ids: [UUID] = []
        for index in 0..<15 {
            let id = store.createNote(in: nil, initial: NSAttributedString(string: "Note \(index)")).id
            store.notes[store.noteIndex(id)!].updatedAt = clock.addingTimeInterval(Double(index))
            ids.append(id)
        }
        store.togglePin(ids[0])
        store.notes[store.noteIndex(ids[0])!].updatedAt = clock.addingTimeInterval(-100)
        XCTAssertEqual(service.suggestedNoteEntities().map(\.id), Array(ids.suffix(10).reversed()))
        XCTAssertEqual(try service.noteEntities(matching: "  ").map(\.id), Array(ids.suffix(10).reversed()))
    }

    // MARK: Daily, limits, Markdown and attachments

    func testDailyUnavailableWhileGateOff() {
        let (service, store) = makeService(dailyAvailable: false)
        assertThrows(.dailyNotesUnavailable) { try service.daily(date: Date(), create: true) }
        assertThrows(.dailyNotesUnavailable) { try service.appendToDaily(text: "x", format: .plain, timestamp: true, date: Date()) }
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(store.notebooks.isEmpty)
    }

    /// 15:05 local time on the clock's day.
    private func afternoon() -> Date {
        Calendar.current.date(bySettingHour: 15, minute: 5, second: 0, of: clock)!
    }

    func testDailyCreateAndAppend() throws {
        let (service, store) = makeService()
        XCTAssertNil(try service.daily(date: clock, create: false))
        let created = try XCTUnwrap(try service.daily(date: clock, create: true))
        XCTAssertEqual(store.notebook(with: try XCTUnwrap(created.notebookID))?.name, NoteStore.dailyNotesNotebookName)
        XCTAssertEqual(try service.daily(date: clock, create: false)?.id, created.id)
        let appended = try service.appendToDaily(text: "Called Sam", format: .plain, timestamp: false, date: clock)
        XCTAssertEqual(appended.id, created.id)
        XCTAssertTrue(store.body(for: created.id).string.hasSuffix("\n- Called Sam"))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: clock)!
        let other = try service.appendToDaily(text: "Later", format: .plain, timestamp: false, date: tomorrow)
        XCTAssertNotEqual(other.id, created.id)
        assertThrows(.invalidInput("Give the text to add.")) {
            try service.appendToDaily(text: "  \n", format: .plain, timestamp: true, date: clock)
        }
    }

    func testDailyAppendGoesThroughDailyLogAppender() throws {
        clock = afternoon()
        let (service, store) = makeService()
        let meta = try service.appendToDaily(text: "Shipped\nthe build", format: .plain, timestamp: true, date: clock)
        let body = store.body(for: meta.id).string
        let expected = try XCTUnwrap(DailyLogLine.format(text: "Shipped\nthe build", at: clock, timeZone: .current))
        XCTAssertEqual(expected, "- 15:05 Shipped the build")
        XCTAssertTrue(body.hasSuffix("\n" + expected), body)
        XCTAssertFalse(body.contains("PM"))
    }

    func testDailyAppendMarkdownFormat() throws {
        let (service, store) = makeService()
        let meta = try service.appendToDaily(text: "Read **this** today", format: .markdown, timestamp: false, date: clock)
        let body = store.body(for: meta.id)
        XCTAssertTrue(body.string.hasSuffix("\n- Read this today"), body.string)
        XCTAssertFalse(body.string.contains("**"))
        let range = (body.string as NSString).range(of: "this", options: .backwards)
        let font = try XCTUnwrap(body.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testDailyAppendWithoutTimestamp() throws {
        clock = afternoon()
        let (service, store) = makeService()
        let meta = try service.appendToDaily(text: "No time", format: .plain, timestamp: false, date: clock)
        _ = try service.appendToDaily(text: "With time", format: .plain, timestamp: true, date: clock)
        let lines = store.body(for: meta.id).string.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.suffix(2)), ["- No time", "- 15:05 With time"])
    }

    func testDailyFromAutomationUsesTemplateWithoutClipboardOrCaret() throws {
        let (service, store) = makeService()
        let saved = NoteStore.clipboardString
        NoteStore.clipboardString = { "secret" }
        defer { NoteStore.clipboardString = saved }
        let template = store.createTemplate()
        store.updateBody(template.id, NSAttributedString(string: "{{title}}\nPlan\n{{clipboard}}{{cursor}}\n", attributes: EditorStyle.bodyAttributes))
        defaults.set(template.id.uuidString, forKey: PrefKey.dailyNoteTemplateID)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: clock)!
        let created = try XCTUnwrap(try service.daily(date: clock, create: true))
        let appended = try service.appendToDaily(text: "Ran", format: .plain, timestamp: false, date: tomorrow)
        for id in [created.id, appended.id] {
            XCTAssertTrue(store.body(for: id).string.contains("Plan"))
            XCTAssertFalse(store.body(for: id).string.contains("secret"))
            XCTAssertNil(RichTextEditor.pendingCaret[id])
        }
    }

    func testDailyAppendToLockedNoteFails() throws {
        let (service, store) = makeService()
        let meta = try XCTUnwrap(try service.daily(date: clock, create: true))
        lock(store, meta.id)
        assertThrows(.noteLocked) { try service.appendToDaily(text: "x", format: .plain, timestamp: true, date: clock) }
    }

    func testTextLimitIsEnforced() async throws {
        let (service, _) = makeService()
        let big = String(repeating: "a", count: AutomationService.maxTextBytes + 1)
        assertThrows(.tooLarge) { try service.create(title: nil, body: big, format: .text, notebook: nil, tags: [], pinned: false) }
        assertThrows(.tooLarge) { try service.create(title: nil, body: big, format: .markdown, notebook: nil, tags: [], pinned: false) }
        let id = try service.create(title: "A", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        await assertThrows(.tooLarge) { try await service.append(id, text: big, format: .text, position: .end, timestamp: false, ifRevision: nil) }
        XCTAssertNoThrow(try service.create(title: nil, body: String(big.dropFirst()), format: .text, notebook: nil, tags: [],
                                            pinned: false))
    }

    func testTextLimitCountsTitleBodyAndTagsTogether() async throws {
        let (service, _) = makeService()
        let half = String(repeating: "a", count: AutomationService.maxTextBytes / 2 + 1)
        assertThrows(.tooLarge) { try service.create(title: half, body: half, format: .text, notebook: nil, tags: [], pinned: false) }
        assertThrows(.tooLarge) { try service.create(title: nil, body: half, format: .text, notebook: nil, tags: [half], pinned: false) }
        assertThrows(.tooLarge) { try service.create(title: half, body: half, format: .markdown, notebook: .name("Nope"), tags: [],
                                                     pinned: false) }
        let id = try service.create(title: "A", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        await assertThrows(.tooLarge) { try await service.patch(id, title: half, body: (half, .text), notebookID: nil, pinned: nil, ifRevision: nil) }
    }

    func testProgrammaticTextExportsWithoutColor() async throws {
        let (service, store) = makeService()
        let id = try service.create(title: "From curl", body: "Pack bags", format: .text, notebook: nil,
                                    tags: ["travel"], pinned: false).id
        _ = try await service.append(id, text: "later", format: .text, position: .end, timestamp: false, ifRevision: nil)
        let captured = try XCTUnwrap(store.captureNote(title: "Captured", body: "quote", in: nil)).id
        let titled = try service.create(title: nil, body: "x", format: .text, notebook: nil, tags: [], pinned: false).id
        _ = try await service.patch(titled, title: "Renamed", body: ("", .text), notebookID: nil, pinned: nil, ifRevision: nil)
        for note in [id, captured, titled] {
            let exported = try service.body(note, format: .markdown)
            XCTAssertFalse(exported.contains("<span style=\"color"), exported)
        }
        XCTAssertTrue(try service.body(id, format: .markdown).contains("# From curl"))
    }

    func testUserTextColorStillExports() throws {
        let (service, store) = makeService()
        let id = try service.create(title: "Colors", body: "red words", format: .text, notebook: nil, tags: [], pinned: false).id
        try store.editBody(id, actionName: "Text Color") { storage in
            storage.addAttribute(.foregroundColor, value: EditorStyle.textColors[0].color,
                                 range: (storage.string as NSString).range(of: "red"))
        }
        XCTAssertTrue(try service.body(id, format: .markdown).contains("<span style=\"color: #DB332E\">red</span>"))
    }

    func testMarkdownRoundTripThroughNoteItMarkdown() async throws {
        let (service, store) = makeService()
        let staged = try service.staged.stage(pngData())
        let markdown = "# Plan\n\nSome **bold** text\n\n- one\n- two\n\n![pic.png](noteit-attachment:\(staged.id))\n"
        let id = try service.create(title: nil, body: markdown, format: .markdown, notebook: nil, tags: [], pinned: false).id
        let exported = try service.body(id, format: .markdown)
        XCTAssertTrue(exported.contains("# Plan"), exported)
        XCTAssertTrue(exported.contains("**bold**"), exported)
        XCTAssertTrue(exported.contains("- one"), exported)
        XCTAssertTrue(exported.contains("noteit-attachment%3A\(id.uuidString)/pic.png"), exported)

        service.staged.removeAll()
        let text = store.body(for: id).string
        _ = try await service.patch(id, title: nil, body: (exported, .markdown), notebookID: nil, pinned: nil, ifRevision: nil)
        XCTAssertEqual(store.body(for: id).string, text)
        XCTAssertEqual(try service.attachments(of: id).map(\.name), ["pic.png"])
        XCTAssertEqual(try service.body(id, format: .markdown), exported)
        XCTAssertTrue(try service.body(id, format: .html).contains("<strong>bold</strong>"))
        XCTAssertTrue(try service.body(id, format: .text).contains("- one"))

        let doc = try service.body(id, format: .noteitDoc)
        let copy = try service.create(title: nil, body: doc, format: .noteitDoc, notebook: nil, tags: [], pinned: false).id
        XCTAssertEqual(store.body(for: copy).string, text)
        assertThrows(.formatUnavailable("html")) {
            try service.create(title: nil, body: "<p>x</p>", format: .html, notebook: nil, tags: [], pinned: false)
        }
    }

    func testStagedImageResolves() throws {
        let (service, _) = makeService()
        let png = pngData()
        let staged = try service.staged.stage(png)
        XCTAssertTrue(StagedUploads.isValidID(staged.id))
        XCTAssertEqual(staged.expiresAt, clock.addingTimeInterval(3600))
        let id = try service.create(title: "Pic", body: "![shot.png](noteit-attachment:\(staged.id))", format: .markdown,
                                    notebook: nil, tags: [], pinned: false).id
        let files = try service.attachments(of: id)
        XCTAssertEqual(files.map(\.name), ["shot.png"])
        XCTAssertEqual(files.first?.contentType, "image/png")
        XCTAssertFalse(try service.attachment(of: id, named: "shot.png").data.isEmpty)

        clock = clock.addingTimeInterval(3601)
        XCTAssertNil(service.staged.data(for: staged.id))
        service.staged.purgeExpired(now: clock)
        XCTAssertFalse(fm.fileExists(atPath: service.staged.directory.appendingPathComponent(staged.id).path))
    }

    func testStagedUploadLimits() throws {
        let (service, _) = makeService()
        for _ in 0..<StagedUploads.maxFiles { _ = try service.staged.stage(Data([1])) }
        assertThrows(.tooLarge) { try service.staged.stage(Data([1])) }
        assertThrows(.invalidInput("The upload is empty.")) { try service.staged.stage(Data()) }
        XCTAssertNil(service.staged.data(for: "att_../../etc"))
    }

    func testUnknownImagePathIsNotRead() throws {
        let (service, _) = makeService()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("secret.png")
        try pngData().write(to: outside)
        let other = try service.create(title: "Other", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        _ = try service.addAttachment(to: other, data: pngData(), filename: "x.png", contentType: "image/png")
        let markdown = """
        ![a.png](\(outside.path))

        ![b.png](\(outside.absoluteString))

        ![c.png](../secret.png)

        ![d.png](noteit-attachment:\(other.uuidString)/x.png)

        ![e.png](noteit-attachment:att_AAAAAAAAAAAAAAAAAAAAAA)
        """
        let id = try service.create(title: "Refs", body: markdown, format: .markdown, notebook: nil, tags: [], pinned: false).id
        XCTAssertTrue(try service.attachments(of: id).isEmpty)
    }

    func testAddAttachmentSanitizesAndDeduplicates() throws {
        let (service, _) = makeService()
        let id = try service.create(title: "Files", body: "", format: .text, notebook: nil, tags: [], pinned: false).id
        _ = try service.addAttachment(to: id, data: Data("a".utf8), filename: "re/port:\u{7}.txt", contentType: "text/plain")
        _ = try service.addAttachment(to: id, data: Data("b".utf8), filename: "report.txt", contentType: "text/plain")
        _ = try service.addAttachment(to: id, data: pngData(), filename: "photo", contentType: "image/png")
        XCTAssertEqual(try service.attachments(of: id).map(\.name), ["report.txt", "report 2.txt", "photo.png"])
    }

    func testLinkIsNoteForm() {
        let id = UUID()
        XCTAssertEqual(AutomationService.link(for: id).absoluteString, "noteit://note/\(id.uuidString)")
    }

    func testClientsIssueListRevoke() throws {
        let (service, _) = makeService()
        let registry = ClientRegistry(store: InMemoryClientStore())
        let revoked = LockedIDs()
        registry.onRevoke = { revoked.append($0) }
        service.clients = AutomationClients(registry: registry)

        let (client, token) = try service.clients.issue(name: "  Shortcuts  ", kind: .script, scopes: [.write, .read], origin: nil)
        XCTAssertEqual(client.name, "Shortcuts")
        XCTAssertEqual(client.scopes, [.read, .write])
        XCTAssertTrue(token.hasPrefix("nit_"))
        XCTAssertEqual(registry.authenticate(bearer: "Bearer \(token)")?.id, client.id)
        XCTAssertEqual(service.clients.list().map(\.id), [client.id])

        try service.clients.revoke(client.id)
        XCTAssertEqual(service.clients.list(), [])
        XCTAssertEqual(revoked.ids, [client.id])
        XCTAssertNil(registry.authenticate(bearer: "Bearer \(token)"))
        assertThrows(.notFound) { try service.clients.revoke(client.id) }
        assertThrows(.invalidInput("Give the token a name.")) {
            try service.clients.issue(name: " ", kind: .script, scopes: [.read], origin: nil)
        }
    }
}

private final class LockedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID] = []
    var ids: [UUID] { lock.withLock { stored } }
    func append(_ id: UUID) { lock.withLock { stored.append(id) } }
}
