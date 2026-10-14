import AppKit
import XCTest
@testable import NoteIt

@MainActor
final class MarkdownImporterTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: base.appendingPathComponent("Library", isDirectory: true), seedsFreshLibrary: false))
    }

    @discardableResult
    private func write(_ text: String, to path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func importAll(_ urls: [URL], into store: NoteStore) async -> ImportReport {
        await MarkdownImporter(store: store).run(MarkdownImporter.items(for: urls)) { _ in }
    }

    private func note(titled title: String, in store: NoteStore) throws -> NoteMeta {
        try XCTUnwrap(store.notes.first { $0.title == title }, "no note titled \(title)")
    }

    func testFolderTreeBecomesNotebooks() async throws {
        let vault = base.appendingPathComponent("Vault", isDirectory: true)
        try write("# Inbox note\nHello", to: "Inbox note.md", in: vault)
        try write("Plain words", to: "Projects/Garden.md", in: vault)
        try write("# Deep\n", to: "Projects/Archive/Deep.markdown", in: vault)
        try write("Line one\nLine two", to: "Projects/Todo.txt", in: vault)
        try write("ignored", to: ".obsidian/workspace.md", in: vault)
        try write("ignored", to: ".trash/Old.md", in: vault)
        try write("ignored", to: ".hidden/Secret.md", in: vault)
        try write("ignored", to: "Projects/.draft.md", in: vault)
        try write("not a note", to: "Projects/data.json", in: vault)

        let store = makeStore()
        let report = await importAll([vault], into: store)

        XCTAssertEqual(report.notesImported, 4)
        XCTAssertEqual(report.notebooksUsed, 3)
        XCTAssertEqual(Set(store.notebooks.map(\.name)), ["Vault", "Vault / Projects", "Vault / Projects / Archive"])
        func notebookName(_ title: String) throws -> String? {
            let meta = try note(titled: title, in: store)
            return store.notebooks.first { $0.id == meta.notebookID }?.name
        }
        XCTAssertEqual(try notebookName("Inbox note"), "Vault")
        XCTAssertEqual(try notebookName("Garden"), "Vault / Projects")
        XCTAssertEqual(try notebookName("Deep"), "Vault / Projects / Archive")
        XCTAssertEqual(try notebookName("Todo"), "Vault / Projects")
        XCTAssertFalse(store.notes.contains { $0.title == "ignored" || $0.title == "Secret" || $0.title == "Old" })

        let todo = store.body(for: try note(titled: "Todo", in: store).id)
        XCTAssertEqual(todo.string, "Todo\nLine one\nLine two\n")
        XCTAssertEqual(report.summary, "Imported 4 notes into 3 notebooks.")
    }

    func testExistingNotebookIsReused() async throws {
        let store = makeStore()
        let existing = store.createNotebook(name: "recipes", symbol: "book", colorHex: Tokens.Hex.notebookRed)
        let folder = base.appendingPathComponent("Recipes", isDirectory: true)
        try write("Flour and water", to: "Bread.md", in: folder)

        _ = await importAll([folder], into: store)

        XCTAssertEqual(store.notebooks.count, 1)
        XCTAssertEqual(try note(titled: "Bread", in: store).notebookID, existing.id)
    }

    func testLooseFilesGoIntoTheirFolderNotebook() async throws {
        let folder = base.appendingPathComponent("Loose", isDirectory: true)
        let file = try write("Some text", to: "One.md", in: folder)
        let store = makeStore()
        _ = await importAll([file], into: store)
        XCTAssertEqual(store.notebooks.map(\.name), ["Loose"])
        XCTAssertEqual(store.notes.count, 1)
    }

    func testDatesFromFrontMatterAndFile() async throws {
        let folder = base.appendingPathComponent("Dated", isDirectory: true)
        try write("---\ncreated: 2021-01-02T03:04:05Z\nupdated: 2022-06-07T08:09:10Z\n---\nBody", to: "With front matter.md", in: folder)
        let plain = try write("Body", to: "Without.md", in: folder)
        let created = ISO8601DateFormatter().date(from: "2019-05-01T10:00:00Z")!
        let modified = ISO8601DateFormatter().date(from: "2020-08-15T12:30:00Z")!
        try fm.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: plain.path)

        let store = makeStore()
        _ = await importAll([folder], into: store)

        let a = try note(titled: "With front matter", in: store)
        XCTAssertEqual(a.createdAt, ISO8601DateFormatter().date(from: "2021-01-02T03:04:05Z"))
        XCTAssertEqual(a.updatedAt, ISO8601DateFormatter().date(from: "2022-06-07T08:09:10Z"))
        let b = try note(titled: "Without", in: store)
        XCTAssertEqual(b.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(b.updatedAt.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
    }

    func testImportedNotesPersistAndAreSearchable() async throws {
        let folder = base.appendingPathComponent("Persist", isDirectory: true)
        try write("---\ntags: [kitchen]\nupdated: 2020-01-01\n---\n# Pancakes\nWhisk the eggs", to: "Pancakes.md", in: folder)
        let store = makeStore()
        _ = await importAll([folder], into: store)
        let meta = try note(titled: "Pancakes", in: store)
        XCTAssertEqual(meta.tags, ["kitchen"])
        XCTAssertNotNil(meta.revision)

        let reloaded = makeStore()
        let again = try note(titled: "Pancakes", in: reloaded)
        XCTAssertEqual(meta.updatedAt, MarkdownReader.date(from: "2020-01-01"))
        XCTAssertEqual(meta.createdAt, meta.updatedAt, "a file newer than its front matter date doesn't make the note newer")
        XCTAssertEqual(again.updatedAt, meta.updatedAt)
        XCTAssertTrue(reloaded.body(for: again.id).string.contains("Whisk the eggs"))
        XCTAssertEqual(store.notes(for: .allNotes, search: "whisk").map(\.id), [meta.id])
        XCTAssertEqual(reloaded.notes(for: .allNotes, search: "whisk").map(\.id), [again.id])
    }

    func testTextBundleWithAsset() async throws {
        let folder = base.appendingPathComponent("Bear", isDirectory: true)
        let bundle = folder.appendingPathComponent("Bird watching.textbundle", isDirectory: true)
        try write("# Bird watching\nSaw a robin #nature/birds\n\n![](assets/robin.png)\n", to: "text.md", in: bundle)
        try fm.createDirectory(at: bundle.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try MarkdownReaderTests.pngData().write(to: bundle.appendingPathComponent("assets/robin.png"))
        try write(#"{"version": 2, "net.shinyfrog.bear": {"creationDate": "2023-04-05T06:07:08Z", "modificationDate": "2023-04-06T06:07:08Z"}}"#,
                  to: "info.json", in: bundle)

        let store = makeStore()
        let report = await importAll([folder], into: store)
        XCTAssertEqual(report.notesImported, 1)

        let meta = try note(titled: "Bird watching", in: store)
        XCTAssertEqual(meta.createdAt, ISO8601DateFormatter().date(from: "2023-04-05T06:07:08Z"))
        XCTAssertEqual(meta.updatedAt, ISO8601DateFormatter().date(from: "2023-04-06T06:07:08Z"))
        let body = store.body(for: meta.id)
        XCTAssertTrue(body.string.contains("#nature/birds"), "Bear tags stay as typed")
        var names: [String] = []
        body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            if let name = (value as? NSTextAttachment)?.fileWrapper?.preferredFilename { names.append(name) }
        }
        XCTAssertEqual(names, ["robin.png"])
    }

    func testTextPack() async throws {
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let bundle = staging.appendingPathComponent("Packed.textbundle", isDirectory: true)
        try write("# Packed note\nInside a zip", to: "text.md", in: bundle)
        let pack = base.appendingPathComponent("Packed.textpack")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", bundle.path, pack.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let store = makeStore()
        let report = await importAll([pack], into: store)
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertTrue(store.body(for: try note(titled: "Packed note", in: store).id).string.contains("Inside a zip"))
    }

    func testObsidianImageFoundByName() async throws {
        let vault = base.appendingPathComponent("Vault", isDirectory: true)
        try write("Photo: ![[cat.png]]", to: "Notes/Pets.md", in: vault)
        try fm.createDirectory(at: vault.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
        try MarkdownReaderTests.pngData().write(to: vault.appendingPathComponent("Attachments/cat.png"))

        let store = makeStore()
        _ = await importAll([vault], into: store)
        let body = store.body(for: try note(titled: "Pets", in: store).id)
        XCTAssertNotNil(body.attribute(.attachment, at: (body.string as NSString).range(of: "\u{FFFC}").location, effectiveRange: nil))
    }

    func testCancelStopsEarly() async throws {
        let folder = base.appendingPathComponent("Many", isDirectory: true)
        for i in 0..<5 { try write("Note \(i)", to: "\(i).md", in: folder) }
        let store = makeStore()
        let items = MarkdownImporter.items(for: [folder])
        let task = Task { @MainActor in
            await MarkdownImporter(store: store).run(items) { progress in
                if progress.completed == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertLessThan(report.notesImported, 5)
        XCTAssertEqual(store.notes.count, report.notesImported)
    }

    func testSummaryWording() {
        var report = ImportReport()
        report.notesImported = 132
        report.notebookIDs = Set((0..<6).map { _ in UUID() })
        report.lockedSkipped = 3
        XCTAssertEqual(report.summary, "Imported 132 notes into 6 notebooks. Skipped 3 locked notes.")
        report.lockedSkipped = 1
        report.attachmentsSkipped = 2
        XCTAssertEqual(report.summary, "Imported 132 notes into 6 notebooks. Skipped 1 locked note and 2 attachments.")
    }
}
