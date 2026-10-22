import AppKit
import XCTest
import NoteItAPI
import NoteItCore
@testable import NoteIt

/// A Markdown library end to end: what automation writes lands in the files, and what other apps write to the files
/// reaches search, tasks, reminders, links, Spotlight, notebooks, tags and smart folders.
@MainActor
final class MarkdownIntegrationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let fm = FileManager.default
    private var content: URL { root.appendingPathComponent("content", isDirectory: true) }
    private var data: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var stores: [NoteStore] = []

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("noteit-md-integration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        suiteName = "noteit-md-integration-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        stores.forEach { $0.flush() }
        stores = []
        defaults.removePersistentDomain(forName: suiteName)
        try? fm.removeItem(at: root)
    }

    private func open(links: Bool = false) -> NoteStore {
        let store = NoteStore.opened(location: LibraryLocation(url: data, seedsFreshLibrary: false, format: .markdown, contentRootURL: content,
                                                        renameFilesOnTitleChange: false),
                              bodyStorage: MarkdownBodyStorageTests.make(root, renames: false))
        store.preferences = defaults
        store.markdownClock = { Date().addingTimeInterval(10) }
        store.markdownFlushWait = 10
        store.waitForMarkdownWrites(upTo: 10)
        if links { store.installLinkIndex() }
        stores.append(store)
        return store
    }

    private func put(_ path: String, _ text: String) throws {
        let url = content.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: content.appendingPathComponent(path), encoding: .utf8)
    }

    /// The note's file, from the index.
    private func file(_ store: NoteStore, _ id: UUID) throws -> (path: String, text: String) {
        let path = try XCTUnwrap(store.markdownStorage?.index.entry(id)?.path, "note \(id) has no file")
        return (path, try read(path))
    }

    private func note(_ store: NoteStore, titled title: String) throws -> NoteMeta {
        try XCTUnwrap(store.notes.first { $0.title == title }, "no note titled \(title)")
    }

    private func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func handlers(_ store: NoteStore) -> LocalAPIHandlers {
        let staged = StagedUploads(directory: root.appendingPathComponent("staged"))
        let service = AutomationService(store: store, defaults: defaults, staged: staged, dailyNotesAvailable: { true },
                                        isLoading: { false })
        return LocalAPIHandlers(service: service, registry: LocalAPIRouteRegistry(), openNote: { _ in })
    }

    private func call(_ handlers: LocalAPIHandlers, _ route: RouteID, params: [String: String] = [:],
                      body: some Encodable) async throws -> NoteDTO {
        let spec = try XCTUnwrap(APIRoutes.all.first { $0.id == route.rawValue })
        let request = HTTPRequest(method: spec.method.rawValue, path: spec.pattern, query: [:], headers: HTTPHeaders([]),
                                  body: try APIJSON.encoder().encode(body))
        let client = ClientRecord(id: UUID(), name: "Test", kind: .script, scopes: [.read, .write], origin: nil, tokenHash: "h",
                                  tokenHint: "nit_test", createdAt: Date())
        let response = await handlers.respond(LocalAPIContext(request: request, route: RouteMatch(spec: spec, params: params),
                                                               client: client, origin: .native))
        XCTAssertLessThan(response.status, 300, String(decoding: response.body, as: UTF8.self))
        return try APIJSON.decoder().decode(NoteDTO.self, from: response.body)
    }

    // MARK: Automation → files

    func testLocalAPIAndAutomationWritesEndUpInTheMarkdownFiles() async throws {
        let store = open()
        let work = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let api = handlers(store)

        let created = try await call(api, .noteCreate, body: CreateNoteRequest(title: "Groceries", body: "- Milk", notebook: "Work",
                                                                               tags: ["home"]))
        let id = created.summary.id
        store.flush()
        var saved = try file(store, id)
        XCTAssertEqual(saved.path, "Work/Groceries.md")
        XCTAssertTrue(saved.text.hasPrefix("---\nid: \(id.uuidString)"), saved.text)
        XCTAssertTrue(saved.text.contains("Milk"), saved.text)
        XCTAssertTrue(saved.text.contains("#home"), saved.text)
        XCTAssertEqual(store.note(with: id)?.notebookID, work.id)

        _ = try await call(api, .notePatch, params: ["id": id.uuidString],
                           body: PatchNoteRequest(body: "Groceries\n\n- Bread", format: .markdown, notebookID: nil))
        _ = try await call(api, .noteAppend, params: ["id": id.uuidString],
                           body: AppendRequest(text: "- Eggs", format: .markdown, timestamp: false))
        store.flush()
        saved = try file(store, id)
        XCTAssertTrue(saved.text.contains("Bread"), saved.text)
        XCTAssertTrue(saved.text.contains("Eggs"), saved.text)
        XCTAssertFalse(saved.text.contains("Milk"), saved.text)

        let daily = try await call(api, .dailyAppend, body: DailyAppendRequest(text: "Called Sam", timestamp: false))
        store.flush()
        saved = try file(store, daily.summary.id)
        XCTAssertTrue(saved.path.hasPrefix(NoteStore.dailyNotesNotebookName + "/"), saved.path)
        XCTAssertTrue(saved.text.contains("Called Sam"), saved.text)

        let reopened = open()
        XCTAssertTrue(reopened.body(for: id).string.contains("Eggs"))
        XCTAssertEqual(reopened.note(with: id)?.notebookID, work.id)
        XCTAssertTrue(reopened.body(for: daily.summary.id).string.contains("Called Sam"))
    }

    // MARK: Files → derived indexes

    func testAnEditInAnotherAppReachesSearchTasksRemindersAndLinks() async throws {
        try put("Target.md", "# Target\n\nthe place\n")
        try put("Source.md", "# Source\n\nnothing yet\n")
        let store = open(links: true)
        let target = try note(store, titled: "Target").id
        let source = try note(store, titled: "Source").id
        XCTAssertEqual(store.backlinks(to: target).map(\.source), [])

        try put("Source.md", try read("Source.md").replacingOccurrences(of: "# Source\n\nnothing yet\n", with: """
            # Renamed Source

            zebra crossing, see [[Target]]

            - [ ] pay rent @due(2030-01-02)
            call the bank @remind(2030-01-03 09:00)

            """))
        store.markdownFolderNeedsScan()

        try await waitUntil("the background scan applies the edit") { store.note(with: source)?.title == "Renamed Source" }
        try await waitUntil("search finds the new words") {
            store.searchResults(for: .allNotes, search: "zebra", order: .bestMatch).map(\.note.id) == [source]
        }
        let tasks = store.tasks(query: "", includeCompleted: false).values.flatMap { $0 }
        XCTAssertEqual(tasks.filter { $0.ref.noteID == source }.map(\.line.due), [LocalDateTime(year: 2030, month: 1, day: 2)])
        XCTAssertTrue(store.liveReminders().contains { $0.noteID == source && $0.line.text.contains("call the bank") })
        try await waitUntil("the link reaches the backlinks") { store.backlinks(to: target).map(\.source) == [source] }
    }

    func testFilesAddedDeletedAndMovedInAnotherAppReachSpotlightAndTheIndexes() async throws {
        try put("Work/.noteit-notebook.json", "{}")
        try put("Stays.md", "# Stays\n\nfirst\n")
        try put("Gone.md", "# Gone\n\nwalrus\n")
        let store = open(links: true)
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: store, defaults: defaults, index: fake, isSupported: true, flushDelay: 60)
        indexer.start()
        let stays = try note(store, titled: "Stays").id
        let gone = try note(store, titled: "Gone").id
        let work = try XCTUnwrap(store.notebooks.first { $0.name == "Work" }).id
        try await waitUntil("the first rebuild is done") { fake.items[gone.uuidString] != nil }
        await indexer.settle()

        try put("Added.md", "# Added\n\nnarwhal, see [[Stays]]\n")
        try fm.removeItem(at: content.appendingPathComponent("Gone.md"))
        try fm.moveItem(at: content.appendingPathComponent("Stays.md"), to: content.appendingPathComponent("Work/Stays.md"))
        store.newFileSettleDelay = 0
        _ = await store.rescanMarkdownFolder()
        let added = try note(store, titled: "Added").id
        indexer.flush()
        await indexer.settle()

        XCTAssertNotNil(fake.items[added.uuidString], "an added file is indexed")
        XCTAssertNil(fake.items[gone.uuidString], "a deleted file leaves Spotlight")
        XCTAssertNotNil(store.note(with: gone)?.deletedAt)
        XCTAssertEqual(store.note(with: stays)?.notebookID, work)
        try await waitUntil("search follows the files") {
            store.searchResults(for: .allNotes, search: "narwhal", order: .bestMatch).map(\.note.id) == [added]
                && store.searchResults(for: .allNotes, search: "walrus", order: .bestMatch).isEmpty
        }
        XCTAssertEqual(store.notes(for: .notebook(work), search: "").map(\.id), [stays])
        try await waitUntil("the new file's link is indexed") { store.backlinks(to: stays).map(\.source) == [added] }
    }

    // MARK: Organise after a reload

    func testNestedNotebooksTagsAndSmartFoldersSurviveAReload() throws {
        let store = open()
        let work = store.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let projects = store.createNotebook(name: "Projects", symbol: "folder", colorHex: "#0A84FF", parentID: work.id)
        let plan = store.createNote(in: projects.id, initial: NSAttributedString(string: "Plan\n#area/garden roses")).id
        let other = store.createNote(in: work.id, initial: NSAttributedString(string: "Other\n#area tulips")).id
        _ = store.createNote(in: nil, initial: NSAttributedString(string: "Loose\n#home"))
        let folder = try store.createSmartFolder(name: "Garden", query: "tag:area/garden")
        store.flush()
        XCTAssertTrue(fm.fileExists(atPath: content.appendingPathComponent("Work/Projects/Plan.md").path))

        let reopened = open()
        XCTAssertEqual(reopened.notebook(with: projects.id)?.parent, work.id)
        XCTAssertEqual(reopened.note(with: plan)?.notebookID, projects.id)
        XCTAssertEqual(Set(reopened.notes(for: .notebook(work.id), search: "").map(\.id)), [plan, other])
        XCTAssertEqual(Set(reopened.notes(for: .tag("area"), search: "").map(\.id)), [plan, other])
        XCTAssertEqual(reopened.notes(for: .tag("area/garden"), search: "").map(\.id), [plan])
        XCTAssertEqual(reopened.notes(for: .smartFolder(folder.id), search: "").map(\.id), [plan])
        XCTAssertEqual(reopened.notes(for: .smartFolder(folder.id), search: "roses").map(\.id), [plan])
    }
}
