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

    func testMarkdownNestsUnderNumberedItemsAtTheirTextColumn() {
        let items = (1...10).map { "Item \($0)" } + ["Bullet child", "Number child", "Deep", "Task", "Task child"]
        let tv = editor(items)
        tv.setSelectedRange(NSRange(location: 0, length: range(of: "Item 10", in: tv).upperBound))
        tv.perform(.list(.numbered))
        tv.setSelectedRange(NSRange(location: range(of: "Bullet child", in: tv).location, length: range(of: "Deep", in: tv).upperBound - range(of: "Bullet child", in: tv).location))
        tv.perform(.list(.numbered))
        tv.perform(.indent)
        apply(.list(.bullet), to: "Bullet child", in: tv)
        apply(.indent, to: "Deep", in: tv)
        tv.setSelectedRange(NSRange(location: range(of: "Task", in: tv).location, length: range(of: "Task child", in: tv).upperBound - range(of: "Task", in: tv).location))
        tv.perform(.list(.checklist))
        apply(.indent, to: "Task child", in: tv)

        let markdown = MarkdownWriter.write(tv.attributedString(), title: "x").markdown
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Bullet and numbered children under "10. " are indented 4 spaces; a numbered grandchild
        // under "1. " (at column 4) is indented 4 + 3.
        XCTAssertTrue(lines.contains("10. Item 10"), markdown)
        XCTAssertTrue(lines.contains("    - Bullet child"), markdown)
        XCTAssertTrue(lines.contains("    1. Number child"), markdown)
        XCTAssertTrue(lines.contains("       1. Deep"), markdown)
        XCTAssertTrue(lines.contains("- [ ] Task"), markdown)
        XCTAssertTrue(lines.contains("  - [ ] Task child"), markdown)
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

    func testMarkdownEscapesMarkupAfterLineBreaks() {
        let tv = editor(["Intro\u{2028}- not a list\u{2028} # not a heading\u{2028}--\u{2028}2. not numbered"])
        XCTAssertEqual(MarkdownWriter.write(tv.attributedString(), title: "x").markdown,
                       "Intro\\\n\\- not a list\\\n\\# not a heading\\\n\\--\\\n2\\. not numbered\n")
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
        XCTAssertTrue(html.contains("<li class=\"checked\"><input type=\"checkbox\" disabled checked> <span class=\"done\">Done task</span>"))
        XCTAssertTrue(html.contains("<pre><code>let x = 1\nlet y = 2</code></pre>"))
        XCTAssertTrue(html.contains("<th>Name</th>"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertFalse(html.contains("src=\"http"), "no external resources")
        // Nested bullets: Apples and Pears sit inside the item above them.
        XCTAssertTrue(html.contains("<ul>\n<li>Fruit<ul>\n<li>Apples<ul>\n<li>Pears</li></ul>\n</li></ul>\n</li></ul>"), html)
    }

    func testHTMLStrikesThroughOnlyTheCheckedItemItself() {
        let tv = editor(["Parent", "Child", "Sibling"])
        tv.setSelectedRange(NSRange(location: range(of: "Parent", in: tv).location, length: range(of: "Sibling", in: tv).upperBound - range(of: "Parent", in: tv).location))
        tv.perform(.list(.checklist))
        apply(.indent, to: "Child", in: tv)
        apply(.toggleCheckbox, to: "Parent", in: tv)
        let html = HTMLWriter.write(tv.attributedString(), title: "Tasks")

        XCTAssertTrue(html.contains("<span class=\"done\">Parent</span><ul class=\"checklist\">"), html)
        XCTAssertTrue(html.contains("<li class=\"unchecked\"><input type=\"checkbox\" disabled> Child"), html)
        XCTAssertFalse(html.contains("<span class=\"done\">Child"), html)
        XCTAssertFalse(html.contains("li.checked"), "the strike-through is on the item's own text, not its children")
        XCTAssertTrue(html.contains(".done { color: var(--muted); text-decoration: line-through; }"))
    }

    func testHTMLEscapesTextSoNotesCantInjectTags() {
        let tv = editor(["<script>alert('x')</script> & \"quoted\""])
        let html = HTMLWriter.write(tv.attributedString(), title: "<b>'Title'</b>")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("<p>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;quoted&quot;</p>"), html)
        XCTAssertTrue(html.contains("<title>&lt;b&gt;&#39;Title&#39;&lt;/b&gt;</title>"))
        XCTAssertEqual(HTMLWriter.escape("a'b\"c<d>&"), "a&#39;b&quot;c&lt;d&gt;&amp;")
    }

    private func linkedNote(_ links: [(text: String, url: String)]) -> NoteItTextView {
        let tv = editor([links.map(\.text).joined(separator: " ")])
        for link in links {
            let r = range(of: link.text, in: tv)
            tv.editAttributes(in: r) { $0.addAttribute(.link, value: Self.url(link.url), range: r) }
        }
        return tv
    }

    func testHTMLKeepsOnlySafeLinks() {
        let tv = linkedNote([
            ("evil", "javascript:alert(1)"), ("data", "data:text/html,<b>x</b>"), ("web", "https://example.com/?a=1&b='2'"),
            ("mail", "mailto:a@example.com"), ("phone", "tel:+4612345"), ("files", "ftp://example.com/f"),
            ("rel", "notes/other.html"), ("frag", "#top"),
        ])
        let html = HTMLWriter.write(tv.attributedString(), title: "Links")
        XCTAssertFalse(html.lowercased().contains("javascript:"), html)
        XCTAssertFalse(html.contains("href=\"data:text"), html)
        XCTAssertTrue(html.contains("<p>evil data <a href="), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com/?a=1&amp;b=&#39;2&#39;\">web</a>"), html)
        XCTAssertTrue(html.contains("<a href=\"mailto:a@example.com\">mail</a>"))
        XCTAssertTrue(html.contains("<a href=\"tel:+4612345\">phone</a>"))
        XCTAssertTrue(html.contains("<a href=\"ftp://example.com/f\">files</a>"))
        XCTAssertTrue(html.contains("<a href=\"notes/other.html\">rel</a>"))
        XCTAssertTrue(html.contains("<a href=\"#top\">frag</a>"))
    }

    func testLinkSafetyIgnoresCaseAndHiddenCharacters() {
        XCTAssertFalse(ExportLinks.isSafe(URL(string: "JavaScript:alert(1)")!))
        XCTAssertFalse(ExportLinks.isSafe(URL(string: "vbscript:x")!))
        XCTAssertTrue(ExportLinks.isSafe(URL(string: "HTTPS://example.com")!))
        XCTAssertTrue(ExportLinks.isSafe(URL(string: "page.html#a:b")!))
        XCTAssertTrue(ExportLinks.isSafe(URL(string: "/a:b")!))
    }

    func testMarkdownDropsUnsafeLinks() {
        let tv = linkedNote([("evil", "javascript:alert(1)"), ("web", "https://example.com")])
        let markdown = MarkdownWriter.write(tv.attributedString(), title: "x").markdown
        XCTAssertEqual(markdown, "evil [web](https://example.com)\n")
    }

    /// Also builds URLs that `URL(string:)` rejects but other sources, such as pasted rich text, can store.
    private static func url(_ s: String) -> URL {
        URL(string: s) ?? URL(dataRepresentation: Data(s.utf8), relativeTo: nil)!
    }

    private static let encodedSchemes = [
        "javascript&colon;alert(1)", "javascript&#58;alert(1)", "javascript&#x3A;alert(1)", "JavaScript&COLON;alert(1)",
        "javascript&#0000058alert(1)", "java%73cript:alert(1)", "java%73cript%3Aalert(1)", "java\tscript:alert(1)",
        "java&Tab;script&colon;alert(1)",
    ]

    func testLinkSafetyDecodesReferencesAndPercentEscapes() {
        for raw in Self.encodedSchemes { XCTAssertFalse(ExportLinks.isSafe(Self.url(raw)), raw) }
        XCTAssertTrue(ExportLinks.isSafe(URL(string: "https://example.com/?a=1&colon=2")!))
        XCTAssertTrue(ExportLinks.isSafe(URL(string: "notes/a&amp;b.html")!))
    }

    func testMarkdownDropsEncodedUnsafeLinks() {
        for raw in Self.encodedSchemes {
            let tv = linkedNote([("evil", raw)])
            XCTAssertEqual(MarkdownWriter.write(tv.attributedString(), title: "x").markdown, "evil\n", raw)
        }
    }

    func testMarkdownEscapesAmpersandsInLinks() {
        let tv = linkedNote([("web", "https://example.com/?a=1&b=2&colon=3")])
        let markdown = MarkdownWriter.write(tv.attributedString(), title: "x").markdown
        XCTAssertEqual(markdown, "[web](https://example.com/?a=1\\&b=2\\&colon=3)\n")
        let read = MarkdownReader.attributedString(from: markdown, resolveImage: { _ in nil })
        XCTAssertEqual(read.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://example.com/?a=1&b=2&colon=3"))
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

    private func imageNote(_ title: String) throws -> NSAttributedString {
        let tv = editor([title])
        apply(.block(.title), to: title, in: tv)
        try appendImage(to: tv)
        return tv.attributedString()
    }

    func testMarkdownNeverReplacesAnExistingAssetsFolder() throws {
        let body = try imageNote("Trip")
        let existing = folder.appendingPathComponent("Trip assets", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing.appendingPathComponent("image-1.png"))
        let url = folder.appendingPathComponent("Trip.md")

        try NoteExporter.write(body, title: "Trip", format: .markdown, to: url)
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("image-1.png")), Data("mine".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Trip assets 2/image-1.png").path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Trip\n\n![](<Trip assets 2/image-1.png>)\n")

        // Exporting over the same file again still leaves both folders alone.
        try NoteExporter.write(body, title: "Trip", format: .markdown, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Trip\n\n![](<Trip assets 3/image-1.png>)\n")
        XCTAssertEqual(files(in: folder).filter { $0.hasPrefix("Trip") }, [
            "Trip assets", "Trip assets 2", "Trip assets 2/image-1.png", "Trip assets 3", "Trip assets 3/image-1.png",
            "Trip assets/image-1.png", "Trip.md",
        ])
    }

    func testMarkdownSkipsAnAssetsNameTakenByAFile() throws {
        try Data("note".utf8).write(to: folder.appendingPathComponent("Trip assets"))
        let url = folder.appendingPathComponent("Trip.md")
        try NoteExporter.write(try imageNote("Trip"), title: "Trip", format: .markdown, to: url)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Trip assets"), encoding: .utf8), "note")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("<Trip assets 2/image-1.png>"))
    }

    func testMarkdownWithoutAssetsLeavesAnExistingFolderAlone() throws {
        let existing = folder.appendingPathComponent("Plain assets", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try NoteExporter.write(EditorStyle.paragraph("Plain", kind: .body), title: "Plain", format: .markdown,
                               to: folder.appendingPathComponent("Plain.md"))
        XCTAssertEqual(files(in: folder).filter { $0.hasPrefix("Plain") }, ["Plain assets", "Plain.md"])
    }

    // MARK: Large exports

    func testLargeExportsWriteInSlicesAndCanStop() async throws {
        let work = notebook("Work", 0)
        let notes = (1...5).map { meta("Note \($0)", in: work, created: TimeInterval($0)) }
        let body = { (_: UUID) in EditorStyle.paragraph("Body", kind: .body) }
        let export = try NoteExporter.prepareAll(notebooks: [work], notes: notes, format: .plainText, to: folder, body: body)
        XCTAssertEqual(export.total, 5)
        XCTAssertEqual(export.written, 0)
        XCTAssertEqual(files(in: export.folder), ["Work"], "folders are made up front, notes as they're written")

        var reports: [Int] = []
        let result = try await export.write(slice: .zero) { export in
            reports.append(export.written)
            return export.written < 2
        }
        XCTAssertEqual(reports, [1, 2])
        XCTAssertEqual(result.noteCount, 2)
        XCTAssertEqual(result.totalCount, 5)
        XCTAssertFalse(export.isFinished)
        XCTAssertEqual(files(in: result.folder), ["Work", "Work/Note 1.txt", "Work/Note 2.txt"])

        let rest = try await export.write { _ in true }
        XCTAssertEqual(rest.noteCount, 5)
        XCTAssertEqual(files(in: result.folder).count, 6)
    }

    func testSynchronousExportsReportEveryNote() throws {
        let work = notebook("Work", 0)
        let notes = [meta("A", in: work, created: 1), meta("B", in: work, created: 2)]
        let result = try NoteExporter.exportNotebook(work, notes: notes, format: .plainText, to: folder) { _ in NSAttributedString() }
        XCTAssertEqual(result.noteCount, 2)
        XCTAssertEqual(result.totalCount, 2)
    }

    func testExportableNotesIsTheSingleFilter() {
        var deleted = meta("C", in: nil, created: 3)
        deleted.deletedAt = Date()
        let notes = [meta("A", in: nil, created: 1), meta("B", in: nil, created: 2), deleted]
        XCTAssertEqual(NoteExporter.exportableNotes(in: notes), Array(notes.prefix(2)))
    }

    func testExportsSkipNotesInRecentlyDeleted() throws {
        let work = notebook("Work", 0)
        var gone = meta("Gone", in: work, created: 2)
        gone.deletedAt = Date()
        var looseGone = meta("Loose", in: nil, created: 3)
        looseGone.deletedAt = Date()
        let notes = [meta("Kept", in: work, created: 1), gone, looseGone]
        let body = { (_: UUID) in EditorStyle.paragraph("Body", kind: .body) }

        let notebookResult = try NoteExporter.exportNotebook(work, notes: notes, format: .markdown, to: folder, body: body)
        XCTAssertEqual(notebookResult.noteCount, 1)
        XCTAssertEqual(files(in: notebookResult.folder), ["Kept.md"])

        let all = try NoteExporter.exportAll(notebooks: [work], notes: notes, format: .markdown, to: folder, body: body)
        XCTAssertEqual(all.noteCount, 1)
        XCTAssertEqual(files(in: all.folder), ["Work", "Work/Kept.md"])
    }
}
