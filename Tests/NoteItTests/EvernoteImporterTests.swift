import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class EvernoteImporterTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-enex-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeStore() -> NoteStore {
        NoteStore(location: LibraryLocation(url: base.appendingPathComponent("Library", isDirectory: true), seedsFreshLibrary: false))
    }

    private func note(_ title: String, content: String, created: String = "20240102T030405Z",
                      updated: String = "20240203T040506Z", tags: [String] = [], extra: String = "") -> String {
        """
        <note><title>\(title)</title><created>\(created)</created><updated>\(updated)</updated>
        \(tags.map { "<tag>\($0)</tag>" }.joined())
        <content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>\(content)</en-note>]]></content>
        \(extra)</note>
        """
    }

    private func resource(_ data: Data, mime: String, fileName: String? = nil) -> String {
        """
        <resource><data encoding="base64">
        \(data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]))
        </data><mime>\(mime)</mime>\(fileName.map { "<resource-attributes><file-name>\($0)</file-name></resource-attributes>" } ?? "")</resource>
        """
    }

    @discardableResult
    private func enex(_ notes: [String], to path: String) throws -> URL {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
        <en-export export-date="20240301T000000Z" application="Evernote" version="10">
        \(notes.joined(separator: "\n"))
        </en-export>
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func meta(_ title: String, in store: NoteStore) throws -> NoteMeta {
        try XCTUnwrap(store.notes.first { $0.title == title }, "no note titled \(title)")
    }

    private func attachmentNames(_ body: NSAttributedString) -> [String] {
        var names: [String] = []
        body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { names.append(attachment.fileWrapper?.preferredFilename ?? "") }
        }
        return names
    }

    private func links(_ body: NSAttributedString) -> [NoteLink] {
        var out: [NoteLink] = []
        body.enumerateAttribute(.link, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            if let url = value as? URL, let link = NoteLink(url: url) { out.append(link) }
        }
        return out
    }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    func testNoteWithDatesTagsAndChecklist() async throws {
        let url = try enex([note("Groceries", content: """
            <div>Weekly list</div><div><en-todo checked="false"/>Milk</div><div><en-todo checked="true"/>Bread</div>
            """, tags: ["Home", "shopping list", "2024"])], to: "Personal.enex")
        let store = makeStore()
        let report = await EvernoteImporter.importFiles([url], into: store)

        XCTAssertEqual(report.notesImported, 1)
        XCTAssertEqual(store.notebooks.map(\.name), ["Personal"])
        let groceries = try meta("Groceries", in: store)
        XCTAssertEqual(groceries.createdAt, ISO8601DateFormatter().date(from: "2024-01-02T03:04:05Z"))
        XCTAssertEqual(groceries.updatedAt, ISO8601DateFormatter().date(from: "2024-02-03T04:05:06Z"))
        let body = store.body(for: groceries.id)
        let lines = body.string.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Groceries")
        XCTAssertTrue(lines.contains("Weekly list"))
        XCTAssertTrue(lines.contains(EditorStyle.markerText(.checkbox(checked: false), level: 0) + "Milk"), body.string)
        XCTAssertTrue(lines.contains(EditorStyle.markerText(.checkbox(checked: true), level: 0) + "Bread"), body.string)
        XCTAssertTrue(lines.contains("#home #shopping-list #_2024"), body.string)
        XCTAssertFalse(body.string.contains { ENMLConverter.markers.contains(String($0)) })
        XCTAssertEqual(Set(groceries.tags), ["home", "shopping-list", "_2024"])
    }

    func testChecklistInTableCellStaysInTheTable() throws {
        let parsed = try XCTUnwrap(ENEXNoteParser.parse(Data(note("Shop", content: """
            <table><tr><td><en-todo checked="true"/>Buy milk</td><td><en-todo checked="false"/>Eggs</td></tr></table>
            """).utf8)))
        var report = ImportReport()
        let body = EvernoteImporter.body(for: parsed, title: "Shop", report: &report)
        let ns = body.string as NSString
        for (text, mark) in [("Buy milk", "☑"), ("Eggs", "☐")] {
            let found = ns.range(of: text)
            XCTAssertNotEqual(found.location, NSNotFound, body.string)
            let paragraph = ns.paragraphRange(for: found)
            let style = body.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertFalse(style?.textBlocks.isEmpty ?? true, "\(text) left the table")
            XCTAssertTrue(ns.substring(with: paragraph).hasPrefix(mark + " "), ns.substring(with: paragraph))
        }
        XCTAssertEqual(body.attribute(.strikethroughStyle, at: ns.range(of: "Buy milk").location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertNil(body.attribute(.strikethroughStyle, at: ns.range(of: "Eggs").location, effectiveRange: nil))
    }

    func testTagsAreMadeValid() {
        XCTAssertEqual(ImportTags.sanitized("Work Stuff"), "work-stuff")
        XCTAssertEqual(ImportTags.sanitized("2024"), "_2024")
        XCTAssertEqual(ImportTags.sanitized("a/b/c/d/e/f/g"), "a/b/c/d/e-f-g")
        XCTAssertNil(ImportTags.sanitized("   "))
        XCTAssertNil(ImportTags.sanitized("!!!"))
        XCTAssertEqual(ImportTags.sanitized("C++"), "c-plus-plus")
        XCTAssertEqual(ImportTags.sanitized("C#"), "c-sharp")
        XCTAssertEqual(ImportTags.sanitized("+++"), "plus-plus-plus")
        XCTAssertEqual(ImportTags.sanitized("R&D"), "r-and-d")
        XCTAssertEqual(ImportTags.sanitized("#todo"), "todo")
    }

    func testDistinctTagsStayDistinctAndDroppedOnesAreCounted() async throws {
        let url = try enex([
            note("One", content: "<div>x</div>", tags: ["C++", "C#", "!!!", "Work"]),
            note("Two", content: "<div>y</div>", tags: ["c-sharp", "🎉", "work", "C#"]),
        ], to: "Tags.enex")
        let store = makeStore()
        let report = await EvernoteImporter.importFiles([url], into: store)
        XCTAssertEqual(Set(try meta("One", in: store).tags), ["c-plus-plus", "c-sharp", "work"])
        XCTAssertEqual(Set(try meta("Two", in: store).tags), ["c-sharp-2", "c-sharp", "work"])
        XCTAssertEqual(report.tagsSkipped, 2)
        XCTAssertTrue(report.summary.contains("2 tags with no letters or numbers"), report.summary)
    }

    func testResourcesBecomeAttachments() async throws {
        let pdf = Data("%PDF-1.4 tiny".utf8)
        let loose = Data("loose".utf8)
        let url = try enex([note("Receipt", content: """
            <div>Photo:</div><div><en-media type="image/png" hash="\(EvernoteImporter.md5(Self.png))"/></div>\
            <div><en-media type="application/pdf" hash="\(EvernoteImporter.md5(pdf))"></en-media></div>\
            <div><en-media type="image/png" hash="00000000000000000000000000000000"/>gone</div>
            """, extra: resource(Self.png, mime: "image/png")
                + resource(pdf, mime: "application/pdf", fileName: "Receipt March.pdf")
                + resource(loose, mime: "text/plain", fileName: "notes"))], to: "Docs.enex")
        let store = makeStore()
        let report = await EvernoteImporter.importFiles([url], into: store)
        XCTAssertEqual(report.attachmentsSkipped, 0)
        let body = store.body(for: try meta("Receipt", in: store).id)
        XCTAssertEqual(attachmentNames(body), ["image-1.png", "Receipt March.pdf", "notes.txt"])
        XCTAssertLessThan(body.string.range(of: "Photo:")!.lowerBound, body.string.firstIndex(of: "\u{FFFC}")!)
        XCTAssertTrue(body.string.contains("gone"))
    }

    func testEncryptedSectionsAndOversizedResourcesAreReported() async throws {
        let url = try enex([note("Secret", content: """
            <div>Visible</div><en-crypt hint="pet" cipher="AES" length="128">U2FsdGVkX19=</en-crypt><div>After</div>
            """)], to: "Vault.enex")
        let store = makeStore()
        let report = await EvernoteImporter.importFiles([url], into: store)
        XCTAssertEqual(report.encryptedSectionsSkipped, 1)
        let body = store.body(for: try meta("Secret", in: store).id).string
        XCTAssertTrue(body.contains("Visible") && body.contains("After"))
        XCTAssertFalse(body.contains("U2FsdGVkX19"))
        XCTAssertTrue(report.summary.contains("1 note had encrypted sections that were skipped."), report.summary)

        var big = ImportReport()
        let parsed = try XCTUnwrap(ENEXNoteParser.parse(Data(note("Big", content: "x", extra: """
            <resource><data encoding="base64">\(String(repeating: "QUFB", count: 9_000_000))</data><mime>image/png</mime></resource>
            """).utf8)))
        XCTAssertEqual(parsed.resourcesTooLarge, 1)
        XCTAssertTrue(parsed.resources.isEmpty)
        _ = EvernoteImporter.body(for: parsed, title: "Big", report: &big)
        XCTAssertEqual(big.attachmentsSkipped, 1)
    }

    func testMalformedNoteIsSkippedAndOthersImport() async throws {
        let broken = "<note><title>Broken &bad; <b></title><content>oops</note>"
        let sloppy = note("Sloppy", content: "<div>Unclosed <b>bold<p>para</div></en-note><div>tail")
        let url = try enex([note("First", content: "<div>one</div>"), broken, sloppy,
                            note("Last", content: "<div>two</div>")], to: "Mixed.enex")
        let store = makeStore()
        let report = await EvernoteImporter.importFiles([url], into: store)
        XCTAssertEqual(report.notesImported, 3)
        XCTAssertEqual(report.notesSkipped, 1)
        XCTAssertEqual(Set(store.notes.map(\.title)), ["First", "Sloppy", "Last"])
        XCTAssertTrue(store.body(for: try meta("Sloppy", in: store).id).string.contains("tail"))
    }

    func testUnreadableAndNonExportFilesAreReported() async throws {
        let good = try enex([note("Fine", content: "x")], to: "Good.enex")
        let junk = base.appendingPathComponent("Junk.enex")
        try "just text".write(to: junk, atomically: true, encoding: .utf8)
        let locked = try enex([note("Hidden", content: "x")], to: "Locked.enex")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let store = makeStore()
        let report = await EvernoteImporter.importFiles([good, junk, locked], into: store)
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertEqual(report.filesSkipped, 2)
    }

    func testEvernoteLinksPointAtImportedNotes() async throws {
        let url = try enex([
            note("Index", content: """
                <div><a href="evernote:///view/123/s1/abc-def/abc-def/">Trip plan</a> and \
                <a href="https://www.evernote.com/shard/s1/nl/123/abc/">Elsewhere</a> and \
                <a href="https://example.com/">site</a></div>
                """),
            note("Trip plan", content: "<div>Pack</div>"),
            note("Trip plan", content: "<div>A second note with the same title</div>"),
        ], to: "Links.enex")
        let store = makeStore()
        let report = await EvernoteImporter.importFiles([url], into: store)
        XCTAssertEqual(report.notesImported, 3)
        let trips = store.notes.filter { $0.title == "Trip plan" }
        XCTAssertEqual(trips.count, 2)
        let firstTrip = try XCTUnwrap(trips.first { store.body(for: $0.id).string.contains("Pack") })
        let index = store.body(for: try meta("Index", in: store).id)
        XCTAssertEqual(links(index), [.note(id: firstTrip.id, heading: nil), .unresolved(title: "Elsewhere", heading: nil)])
        var external: [URL] = []
        index.enumerateAttribute(.link, in: NSRange(location: 0, length: index.length)) { value, _, _ in
            if let url = value as? URL, url.scheme == "https" { external.append(url) }
        }
        XCTAssertEqual(external, [URL(string: "https://example.com/")!])
    }

    func testCancelLeavesNoLinksToNotesNotCreated() async throws {
        let url = try enex([
            note("Alpha", content: "<div><a href=\"evernote:///view/1/s1/b/b/\">Beta</a></div>"),
            note("Beta", content: "<div>Text</div>"),
            note("Gamma", content: "<div>Text</div>"),
        ], to: "Cancel.enex")
        let store = makeStore()
        let task = Task { @MainActor in
            await EvernoteImporter.importFiles([url], into: store) { progress in
                if progress.currentName == "Beta" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(store.notes.count, report.notesImported)
        XCTAssertEqual(store.notes.map(\.title), ["Alpha"])
        XCTAssertEqual(links(store.body(for: try meta("Alpha", in: store).id)), [.unresolved(title: "Beta", heading: nil)])
    }

    func testFolderOfExportsKeepsStacks() async throws {
        try enex([note("A", content: "x")], to: "Export/Work/Projects.enex")
        try enex([note("B", content: "x")], to: "Export/Inbox.enex")
        let items = EvernoteImporter.items(for: [base.appendingPathComponent("Export")])
        XCTAssertEqual(items.map(\.notebook), [["Inbox"], ["Work", "Projects"]])
        let store = makeStore()
        _ = await EvernoteImporter.importItems(items, into: store)
        XCTAssertEqual(try meta("A", in: store).notebookID.map { store.notebookPathTitle($0) }, "Work › Projects")
        XCTAssertEqual(try meta("B", in: store).notebookID.map { store.notebookPathTitle($0) }, "Inbox")
    }

    func testExistingNotebookIsNotMergedInto() async throws {
        let store = makeStore()
        let existing = store.createNotebook(name: "Work", symbol: "folder", colorHex: Tokens.Hex.notebookRed)
        let file = try enex([note("A", content: "x"), note("B", content: "y")], to: "Work.enex")
        _ = await EvernoteImporter.importFiles([file], into: store)
        let a = try XCTUnwrap(try meta("A", in: store).notebookID)
        XCTAssertNotEqual(a, existing.id)
        XCTAssertEqual(store.notebookPathTitle(a), "Work 2")
        XCTAssertEqual(try meta("B", in: store).notebookID, a)

        _ = await EvernoteImporter.importFiles([file], into: store)
        XCTAssertEqual(Set(store.notebooks.map(\.name)), ["Work", "Work 2", "Work 3"])
        XCTAssertTrue(store.notes.allSatisfy { $0.notebookID != existing.id })
    }

    func testStackSharedWithinOneImportButNotWithTheLibrary() async throws {
        let store = makeStore()
        _ = store.createNotebook(name: "Work", symbol: "folder", colorHex: Tokens.Hex.notebookRed)
        try enex([note("A", content: "x")], to: "Export/Work/Alpha.enex")
        try enex([note("B", content: "x")], to: "Export/Work/Beta.enex")
        _ = await EvernoteImporter.importFiles([base.appendingPathComponent("Export")], into: store)
        XCTAssertEqual(try meta("A", in: store).notebookID.map { store.notebookPathTitle($0) }, "Work 2 › Alpha")
        XCTAssertEqual(try meta("B", in: store).notebookID.map { store.notebookPathTitle($0) }, "Work 2 › Beta")
        XCTAssertEqual(store.notebooks.filter { $0.name == "Work 2" }.count, 1)
    }

    func testReminderBecomesToken() throws {
        let parsed = try XCTUnwrap(ENEXNoteParser.parse(Data(note("Call", content: "<div>Dentist</div>", extra: """
            <note-attributes><reminder-time>20240105T090000Z</reminder-time><reminder-done-time>20240105T100000Z</reminder-done-time></note-attributes>
            """).utf8)))
        XCTAssertNotNil(parsed.reminder)
        XCTAssertTrue(parsed.reminderDone)
        var report = ImportReport()
        let body = EvernoteImporter.body(for: parsed, title: "Call", report: &report).string
        XCTAssertTrue(body.contains(EvernoteImporter.reminderToken(parsed.reminder!, done: true)), body)
        XCTAssertNotNil(body.range(of: "@remind\\(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2} done\\)", options: .regularExpression))
    }

    func testReaderSplitsNotesAcrossBlocks() throws {
        let filler = String(repeating: "word ", count: ENEXReader.blockSize / 5 + 7)
        let notes = (0..<4).map { note("N\($0)", content: "<div>\(filler)</div>") }
        let url = try enex(notes, to: "Blocks.enex")
        XCTAssertEqual(ENEXReader.countNotes(in: url), 4)
        let reader = try XCTUnwrap(ENEXReader(url: url))
        var titles: [String] = []
        while let next = reader.nextParsed() {
            guard case .note(let note) = next else { return XCTFail("unreadable note") }
            titles.append(note.title)
        }
        XCTAssertEqual(titles, ["N0", "N1", "N2", "N3"])
        XCTAssertTrue(reader.isExport)
    }

    func testCutOffNoteAtEndIsUnreadable() throws {
        let url = base.appendingPathComponent("Cut.enex")
        try ("<en-export>" + note("Whole", content: "x") + "<note><title>Half</title><content>").write(to: url, atomically: true, encoding: .utf8)
        let reader = try XCTUnwrap(ENEXReader(url: url))
        guard case .note(let whole)? = reader.nextParsed() else { return XCTFail() }
        XCTAssertEqual(whole.title, "Whole")
        XCTAssertEqual(reader.nextParsed(), .unreadable)
        XCTAssertNil(reader.nextParsed())
    }

    /// A 200 MB export imports one note at a time.
    func testLargeExportStreams() async throws {
        let url = base.appendingPathComponent("Large.enex")
        fm.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("<?xml version=\"1.0\"?><en-export>".utf8))
        var chunk = Data(count: 1_400_000)
        let count = 150
        for i in 0..<count {
            chunk[0] = UInt8(i)
            try handle.write(contentsOf: Data(note("Big \(i)", content: "<div>n</div>",
                                                   extra: resource(chunk, mime: "application/octet-stream")).utf8))
        }
        try handle.write(contentsOf: Data("</en-export>".utf8))
        try handle.close()
        let size = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 200_000_000)

        let store = makeStore()
        let before = Self.footprint()
        var peak = before
        let report = await EvernoteImporter.importFiles([url], into: store) { progress in
            if progress.completed % 10 == 0 { peak = max(peak, Self.footprint()) }
        }
        peak = max(peak, Self.footprint())
        XCTAssertEqual(report.notesImported, count)
        XCTAssertLessThan(peak - before, 100_000_000, "memory grew by \(peak - before) bytes")
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
