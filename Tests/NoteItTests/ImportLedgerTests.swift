import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class ImportLedgerTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-ledger-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: base.appendingPathComponent("Library", isDirectory: true), seedsFreshLibrary: false))
    }

    private func importFolder(_ folder: URL, into store: NoteStore) async -> ImportReport {
        await MarkdownImporter(store: store).run(MarkdownImporter.items(for: [folder])) { _ in }
    }

    // MARK: Ledger

    func testStatusFollowsSourceAndContent() {
        let ledger = ImportLedger(url: nil)
        let id = UUID()
        let first = ImportIdentity(source: "a", content: "one")
        XCTAssertEqual(ledger.status(of: first, noteExists: { _ in true }), .new)

        ledger.record(first, noteID: id)
        XCTAssertEqual(ledger.status(of: first, noteExists: { _ in true }), .alreadyImported(id))
        XCTAssertEqual(ledger.status(of: ImportIdentity(source: "a", content: "two"), noteExists: { _ in true }), .changed)
        XCTAssertEqual(ledger.status(of: ImportIdentity(source: "b", content: "one"), noteExists: { _ in true }), .new)
    }

    func testDeletedForGoodNotesAreImportedAgain() {
        let ledger = ImportLedger(url: nil)
        let identity = ImportIdentity(source: "a", content: "one")
        ledger.record(identity, noteID: UUID())
        XCTAssertEqual(ledger.status(of: identity, noteExists: { _ in false }), .new)
        XCTAssertEqual(ledger.status(of: ImportIdentity(source: "a", content: "two"), noteExists: { _ in false }), .new)
    }

    func testLedgerSurvivesRelaunch() {
        let url = base.appendingPathComponent(ImportLedger.fileName)
        let id = UUID()
        let identity = ImportIdentity(source: "a", content: "one")
        let ledger = ImportLedger(url: url)
        ledger.record(identity, noteID: id)
        ledger.save()
        XCTAssertEqual(ImportLedger(url: url).status(of: identity, noteExists: { _ in true }), .alreadyImported(id))
    }

    func testUnreadableLedgerStartsEmpty() throws {
        let url = base.appendingPathComponent(ImportLedger.fileName)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ImportLedger(url: url).status(of: ImportIdentity(source: "a", content: "x"), noteExists: { _ in true }), .new)
    }

    // MARK: Summary

    func testSummaryMentionsSkippedAndChangedNotes() {
        var report = ImportReport()
        report.notesImported = 2
        report.notebookIDs = [UUID()]
        report.notesAlreadyImported = 3
        report.notesChanged = 1
        XCTAssertEqual(report.summary, "Imported 2 notes into 1 notebook. 3 notes were already imported and left as they are. 1 note had changed since it was imported, so it came in as a new note.")

        report = ImportReport()
        report.notesAlreadyImported = 1
        XCTAssertEqual(report.summary, "Nothing new to import. 1 note was already imported and left as it is.")
    }

    // MARK: Markdown

    func testImportingAFolderTwiceMakesNoDuplicates() async throws {
        let vault = base.appendingPathComponent("Vault", isDirectory: true)
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        try "# One\nHello".write(to: vault.appendingPathComponent("One.md"), atomically: true, encoding: .utf8)
        try "# Two\nWorld".write(to: vault.appendingPathComponent("Two.md"), atomically: true, encoding: .utf8)
        let store = makeStore()

        let first = await importFolder(vault, into: store)
        XCTAssertEqual(first.notesImported, 2)
        let count = store.notes.count

        let second = await importFolder(vault, into: store)
        XCTAssertEqual(second.notesImported, 0)
        XCTAssertEqual(second.notesAlreadyImported, 2)
        XCTAssertEqual(store.notes.count, count)
        XCTAssertEqual(second.summary, "Nothing new to import. 2 notes were already imported and left as they are.")
    }

    func testChangedFileComesInAsANewNote() async throws {
        let vault = base.appendingPathComponent("Vault", isDirectory: true)
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        let file = vault.appendingPathComponent("One.md")
        try "# One\nHello".write(to: file, atomically: true, encoding: .utf8)
        try "# Two\nWorld".write(to: vault.appendingPathComponent("Two.md"), atomically: true, encoding: .utf8)
        let store = makeStore()
        _ = await importFolder(vault, into: store)
        let count = store.notes.count

        try "# One\nHello again".write(to: file, atomically: true, encoding: .utf8)
        let report = await importFolder(vault, into: store)
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertEqual(report.notesChanged, 1)
        XCTAssertEqual(report.notesAlreadyImported, 1)
        XCTAssertEqual(store.notes.count, count + 1)

        // The new version is remembered too.
        let again = await importFolder(vault, into: store)
        XCTAssertEqual(again.notesImported, 0)
        XCTAssertEqual(again.notesAlreadyImported, 2)
    }

    func testNoteDeletedForGoodIsImportedAgain() async throws {
        let vault = base.appendingPathComponent("Vault", isDirectory: true)
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        try "# One\nHello".write(to: vault.appendingPathComponent("One.md"), atomically: true, encoding: .utf8)
        let store = makeStore()
        _ = await importFolder(vault, into: store)
        let imported = try XCTUnwrap(store.notes.first { $0.title == "One" })
        store.moveToRecentlyDeleted([imported.id])
        let whileDeleted = await importFolder(vault, into: store)
        XCTAssertEqual(whileDeleted.notesAlreadyImported, 1, "a note in Recently Deleted can still be restored")

        store.deleteNow([imported.id])
        let report = await importFolder(vault, into: store)
        XCTAssertEqual(report.notesImported, 1)
    }
}
