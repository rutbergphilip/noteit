import AppKit
import XCTest
@testable import NoteIt

/// Notes for these tests are built with the editor's own commands and builders, the same way they're
/// made by typing, so the writers are checked against real note bodies.
@MainActor
final class ExportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteItExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Building notes

    private func editor(_ paragraphs: [String]) -> NoteItTextView {
        let (_, textView) = NoteItTextView.make()
        let text = paragraphs.joined(separator: "\n") + "\n"
        textView.storage.setAttributedString(NSAttributedString(string: text, attributes: EditorStyle.bodyAttributes))
        return textView
    }

    private func range(of text: String, in textView: NoteItTextView) -> NSRange {
        let r = (textView.string as NSString).range(of: text)
        XCTAssertNotEqual(r.location, NSNotFound, "missing \(text)")
        return r
    }

    private func apply(_ command: FormatCommand, to text: String, in textView: NoteItTextView) {
        textView.setSelectedRange(range(of: text, in: textView))
        textView.perform(command)
    }

    private func pngFile(named name: String = "photo.png") throws -> URL {
        let image = NSImage(size: NSSize(width: 4, height: 3))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 3).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let url = folder.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func appendImage(to textView: NoteItTextView) throws {
        textView.replace(NSRange(location: textView.storage.length, length: 0), with: EditorStyle.paragraph("", kind: .body))
        textView.setSelectedRange(NSRange(location: textView.storage.length - 1, length: 0))
        textView.insertImages([try pngFile()])
    }

    private func appendTable(to textView: NoteItTextView) {
        let table = EditorStyle.table(header: ["Name", "Qty"], rows: [["Apples", "3"], ["Pears | ripe", "5"]])
        textView.replace(NSRange(location: textView.storage.length, length: 0), with: table)
    }

    /// A note with every block from the Markdown mapping table.
    private func fullNote() throws -> NoteItTextView {
        let tv = editor([
            "Groceries", "Plan", "Details",
            "Buy bold and italic and gone and code here, see site.",
            "Fruit", "Apples", "Pears",
            "First", "Second",
            "Open task", "Done task",
            "Quoted words",
            "let x = 1", "let y = 2",
            "After",
        ])
        apply(.block(.title), to: "Groceries", in: tv)
        apply(.block(.heading), to: "Plan", in: tv)
        apply(.block(.subheading), to: "Details", in: tv)
        apply(.bold, to: "bold", in: tv)
        apply(.italic, to: "italic", in: tv)
        apply(.strikethrough, to: "gone", in: tv)
        apply(.inlineCode, to: "code", in: tv)
        let site = range(of: "site", in: tv)
        tv.editAttributes(in: site) { $0.addAttribute(.link, value: URL(string: "https://example.com/a")!, range: site) }

        tv.setSelectedRange(NSRange(location: range(of: "Fruit", in: tv).location, length: range(of: "Pears", in: tv).upperBound - range(of: "Fruit", in: tv).location))
        tv.perform(.list(.bullet))
        tv.setSelectedRange(NSRange(location: range(of: "Apples", in: tv).location, length: range(of: "Pears", in: tv).upperBound - range(of: "Apples", in: tv).location))
        tv.perform(.indent)
        apply(.indent, to: "Pears", in: tv)

        tv.setSelectedRange(NSRange(location: range(of: "First", in: tv).location, length: range(of: "Second", in: tv).upperBound - range(of: "First", in: tv).location))
        tv.perform(.list(.numbered))
        tv.setSelectedRange(NSRange(location: range(of: "Open task", in: tv).location, length: range(of: "Done task", in: tv).upperBound - range(of: "Open task", in: tv).location))
        tv.perform(.list(.checklist))
        apply(.toggleCheckbox, to: "Done task", in: tv)

        apply(.block(.quote), to: "Quoted words", in: tv)
        tv.setSelectedRange(NSRange(location: range(of: "let x = 1", in: tv).location, length: range(of: "let y = 2", in: tv).upperBound - range(of: "let x = 1", in: tv).location))
        tv.perform(.block(.code))

        tv.setSelectedRange(NSRange(location: range(of: "After", in: tv).upperBound, length: 0))
        tv.perform(.divider)
        appendTable(to: tv)
        try appendImage(to: tv)
        return tv
    }

    // MARK: Markdown

    func testMarkdownCoversEveryBlockInTheMappingTable() throws {
        let tv = try fullNote()
        let export = MarkdownWriter.write(tv.attributedString(), title: "Groceries")
        XCTAssertEqual(export.markdown, """
        # Groceries

        ## Plan

        ### Details

        Buy **bold** and *italic* and ~~gone~~ and `code` here, see [site](https://example.com/a).

        - Fruit
          - Apples
            - Pears

        1. First
        2. Second

        - [ ] Open task
        - [x] Done task

        > Quoted words

        ```
        let x = 1
        let y = 2
        ```

        After

        ---

        | Name | Qty |
        | --- | --- |
        | Apples | 3 |
        | Pears \\| ripe | 5 |

        ![](<Groceries assets/image-1.png>)

        """)
        XCTAssertEqual(export.assets.map(\.filename), ["image-1.png"])
        XCTAssertNotNil(NSImage(data: export.assets[0].data))
    }

    func testMarkdownSurvivesAnRTFDRoundTrip() throws {
        let tv = try fullNote()
        let original = MarkdownWriter.write(tv.attributedString(), title: "Groceries").markdown
        let wrapper = try tv.attributedString().fileWrapper(from: NSRange(location: 0, length: tv.storage.length),
                                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let url = folder.appendingPathComponent("note.rtfd")
        try wrapper.write(to: url, options: [], originalContentsURL: nil)
        let loaded = try NoteStore.readBody(at: url)
        XCTAssertEqual(MarkdownWriter.write(loaded, title: "Groceries").markdown, original)
    }

    func testMarkdownDropsUnderlineColorsHighlightsAndAlignment() {
        let tv = editor(["Plain words here"])
        apply(.underline, to: "Plain", in: tv)
        apply(.textColor(EditorStyle.textColors[0].color), to: "words", in: tv)
        apply(.highlight(EditorStyle.highlightColors[0].color), to: "here", in: tv)
        apply(.align(.center), to: "Plain", in: tv)
        XCTAssertEqual(MarkdownWriter.write(tv.attributedString(), title: "x").markdown, "Plain words here\n")
    }

    func testMarkdownNestsMixedListsAndQuotes() {
        let tv = editor(["One", "Sub", "Two", "Line one", "Line two"])
        tv.setSelectedRange(NSRange(location: 0, length: range(of: "Two", in: tv).upperBound))
        tv.perform(.list(.numbered))
        apply(.indent, to: "Sub", in: tv)
        apply(.list(.checklist), to: "Sub", in: tv)
        tv.setSelectedRange(NSRange(location: range(of: "Line one", in: tv).location, length: range(of: "Line two", in: tv).upperBound - range(of: "Line one", in: tv).location))
        tv.perform(.block(.quote))
        XCTAssertEqual(MarkdownWriter.write(tv.attributedString(), title: "x").markdown, """
        1. One
          - [ ] Sub
        2. Two

        > Line one
        >
        > Line two

        """)
    }

    func testMarkdownEscapesTextThatLooksLikeMarkup() {
        let tv = editor(["1. not a list", "# not a heading", "a *star* and [link] and snake_case and _x_", "- dash"])
        XCTAssertEqual(MarkdownWriter.write(tv.attributedString(), title: "x").markdown, """
        1\\. not a list

        \\# not a heading

        a \\*star\\* and \\[link\\] and snake_case and \\_x\\_

        \\- dash

        """)
    }

    func testMarkdownOfSelectionAndEmptyNote() {
        let tv = editor(["Alpha beta", "Gamma"])
        apply(.bold, to: "beta", in: tv)
        let selection = tv.attributedString().attributedSubstring(from: range(of: "beta", in: tv))
        XCTAssertEqual(MarkdownWriter.write(selection, title: "x").markdown, "**beta**\n")
        XCTAssertEqual(MarkdownWriter.write(NSAttributedString(), title: "x"), MarkdownExport(markdown: "", assets: []))
    }

    // MARK: HTML

    func testHTMLEmbedsImagesAndKeepsColors() throws {
        let tv = try fullNote()
        let red = EditorStyle.textColors[0].color
        let yellow = EditorStyle.highlightColors[0].color
        apply(.textColor(red), to: "Quoted", in: tv)
        apply(.highlight(yellow), to: "After", in: tv)
        apply(.underline, to: "here", in: tv)
        let html = HTMLWriter.write(tv.attributedString(), title: "Groceries & more")

        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<title>Groceries &amp; more</title>"))
        XCTAssertTrue(html.contains("<img src=\"data:image/png;base64,"))
        XCTAssertTrue(html.contains("color: \(HTMLWriter.cssColor(red)!)"))
        XCTAssertTrue(html.contains("<mark style=\"background-color: \(HTMLWriter.cssColor(yellow)!)\">After</mark>"))
        XCTAssertTrue(html.contains("<u>here</u>"))
        XCTAssertTrue(html.contains("<h1>Groceries</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com/a\">site</a>"))
        XCTAssertTrue(html.contains("<li class=\"checked\"><input type=\"checkbox\" disabled checked> Done task"))
        XCTAssertTrue(html.contains("<pre><code>let x = 1\nlet y = 2</code></pre>"))
        XCTAssertTrue(html.contains("<th>Name</th>"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertFalse(html.contains("src=\"http"), "no external resources")
        // Nested bullets: Apples and Pears sit inside the item above them.
        XCTAssertTrue(html.contains("<ul>\n<li>Fruit<ul>\n<li>Apples<ul>\n<li>Pears</li></ul>\n</li></ul>\n</li></ul>"), html)
    }

    // MARK: File names

    func testFileNamesAreSanitized() {
        XCTAssertEqual(ExportNaming.sanitized("Q3: plan/budget?"), "Q3 planbudget")
        XCTAssertEqual(ExportNaming.sanitized("  ..hidden\tnote  "), "hidden note")
        XCTAssertEqual(ExportNaming.sanitized("<>|*\"\\"), "Untitled")
        XCTAssertEqual(ExportNaming.sanitized(""), "Untitled")
        XCTAssertEqual(ExportNaming.sanitized("Käse & Brot – 2026"), "Käse & Brot – 2026")
        XCTAssertEqual(ExportNaming.sanitized(String(repeating: "a", count: 300)).count, ExportNaming.maxLength)
    }

    func testDuplicateNamesGetNumbers() {
        var taken = Set<String>()
        XCTAssertEqual(ExportNaming.unique("Note", extension: "md", taken: &taken), "Note.md")
        XCTAssertEqual(ExportNaming.unique("Note", extension: "md", taken: &taken), "Note 2.md")
        XCTAssertEqual(ExportNaming.unique("note", extension: "md", taken: &taken), "note 3.md")
        XCTAssertEqual(ExportNaming.unique("Note", extension: "html", taken: &taken), "Note.html")
        XCTAssertEqual(ExportNaming.unique("Work", extension: "", taken: &taken), "Work")
        XCTAssertEqual(ExportNaming.unique("Work", extension: "", taken: &taken), "Work 2")
    }

    // MARK: Folders

    private func meta(_ title: String, in notebook: Notebook?, created: TimeInterval) -> NoteMeta {
        NoteMeta(id: UUID(), notebookID: notebook?.id, title: title, preview: "", isPinned: false,
                 createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(), tags: [])
    }

    private func notebook(_ name: String, _ index: Int) -> Notebook {
        Notebook(id: UUID(), name: name, symbol: "book", colorHex: "#0A84FF", sortIndex: index)
    }

    private func files(in url: URL) -> [String] {
        let root = url.resolvingSymlinksInPath().path + "/"
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)!
        return enumerator.compactMap { ($0 as? URL)?.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "") }.sorted()
    }

    func testExportAllWritesOneFolderPerNotebook() throws {
        let work = notebook("Work", 0), home = notebook("Home: Garden", 1), empty = notebook("Empty", 2)
        let notes = [
            meta("Plan", in: work, created: 2),
            meta("Plan", in: work, created: 1),
            meta("Roses / tulips", in: home, created: 1),
            meta("", in: nil, created: 1),
        ]
        let bodies = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, EditorStyle.paragraph($0.displayTitle, kind: .title)) })
        let result = try NoteExporter.exportAll(notebooks: [work, home, empty], notes: notes, format: .markdown, to: folder) { bodies[$0]! }

        XCTAssertEqual(result.folder.lastPathComponent, "NoteIt Export")
        XCTAssertEqual(result.noteCount, 4)
        XCTAssertEqual(files(in: result.folder), [
            "Empty", "Home Garden", "Home Garden/Roses tulips.md", "No Notebook", "No Notebook/New Note.md",
            "Work", "Work/Plan 2.md", "Work/Plan.md",
        ])
        // The older note keeps the plain name.
        let plan = try String(contentsOf: result.folder.appendingPathComponent("Work/Plan.md"), encoding: .utf8)
        XCTAssertEqual(plan, "# Plan\n")

        let again = try NoteExporter.exportAll(notebooks: [work], notes: [], format: .html, to: folder) { _ in NSAttributedString() }
        XCTAssertEqual(again.folder.lastPathComponent, "NoteIt Export 2")
    }

    func testExportNotebookWritesOnlyItsNotesAndAssets() throws {
        let work = notebook("Work", 0), other = notebook("Other", 1)
        let tv = editor(["Trip"])
        apply(.block(.title), to: "Trip", in: tv)
        try appendImage(to: tv)
        let notes = [meta("Trip", in: work, created: 1), meta("Elsewhere", in: other, created: 1)]
        let body = tv.attributedString()
        let result = try NoteExporter.exportNotebook(work, notes: notes, format: .markdown, to: folder) { _ in body }
        XCTAssertEqual(result.noteCount, 1)
        XCTAssertEqual(files(in: result.folder), ["Trip assets", "Trip assets/image-1.png", "Trip.md"])
        let markdown = try String(contentsOf: result.folder.appendingPathComponent("Trip.md"), encoding: .utf8)
        XCTAssertEqual(markdown, "# Trip\n\n![](<Trip assets/image-1.png>)\n")

        let second = try NoteExporter.exportNotebook(work, notes: notes, format: .plainText, to: folder) { _ in body }
        XCTAssertEqual(second.folder.lastPathComponent, "Work 2")
        XCTAssertEqual(files(in: second.folder), ["Trip.txt"])
    }

    func testEveryFormatWritesAFile() throws {
        let tv = try fullNote()
        let body = tv.attributedString()
        for format in ExportFormat.allCases {
            let url = folder.appendingPathComponent("Groceries.\(format.fileExtension)")
            try NoteExporter.write(body, title: "Groceries", format: format, to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), format.rawValue)
        }
        let pdf = try Data(contentsOf: folder.appendingPathComponent("Groceries.pdf"))
        XCTAssertEqual(String(decoding: pdf.prefix(4), as: UTF8.self), "%PDF")
        let rtfd = try NoteStore.readBody(at: folder.appendingPathComponent("Groceries.rtfd"))
        XCTAssertEqual(rtfd.string.trimmingCharacters(in: .newlines), body.string.trimmingCharacters(in: .newlines))
        let text = try String(contentsOf: folder.appendingPathComponent("Groceries.txt"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Groceries\nPlan\nDetails\n"))
        XCTAssertTrue(text.contains("  - Apples\n"))
        XCTAssertTrue(text.contains("☑ Done task\n"))
        XCTAssertTrue(text.contains("Name\tQty\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Groceries assets/image-1.png").path))
    }

    func testExportableNotesIsTheSingleFilter() {
        let notes = [meta("A", in: nil, created: 1), meta("B", in: nil, created: 2)]
        XCTAssertEqual(NoteExporter.exportableNotes(in: notes), notes)
    }
}
