import AppKit
import NoteItDoc
import XCTest
@testable import NoteIt

@MainActor
final class AppleNotesHTMLTests: XCTestCase {
    private struct Para {
        var text: String
        var kind: BlockKind
        var marker: ListMarker?
        var level: Int
    }

    private func paragraphs(_ s: NSAttributedString) -> [Para] {
        let ns = s.string as NSString
        var result: [Para] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let text = ns.substring(with: range).trimmingCharacters(in: .newlines)
            let ps = s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let font = s.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let marker = EditorStyle.listMarker(in: text)
            result.append(Para(text: text, kind: EditorStyle.blockKind(paragraphStyle: ps, font: font), marker: marker,
                               level: EditorStyle.listLevel(of: ps)))
        }
        return result
    }

    private func attrs(_ s: NSAttributedString, of substring: String) -> [NSAttributedString.Key: Any] {
        let r = (s.string as NSString).range(of: substring)
        XCTAssertNotEqual(r.location, NSNotFound, "missing \(substring)")
        return r.location == NSNotFound ? [:] : s.attributes(at: r.location, effectiveRange: nil)
    }

    /// Shaped like the HTML the Notes app returns for a note's body.
    private let fixture = """
    <div><b><span style="font-size: 24px">Garden plan</span></b></div>
    <div><b><span style="font-size: 18px">Spring</span></b></div>
    <div><b><span style="font-size: 15px">Seeds</span></b></div>
    <div><span style="font-family: Georgia; color: rgb(200, 30, 30); font-size: 13px">Plant <b>tomatoes</b>, <i>basil</i>, <u>mint</u> and <strike>weeds</strike>.</span></div>
    <div><span style="font-size: 13px">Read <a href="https://example.com/soil">soil tips</a>.</span></div>
    <div><br></div>
    <ul>
    <li><span style="font-size: 13px">Rake</span></li>
    <li><span style="font-size: 13px">Water</span>
    <ul><li><span style="font-size: 13px">Morning</span></li></ul>
    </li>
    </ul>
    <ol>
    <li><span style="font-size: 13px">Dig</span></li>
    <li><span style="font-size: 13px">Sow</span></li>
    </ol>
    <div><tt>let rows = 4</tt></div>
    <div><span style="font-size: 13px">Use <tt>pH 6.5</tt> soil</span></div>
    <div><br></div>
    """

    func testFixtureConvertsToNoteItStyles() {
        let result = AppleNotesImporter.convert(html: fixture, title: "Garden plan")
        let s = result.body
        let p = paragraphs(s)
        XCTAssertEqual(p.map(\.text), [
            "Garden plan", "Spring", "Seeds",
            "Plant tomatoes, basil, mint and weeds.", "Read soil tips.", "",
            EditorStyle.markerText(.bullet, level: 0) + "Rake",
            EditorStyle.markerText(.bullet, level: 0) + "Water",
            EditorStyle.markerText(.bullet, level: 1) + "Morning",
            "1.\tDig", "2.\tSow",
            "let rows = 4", "Use pH 6.5 soil",
        ])
        XCTAssertEqual(p.map(\.kind), [.title, .heading, .subheading, .body, .body, .body,
                                       .body, .body, .body, .body, .body, .code, .body])
        XCTAssertEqual(p[6...10].map(\.marker?.kind), [.bullet, .bullet, .bullet, .numbered(1), .numbered(2)])
        XCTAssertEqual(p[6...10].map(\.level), [0, 0, 1, 0, 0])

        let fm = NSFontManager.shared
        XCTAssertTrue(fm.traits(of: attrs(s, of: "tomatoes")[.font] as! NSFont).contains(.boldFontMask))
        XCTAssertTrue(fm.traits(of: attrs(s, of: "basil")[.font] as! NSFont).contains(.italicFontMask))
        XCTAssertEqual(attrs(s, of: "mint")[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(attrs(s, of: "weeds")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(attrs(s, of: "soil tips")[.link] as? URL, URL(string: "https://example.com/soil"))
        XCTAssertEqual(attrs(s, of: "pH 6.5")[.font] as? NSFont, EditorStyle.inlineCodeFont)

        let plant = attrs(s, of: "Plant")
        XCTAssertEqual((plant[.font] as? NSFont)?.familyName, EditorStyle.bodyFont.familyName, "Notes fonts are dropped")
        XCTAssertEqual((plant[.font] as? NSFont)?.pointSize, EditorStyle.bodySize)
        XCTAssertNil(plant[.foregroundColor], "Notes colors are dropped")
        XCTAssertEqual(result.images, 0)
    }

    func testTitleIsAddedWhenBodyDoesNotStartWithIt() {
        let s = AppleNotesImporter.convert(html: "<div>Just some text</div>", title: "Untitled thought").body
        XCTAssertEqual(paragraphs(s).map(\.text), ["Untitled thought", "Just some text"])
        XCTAssertEqual(paragraphs(s).map(\.kind), [.title, .body])
    }

    func testPlainFirstLineMatchingNameBecomesTitle() {
        let s = AppleNotesImporter.convert(html: "<div>Errands</div><div>Post office</div>", title: "Errands").body
        XCTAssertEqual(paragraphs(s).map(\.kind), [.title, .body])
    }

    func testEmbeddedImageBecomesAttachment() throws {
        let png = try MarkdownReaderTests.pngData().base64EncodedString()
        let html = "<div>Sketch</div><div><img src=\"data:image/png;base64,\(png)\"></div><div><img src=\"https://example.com/remote.png\"></div><div>After</div>"
        let result = AppleNotesImporter.convert(html: html, title: "Sketch")
        XCTAssertEqual(result.images, 1)
        var wrappers: [FileWrapper] = []
        result.body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.body.length)) { value, _, _ in
            if let w = (value as? NSTextAttachment)?.fileWrapper { wrappers.append(w) }
        }
        XCTAssertEqual(wrappers.count, 1)
        XCTAssertEqual(wrappers.first?.preferredFilename, "image-1.png")
        XCTAssertEqual(wrappers.first?.regularFileContents, Data(base64Encoded: png))
        XCTAssertFalse(result.body.string.contains("\u{E000}"))
        XCTAssertTrue(result.body.string.hasSuffix("After\n"))
    }

    func testTable() throws {
        let html = """
        <div>Prices</div>
        <table><tbody>
        <tr><td><div>Item</div></td><td><div>Cost</div></td></tr>
        <tr><td><div>Pens</div></td><td><div>3</div></td></tr>
        </tbody></table>
        """
        let s = AppleNotesImporter.convert(html: html, title: "Prices").body
        let p = paragraphs(s)
        XCTAssertEqual(p.prefix(5).map(\.text), ["Prices", "Item", "Cost", "Pens", "3"])
        let ps = s.attribute(.paragraphStyle, at: (s.string as NSString).range(of: "Pens").location, effectiveRange: nil) as? NSParagraphStyle
        let block = try XCTUnwrap(ps?.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.numberOfColumns, 2)
        XCTAssertEqual(block.startingRow, 1)
    }

    func testFolderPathsFlattenNestingAndOmitAccounts() {
        let folders = [
            AppleNotesFolder(id: "a", name: "Notes", parentID: ""),
            AppleNotesFolder(id: "b", name: "Work", parentID: ""),
            AppleNotesFolder(id: "c", name: "Meetings", parentID: "b"),
            AppleNotesFolder(id: "d", name: "2024", parentID: "c"),
        ]
        XCTAssertEqual(AppleNotesImporter.folderPaths(folders), [
            "a": "Notes", "b": "Work", "c": "Work / Meetings", "d": "Work / Meetings / 2024",
        ])
        XCTAssertTrue(AppleNotesImporter.isRecentlyDeleted(AppleNotesFolder(id: "x", name: "Recently Deleted", parentID: "")))
        for name in ["Nyligen raderade", "Senast raderade", "Zuletzt gelöscht", "Suppressions récentes", "Eliminado recientemente"] {
            XCTAssertTrue(AppleNotesImporter.isRecentlyDeleted(AppleNotesFolder(id: "x", name: name, parentID: "")), name)
        }
        XCTAssertFalse(AppleNotesImporter.isRecentlyDeleted(AppleNotesFolder(id: "x", name: "Recently Deleted", parentID: "b")))
        XCTAssertFalse(AppleNotesImporter.isRecentlyDeleted(AppleNotesFolder(id: "x", name: "Work", parentID: "")))
    }

    func testScriptsEscapeIDs() {
        XCTAssertTrue(AppleNotesImporter.noteScript(noteID: "x-coredata://a\"b").contains("note id \"x-coredata://a\\\"b\""))
    }

    func testImportWithFakeScriptingCountsLockedAndAttachments() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = NoteStore(location: LibraryLocation(url: base, seedsFreshLibrary: false))
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let modified = Date(timeIntervalSince1970: 1_650_000_000)
        let fake = FakeNotes(
            folders: [("f1", "Notes", ""), ("f2", "Trips", ""), ("f3", "Italy", "f2"), ("f9", "Recently Deleted", "")],
            notes: [
                "f1": [("n1", false), ("n2", true)],
                "f2": [],
                "f3": [("n3", false)],
                "f9": [("n4", false)],
            ],
            bodies: [
                "n1": ("Shopping", "<div>Shopping</div><div>Milk</div>", 2),
                "n3": ("Rome", "<div><b><span style=\"font-size: 24px\">Rome</span></b></div><div>Colosseum</div>", 0),
                "n4": ("Deleted", "<div>Deleted</div>", 0),
            ],
            created: created, modified: modified
        )
        let report = try await AppleNotesImporter(store: store, scripting: fake).run { _ in }
        XCTAssertEqual(report.notesImported, 2)
        XCTAssertEqual(report.lockedSkipped, 1)
        XCTAssertEqual(report.attachmentsSkipped, 2)
        XCTAssertEqual(Set(store.notebooks.map(\.name)), ["Notes", "Trips / Italy"])
        let rome = try XCTUnwrap(store.notes.first { $0.title == "Rome" })
        XCTAssertEqual(rome.createdAt, created)
        XCTAssertEqual(rome.updatedAt, modified)
        XCTAssertEqual(report.summary, "Imported 2 notes into 2 notebooks. Skipped 1 locked note and 2 attachments.")
    }

    private func makeStore(_ base: URL) -> NoteStore {
        NoteStore(location: LibraryLocation(url: base, seedsFreshLibrary: false))
    }

    private func fake(notes: [String], failures: [String: Int] = [:]) -> FakeNotes {
        FakeNotes(
            folders: [("f1", "Notes", "")],
            notes: ["f1": notes.map { ($0, false) }],
            bodies: Dictionary(uniqueKeysWithValues: notes.map { ($0, ("Note \($0)", "<div>Note \($0)</div><div>Text</div>", 0)) }),
            created: Date(timeIntervalSince1970: 1_600_000_000), modified: Date(timeIntervalSince1970: 1_650_000_000),
            failures: failures
        )
    }

    func testOneUnreadableNoteDoesNotStopTheImport() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(base)
        let report = try await AppleNotesImporter(store: store, scripting: fake(notes: ["n1", "n2", "n3"], failures: ["n2": -1728])).run { _ in }
        XCTAssertEqual(report.notesImported, 2)
        XCTAssertEqual(report.notesSkipped, 1)
        XCTAssertFalse(report.permissionDenied)
        XCTAssertEqual(report.summary, "Imported 2 notes into 1 notebook. Skipped 1 unreadable note.")
        XCTAssertEqual(Set(store.notes.map(\.title)), ["Note n1", "Note n3"])
    }

    func testLosingPermissionMidwayKeepsImportedNotes() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(base)
        let report = try await AppleNotesImporter(store: store, scripting: fake(notes: ["n1", "n2", "n3"], failures: ["n2": -1743])).run { _ in }
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertTrue(report.permissionDenied)
        XCTAssertTrue(report.summary.hasPrefix("Imported 1 note into 1 notebook. NoteIt isn't allowed"), report.summary)
        XCTAssertEqual(makeStore(base).notes.map(\.title), ["Note n1"], "imported notes are saved")
    }

    func testLocalizedRecentlyDeletedFoldersAreSkipped() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = makeStore(base)
        let trash = ["Nyligen raderade", "Senast raderade", "Zuletzt gelöscht", "Suppressions récentes", "Eliminado recientemente"]
        let fake = FakeNotes(
            folders: [("w", "Work", "")] + trash.enumerated().map { ("t\($0.offset)", $0.element, "") },
            notes: Dictionary(uniqueKeysWithValues: [("w", [("keep", false)])] + trash.indices.map { ("t\($0)", [("gone\($0)", false)]) }),
            bodies: Dictionary(uniqueKeysWithValues: [("keep", ("Keep", "<div>Keep</div>", 0))] + trash.indices.map { ("gone\($0)", ("Gone", "<div>Gone</div>", 0)) }),
            created: Date(), modified: Date()
        )
        let report = try await AppleNotesImporter(store: store, scripting: fake).run { _ in }
        XCTAssertEqual(report.notesImported, 1)
        XCTAssertEqual(store.notebooks.map(\.name), ["Work"])
        XCTAssertEqual(store.notes.map(\.title), ["Keep"])
    }

    func testPermissionDenialIsFriendly() async {
        let store = NoteStore(location: LibraryLocation(url: FileManager.default.temporaryDirectory.appendingPathComponent("noteit-notes-\(UUID().uuidString)"), seedsFreshLibrary: false))
        let denied = DeniedNotes()
        do {
            _ = try await AppleNotesImporter(store: store, scripting: denied).run { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImportError, .notesPermissionDenied)
            XCTAssertTrue(error.localizedDescription.contains("System Settings › Privacy & Security › Automation"))
        }
        try? FileManager.default.removeItem(at: store.rootURL)
    }

    func testImagesOver25MBAreLeftOutAndCountedAsSkipped() {
        let big = Data(count: AttachmentLimit.maxBytes + 1).base64EncodedString()
        let small = Data(count: 10).base64EncodedString()
        let html = "<div>Photos</div><div><img src=\"data:image/png;base64,\(big)\"></div><div><img src=\"data:image/png;base64,\(small)\"></div>"
        let result = AppleNotesImporter.convert(html: html, title: "Photos")
        XCTAssertEqual(result.images, 1)
        var attachments = 0
        result.body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.body.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 1)
    }
}

private struct DeniedNotes: AppleNotesScripting {
    func run(_ source: String) throws -> NSAppleEventDescriptor {
        throw AppleScriptError(code: -1743, message: "Not authorized to send Apple events to Notes.")
    }
}

/// Answers the importer's scripts from canned data.
private struct FakeNotes: AppleNotesScripting {
    var folders: [(String, String, String)]
    var notes: [String: [(String, Bool)]]
    var bodies: [String: (String, String, Int)]
    var created: Date
    var modified: Date
    /// Note id → the Apple Event error reading it throws.
    var failures: [String: Int] = [:]

    func run(_ source: String) throws -> NSAppleEventDescriptor {
        XCTAssertFalse(Thread.isMainThread, "scripts run off the main thread")
        if source == AppleNotesImporter.foldersScript {
            return list(folders.map { list([text($0.0), text($0.1), text($0.2)]) })
        }
        for (folder, entries) in notes where source == AppleNotesImporter.noteListScript(folderID: folder) {
            return list([list(entries.map { text($0.0) }), list(entries.map { NSAppleEventDescriptor(boolean: $0.1) })])
        }
        for (id, code) in failures where source == AppleNotesImporter.noteScript(noteID: id) {
            throw AppleScriptError(code: code, message: "Failed")
        }
        for (id, body) in bodies where source == AppleNotesImporter.noteScript(noteID: id) {
            return list([text(body.0), text(body.1), NSAppleEventDescriptor(date: created), NSAppleEventDescriptor(date: modified),
                         NSAppleEventDescriptor(int32: Int32(body.2))])
        }
        throw AppleScriptError(code: -1728, message: "Unexpected script")
    }

    private func text(_ s: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: s) }

    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let d = NSAppleEventDescriptor.list()
        for (i, item) in items.enumerated() { d.insert(item, at: i + 1) }
        return d
    }
}
