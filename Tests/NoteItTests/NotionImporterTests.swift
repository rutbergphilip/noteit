import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class NotionImporterTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private let projectsID = "0123456789abcdef0123456789abcdef"
    private let roadmapID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let tasksID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let looseID = "dddddddddddddddddddddddddddddddd"

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("noteit-notion-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeStore(_ name: String = "Library") -> NoteStore {
        NoteStore(location: LibraryLocation(url: base.appendingPathComponent(name, isDirectory: true), seedsFreshLibrary: false))
    }

    @discardableResult
    private func write(_ text: String, to path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func zip(_ folder: URL, to zip: URL, keepParent: Bool = true) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func meta(_ title: String, in store: NoteStore) throws -> NoteMeta {
        try XCTUnwrap(store.notes.first { $0.title == title }, "no note titled \(title)")
    }

    private func links(_ body: NSAttributedString) -> [NoteLink] {
        var out: [NoteLink] = []
        body.enumerateAttribute(.link, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            if let url = value as? URL, let link = NoteLink(url: url) { out.append(link) }
        }
        return out
    }

    private func tableCells(_ body: NSAttributedString) -> [String] {
        var cells: [String] = []
        let ns = body.string as NSString
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let style = body.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            if style?.textBlocks.isEmpty == false { cells.append(ns.substring(with: range).trimmingCharacters(in: .newlines)) }
        }
        return cells
    }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// A workspace export: one top-level page with subpages, a database and an image, and one lone page.
    private func makeExport() throws -> URL {
        let export = base.appendingPathComponent("Export-1234", isDirectory: true)
        let projects = "Projects \(projectsID)"
        let enc = "Projects%20\(projectsID)"
        try write("""
            # Projects

            See [Roadmap](\(enc)/Roadmap%20\(roadmapID).md) and [Tasks](\(enc)/Tasks%20\(tasksID).csv).

            <aside>
            💡 Keep it short.
            </aside>

            ![Diagram](\(enc)/Diagram%201.png)

            ![Gone](\(enc)/missing.png)
            """, to: "\(projects).md", in: export)
        try write("""
            Next steps live here. Back to [Projects](../Projects%20\(projectsID).md), \
            and [Elsewhere](../../Elsewhere%20cccccccccccccccccccccccccccccccc.md).
            """, to: "\(projects)/Roadmap \(roadmapID).md", in: export)
        try write("Name,Status\nWrite,Done\n", to: "\(projects)/Tasks \(tasksID).csv", in: export)
        try write("Name,Status,Notes\nWrite,Done,\"Short, sweet\"\nShip,Open,\"Line one\nLine two\"\n",
                  to: "\(projects)/Tasks \(tasksID)_all.csv", in: export)
        try Self.png.write(to: export.appendingPathComponent("\(projects)/Diagram 1.png"))
        try write("# Loose\nOn its own.", to: "Loose \(looseID).md", in: export)
        return export
    }

    func testExportBecomesNotebooksNotesAndLinks() async throws {
        let export = try makeExport()
        let store = makeStore()
        let report = try await NotionImporter.importExport(export, into: store)

        XCTAssertEqual(report.notesImported, 4)
        XCTAssertEqual(report.attachmentsSkipped, 1)
        XCTAssertEqual(Set(store.notebooks.map(\.name)), ["Projects", "Notion"])
        func notebook(_ title: String) throws -> String? {
            try meta(title, in: store).notebookID.flatMap { id in store.notebooks.first { $0.id == id }?.name }
        }
        XCTAssertEqual(try notebook("Projects"), "Projects")
        XCTAssertEqual(try notebook("Roadmap"), "Projects")
        XCTAssertEqual(try notebook("Tasks"), "Projects")
        XCTAssertEqual(try notebook("Loose"), "Notion")

        let projects = store.body(for: try meta("Projects", in: store).id)
        let roadmap = try meta("Roadmap", in: store), tasks = try meta("Tasks", in: store)
        XCTAssertEqual(links(projects), [.note(id: roadmap.id, heading: nil), .note(id: tasks.id, heading: nil)])
        XCTAssertTrue(projects.string.contains("💡 Keep it short."))
        XCTAssertFalse(projects.string.contains("aside"))
        var images = 0
        projects.enumerateAttribute(.attachment, in: NSRange(location: 0, length: projects.length)) { value, _, _ in
            if value != nil { images += 1 }
        }
        XCTAssertEqual(images, 1)

        let roadmapBody = store.body(for: roadmap.id)
        XCTAssertTrue(roadmapBody.string.hasPrefix("Roadmap\nNext steps"), roadmapBody.string)
        XCTAssertEqual(links(roadmapBody), [.note(id: try meta("Projects", in: store).id, heading: nil),
                                            .unresolved(title: "Elsewhere", heading: nil)])

        let table = store.body(for: tasks.id)
        XCTAssertTrue(table.string.hasPrefix("Tasks\n"))
        XCTAssertEqual(tableCells(table), ["Name", "Status", "Notes", "Write", "Done", "Short, sweet", "Ship", "Open", "Line one Line two"])
        XCTAssertFalse(store.notes.contains { $0.title.contains(projectsID) || $0.title.contains(tasksID) })
    }

    func testExistingNotebooksAreNotMergedInto() async throws {
        let store = makeStore()
        let existing = store.createNotebook(name: "Projects", symbol: "folder", colorHex: Tokens.Hex.notebookRed)
        let export = try makeExport()
        _ = try await NotionImporter.importExport(export, into: store)
        func notebook(_ title: String) throws -> String? {
            try meta(title, in: store).notebookID.flatMap { id in store.notebooks.first { $0.id == id }?.name }
        }
        XCTAssertEqual(try notebook("Projects"), "Projects 2")
        XCTAssertEqual(try notebook("Roadmap"), "Projects 2")
        XCTAssertEqual(try notebook("Tasks"), "Projects 2")
        XCTAssertEqual(store.notebooks.filter { $0.name == "Projects 2" }.count, 1)
        XCTAssertTrue(store.notes.allSatisfy { $0.notebookID != existing.id })

        _ = try await NotionImporter.importExport(export, into: store)
        XCTAssertEqual(Set(store.notebooks.map(\.name)), ["Projects", "Projects 2", "Projects 3", "Notion", "Notion 2"])
    }

    func testSameTitledTopPagesGetTheirOwnNotebooks() async throws {
        let export = base.appendingPathComponent("Twins", isDirectory: true)
        try write("# Plan\nA", to: "Plan \(projectsID).md", in: export)
        try write("Child A", to: "Plan \(projectsID)/One \(roadmapID).md", in: export)
        try write("# Plan\nB", to: "Plan \(tasksID).md", in: export)
        try write("Child B", to: "Plan \(tasksID)/Two \(looseID).md", in: export)
        let store = makeStore()
        _ = try await NotionImporter.importExport(export, into: store)
        let one = try XCTUnwrap(try meta("One", in: store).notebookID)
        let two = try XCTUnwrap(try meta("Two", in: store).notebookID)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(Set(store.notebooks.map(\.name)), ["Plan", "Plan 2"])
    }

    func testZipWithNestedPartsIsOpened() async throws {
        let export = try makeExport()
        let staging = base.appendingPathComponent("Outer", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try zip(export, to: staging.appendingPathComponent("Export-1234-Part-1.zip"))
        let outer = base.appendingPathComponent("Notion.zip")
        try zip(staging, to: outer, keepParent: false)

        let store = makeStore()
        let report = try await NotionImporter.importExport(outer, into: store)
        XCTAssertEqual(report.notesImported, 4)
        XCTAssertNotNil(store.notes.first { $0.title == "Roadmap" })
    }

    func testPartZipThatWontOpenIsReported() async throws {
        let export = try makeExport()
        let staging = base.appendingPathComponent("Outer", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try zip(export, to: staging.appendingPathComponent("Export-Part-1.zip"))
        try Data("not a zip".utf8).write(to: staging.appendingPathComponent("Export-Part-2.zip"))

        let store = makeStore()
        let report = try await NotionImporter.importExport(staging, into: store)
        XCTAssertEqual(report.notesImported, 4)
        XCTAssertEqual(report.archivesSkipped, ["Export-Part-2.zip"])
        XCTAssertTrue(report.summary.contains("Export-Part-2.zip"), report.summary)

        let broken = base.appendingPathComponent("Broken", isDirectory: true)
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: broken.appendingPathComponent("Export-Part-1.zip"))
        do {
            _ = try await NotionImporter.importExport(broken, into: makeStore())
            XCTFail("No error thrown")
        } catch {
            XCTAssertEqual(error as? ImportError, .unreadableArchive("Export-Part-1.zip"))
        }
    }

    func testArchivesOverTheSizeOrEntryLimitAreRefused() async throws {
        let export = try makeExport()
        let staging = base.appendingPathComponent("Outer", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let part = staging.appendingPathComponent("Export-1234-Part-1.zip")
        try zip(export, to: part)
        let outer = base.appendingPathComponent("Notion.zip")
        try zip(staging, to: outer, keepParent: false)
        let outerTotals = try XCTUnwrap(MarkdownImporter.zipTotals(outer, excludingTopLevelZips: true))
        let partTotals = try XCTUnwrap(MarkdownImporter.zipTotals(part))
        XCTAssertGreaterThan(partTotals.entries, 5)

        func refused(_ limits: ZipLimits, _ name: String, line: UInt = #line) async {
            do {
                _ = try await NotionImporter.importExport(outer, into: makeStore(), limits: limits)
                XCTFail("No error thrown", line: line)
            } catch {
                XCTAssertEqual(error as? ImportError, .archiveTooLarge(name), line: line)
            }
        }
        await refused(ZipLimits(maxEntries: outerTotals.entries - 1, maxBytes: .max), "Notion.zip")
        await refused(ZipLimits(maxEntries: .max, maxBytes: outerTotals.bytes - 1), "Notion.zip")
        await refused(ZipLimits(maxEntries: outerTotals.entries + partTotals.entries - 1, maxBytes: .max),
                      "Export-1234-Part-1.zip")
        XCTAssertTrue(ImportError.archiveTooLarge("Notion.zip").errorDescription?.contains("Notion.zip") == true)

        let fits = ZipLimits(maxEntries: outerTotals.entries + partTotals.entries,
                             maxBytes: outerTotals.bytes + partTotals.bytes)
        let report = try await NotionImporter.importExport(outer, into: makeStore(), limits: fits)
        XCTAssertEqual(report.notesImported, 4)
    }

    func testPartArchivesAreChargedOnlyOnceAgainstTheLimit() async throws {
        let export = try makeExport()
        try Data(repeating: 65, count: 2_000_000).write(to: export.appendingPathComponent("Filler.bin"))
        let staging = base.appendingPathComponent("Outer", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let part = staging.appendingPathComponent("Export-1234-Part-1.zip")
        try zip(export, to: part)
        let outer = base.appendingPathComponent("Notion.zip")
        try zip(staging, to: outer, keepParent: false)
        let outerTotals = try XCTUnwrap(MarkdownImporter.zipTotals(outer))
        let partTotals = try XCTUnwrap(MarkdownImporter.zipTotals(part))
        let partSize = try XCTUnwrap(fm.attributesOfItem(atPath: part.path)[.size] as? Int64)

        let limits = ZipLimits(maxEntries: .max, maxBytes: outerTotals.bytes - partSize + partTotals.bytes)
        XCTAssertGreaterThan(limits.maxBytes, outerTotals.bytes)
        do {
            let report = try await NotionImporter.importExport(outer, into: makeStore(), limits: limits)
            XCTAssertEqual(report.notesImported, 4)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testHTMLExportAndEmptyFoldersAreRefused() async throws {
        let html = base.appendingPathComponent("HTML", isDirectory: true)
        try write("<html></html>", to: "Page \(projectsID).html", in: html)
        do {
            _ = try await NotionImporter.importExport(html, into: makeStore())
            XCTFail("imported an HTML export")
        } catch let error as ImportError {
            XCTAssertEqual(error, .notionHTMLExport)
        }
        let empty = base.appendingPathComponent("Empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        do {
            _ = try await NotionImporter.importExport(empty, into: makeStore("Library2"))
            XCTFail("imported an empty folder")
        } catch let error as ImportError {
            XCTAssertEqual(error, .nothingToImport)
        }
        let notZip = try write("nope", to: "Broken.zip", in: base)
        do {
            _ = try await NotionImporter.importExport(notZip, into: makeStore("Library3"))
            XCTFail("imported a broken zip")
        } catch let error as ImportError {
            XCTAssertEqual(error, .unreadableArchive("Broken.zip"))
        }
    }

    func testLargeDatabaseIsCutAtTheRowLimit() async throws {
        let export = base.appendingPathComponent("Big", isDirectory: true)
        let rows = (0..<(NotionImporter.maxTableRows + 5)).map { "Row \($0),x" }
        try write((["Name,Value"] + rows).joined(separator: "\r\n"), to: "Inventory \(tasksID).csv", in: export)
        let store = makeStore()
        let report = try await NotionImporter.importExport(export, into: store)
        XCTAssertEqual(report.truncatedTables, ["Inventory"])
        XCTAssertTrue(report.summary.contains("rows of “Inventory” were imported."), report.summary)
        let cells = tableCells(store.body(for: try meta("Inventory", in: store).id))
        XCTAssertEqual(cells.count, 2 * (NotionImporter.maxTableRows + 1))
        XCTAssertEqual(cells.suffix(2), ["Row 999", "x"])
    }

    func testCancelLeavesOnlyTitleLinksToPagesNotCreated() async throws {
        let export = base.appendingPathComponent("Cancel", isDirectory: true)
        try write("# Alpha\nSee [Beta](Beta%20\(roadmapID).md).", to: "Alpha \(projectsID).md", in: export)
        try write("# Beta\nText", to: "Beta \(roadmapID).md", in: export)
        try write("# Gamma\nText", to: "Gamma \(tasksID).md", in: export)
        let store = makeStore()
        let task = Task { @MainActor in
            try await NotionImporter.importExport(export, into: store) { progress in
                if progress.currentName == "Beta" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = try await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(store.notes.map(\.title), ["Alpha"])
        XCTAssertEqual(links(store.body(for: try meta("Alpha", in: store).id)), [.unresolved(title: "Beta", heading: nil)])
    }

    func testUnreadablePageIsReported() async throws {
        let export = base.appendingPathComponent("Locked", isDirectory: true)
        try write("# Fine\nText", to: "Fine \(projectsID).md", in: export)
        let locked = try write("# Hidden\nText", to: "Hidden \(roadmapID).md", in: export)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let report = try await NotionImporter.importExport(export, into: makeStore())
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertEqual(report.filesSkipped, 1)
    }

    func testRemoteImagesStayAsLinks() async throws {
        let export = base.appendingPathComponent("Remote", isDirectory: true)
        try write("""
            # Web
            ![Chart](https://example.com/chart.png)

            ![](<https://example.com/a b.png> "Caption")
            """, to: "Web \(projectsID).md", in: export)
        let store = makeStore()
        let report = try await NotionImporter.importExport(export, into: store)
        XCTAssertEqual(report.attachmentsSkipped, 0)
        let body = store.body(for: try meta("Web", in: store).id)
        var found: [String: String] = [:]
        body.enumerateAttribute(.link, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            let url = (value as? URL)?.absoluteString ?? value as? String
            if let url { found[url] = (body.string as NSString).substring(with: range) }
        }
        XCTAssertEqual(found["https://example.com/chart.png"], "Chart")
        XCTAssertEqual(found["https://example.com/a%20b.png"], "https://example.com/a b.png")
    }

    func testNames() {
        XCTAssertEqual(NotionNames.stripID("Plan \(projectsID)").title, "Plan")
        XCTAssertEqual(NotionNames.stripID("Plan \(projectsID.uppercased())").id, projectsID)
        XCTAssertEqual(NotionNames.stripID("Plan 1234").title, "Plan 1234")
        XCTAssertEqual(NotionNames.title(ofFile: "Tasks \(tasksID)_all.csv"), "Tasks")
        XCTAssertEqual(NotionNames.title(ofFile: " \(tasksID).md"), "Untitled")
        XCTAssertEqual(NotionNames.title(ofStem: "v1.2 notes \(tasksID)"), "v1.2 notes")
    }

    func testCSVReader() {
        let table = NotionCSV.read("\u{FEFF}A,B\n\"x \"\"q\"\"\",\"1,2\"\n\nlast,\n", limit: 10)
        XCTAssertEqual(table.header, ["A", "B"])
        XCTAssertEqual(table.rows, [["x \"q\"", "1,2"], ["last", ""]])
        XCTAssertFalse(table.truncated)
        let cut = NotionCSV.read("A\n1\n2\n3", limit: 2)
        XCTAssertEqual(cut.rows, [["1"], ["2"]])
        XCTAssertTrue(cut.truncated)
    }
}
