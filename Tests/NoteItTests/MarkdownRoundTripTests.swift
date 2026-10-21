import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

/// Notes built with the editor's own commands are written as Markdown and read back, and must come back
/// with the same blocks: kind, list marker and level, checked state, text and inline styles.
@MainActor
final class MarkdownRoundTripTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteItRoundTripTests-\(UUID().uuidString)", isDirectory: true)
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

    private func range(from first: String, to last: String, in textView: NoteItTextView) -> NSRange {
        let start = range(of: first, in: textView).location
        return NSRange(location: start, length: range(of: last, in: textView).upperBound - start)
    }

    private func apply(_ command: FormatCommand, to text: String, in textView: NoteItTextView) {
        textView.setSelectedRange(range(of: text, in: textView))
        textView.perform(command)
    }

    private func apply(_ command: FormatCommand, from first: String, to last: String, in textView: NoteItTextView) {
        textView.setSelectedRange(range(from: first, to: last, in: textView))
        textView.perform(command)
    }

    private func appendImage(to textView: NoteItTextView) throws {
        let image = NSImage(size: NSSize(width: 4, height: 3))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 3).fill()
        image.unlockFocus()
        let url = folder.appendingPathComponent("photo.png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
        textView.replace(NSRange(location: textView.storage.length, length: 0), with: EditorStyle.paragraph("", kind: .body))
        textView.setSelectedRange(NSRange(location: textView.storage.length - 1, length: 0))
        textView.insertImages([url])
    }

    // MARK: Comparing

    /// One line per paragraph (per row for tables): block, marker and level, then the runs with their styles.
    private func structure(_ text: NSAttributedString) -> [String] {
        NoteBlocks.parse(text).flatMap { block -> [String] in
            switch block {
            case .paragraph(let kind, _, let runs):
                return ["\(kind.rawValue): \(describe(runs))"]
            case .listItem(let marker, let level, _, let runs):
                let name: String
                switch marker {
                case .bullet: name = "bullet"
                case .numbered(let n): name = "numbered \(n)"
                case .checkbox(let checked): name = checked ? "checked" : "unchecked"
                }
                return ["\(name) level \(level): \(describe(runs))"]
            case .code(let code, let language):
                let lines = code.components(separatedBy: "\n").map { "code: \($0)" }
                guard let language else { return lines }
                return ["code language: \(language.identifier)"] + lines
            case .divider:
                return ["divider"]
            case .table(let rows):
                return rows.map { "row: " + $0.map(describe).joined(separator: " | ") }
            }
        }
    }

    private func describe(_ runs: [InlineRun]) -> String {
        var parts: [(style: String, text: String)] = []
        for run in runs {
            var style: [String] = []
            if run.bold { style.append("b") }
            if run.italic { style.append("i") }
            if run.strikethrough { style.append("s") }
            if run.code { style.append("code") }
            if let link = run.link { style.append("link=\(link.absoluteString)") }
            if let contents = run.attachment?.exportContents {
                parts.append(("image", "\(contents.isImage) \(contents.data.count) bytes"))
                continue
            }
            // Markdown keeps spaces outside emphasis delimiters, so their style isn't compared.
            let key = style.joined(separator: ",")
            let keepsSpaces = run.code || run.link != nil
            let lead = keepsSpaces ? "" : String(run.text.prefix { $0 == " " })
            let rest = run.text.dropFirst(lead.count)
            let trail = keepsSpaces ? "" : String(rest.reversed().prefix { $0 == " " })
            for (partKey, text) in [("", lead), (key, String(rest.dropLast(trail.count))), ("", trail)] where !text.isEmpty {
                if let last = parts.last, last.style == partKey, partKey != "image" {
                    parts[parts.count - 1].text += text
                } else {
                    parts.append((partKey, text))
                }
            }
        }
        let text = parts.map { $0.style.isEmpty ? $0.text : "[\($0.style)]\($0.text)" }.joined()
        return text.replacingOccurrences(of: NoteBlocks.lineBreak, with: "⏎")
    }

    /// Writes `text` as Markdown with its assets in a folder, then reads it back resolving images there.
    private func roundTrip(_ text: NSAttributedString, title: String = "Note") throws -> (markdown: String, body: NSAttributedString) {
        let export = MarkdownWriter.write(text, title: title)
        let assets = folder.appendingPathComponent(MarkdownWriter.assetsFolderName(for: title), isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for asset in export.assets {
            try asset.data.write(to: assets.appendingPathComponent(asset.filename))
        }
        let folder = self.folder!
        let body = MarkdownReader.attributedString(from: export.markdown) { ref in
            let url = folder.appendingPathComponent(ref)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return (export.markdown, body)
    }

    private func assertRoundTrip(_ textView: NoteItTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        let original = textView.attributedString()
        let (markdown, body) = try roundTrip(original)
        XCTAssertEqual(structure(body), structure(original), markdown, file: file, line: line)
        XCTAssertEqual(MarkdownWriter.write(body, title: "Note").markdown, markdown, "second write", file: file, line: line)
    }

    // MARK: Tests

    func testHeadingsAndInlineStyles() throws {
        let tv = editor([
            "Groceries", "Plan", "Details",
            "Buy bold and italic and gone and code here, see the site now.",
            "Mixed bold italic words and a bold link.",
        ])
        apply(.block(.title), to: "Groceries", in: tv)
        apply(.block(.heading), to: "Plan", in: tv)
        apply(.block(.subheading), to: "Details", in: tv)
        apply(.bold, to: "bold", in: tv)
        apply(.italic, to: "italic", in: tv)
        apply(.strikethrough, to: "gone", in: tv)
        apply(.inlineCode, to: "code", in: tv)
        let site = range(of: "the site", in: tv)
        tv.editAttributes(in: site) { $0.addAttribute(.link, value: URL(string: "https://example.com/a?b=1&c=2&amp;d")!, range: site) }
        apply(.bold, to: "bold italic", in: tv)
        apply(.italic, to: "italic words", in: tv)
        let link = range(of: "bold link", in: tv)
        tv.editAttributes(in: link) { $0.addAttribute(.link, value: URL(string: "https://example.com/b")!, range: link) }
        apply(.bold, to: "bold link", in: tv)

        XCTAssertEqual(structure(tv.attributedString()).first, "title: Groceries")
        try assertRoundTrip(tv)
    }

    func testNestedListsWithMixedMarkersAndCheckedItems() throws {
        let tv = editor([
            "Fruit", "Apples", "Green", "Pears",
            "First", "Sub task", "Done sub task", "Sub bullet", "Second", "Inner number", "Inner two",
            "Open task", "Done task", "Nested bullet", "Nested done",
        ])
        apply(.list(.bullet), from: "Fruit", to: "Pears", in: tv)
        apply(.indent, from: "Apples", to: "Pears", in: tv)
        apply(.indent, to: "Green", in: tv)

        apply(.list(.numbered), from: "First", to: "Inner two", in: tv)
        apply(.indent, from: "Sub task", to: "Sub bullet", in: tv)
        apply(.list(.checklist), from: "Sub task", to: "Done sub task", in: tv)
        apply(.toggleCheckbox, to: "Done sub task", in: tv)
        apply(.list(.bullet), to: "Sub bullet", in: tv)
        apply(.indent, from: "Inner number", to: "Inner two", in: tv)

        apply(.list(.checklist), from: "Open task", to: "Nested done", in: tv)
        apply(.toggleCheckbox, to: "Done task", in: tv)
        apply(.indent, from: "Nested bullet", to: "Nested done", in: tv)
        apply(.list(.bullet), to: "Nested bullet", in: tv)
        apply(.toggleCheckbox, to: "Nested done", in: tv)

        XCTAssertEqual(structure(tv.attributedString()), [
            "bullet level 0: Fruit",
            "bullet level 1: Apples",
            "bullet level 2: Green",
            "bullet level 1: Pears",
            "numbered 1 level 0: First",
            "unchecked level 1: Sub task",
            "checked level 1: Done sub task",
            "bullet level 1: Sub bullet",
            "numbered 2 level 0: Second",
            "numbered 1 level 1: Inner number",
            "numbered 2 level 1: Inner two",
            "unchecked level 0: Open task",
            "checked level 0: Done task",
            "bullet level 1: Nested bullet",
            "checked level 1: Nested done",
        ])
        try assertRoundTrip(tv)
    }

    func testNewListItemKeepsPreviousTextSizeBeforeTyping() {
        let (_, tv) = NoteItTextView.make()
        tv.storage.setAttributedString(EditorStyle.bullet("test"))
        let text = range(of: "test", in: tv)
        let customFont = NSFont.systemFont(ofSize: 24)
        tv.storage.addAttribute(.font, value: customFont, range: text)
        tv.setSelectedRange(NSRange(location: text.upperBound, length: 0))

        XCTAssertTrue(tv.handleNewline())

        let newParagraph = tv.paragraphRange(at: tv.selectedRange().location)
        guard let marker = tv.marker(ofParagraph: newParagraph) else {
            XCTFail("The new list item should have a marker.")
            return
        }
        let markerFont = tv.storage.attribute(.font, at: tv.selectedRange().location - marker.length, effectiveRange: nil) as? NSFont
        XCTAssertEqual(markerFont?.pointSize, customFont.pointSize)
        XCTAssertEqual((tv.typingAttributes[.font] as? NSFont)?.pointSize, customFont.pointSize)
    }

    func testNewChecklistItemCheckboxKeepsPreviousTextSize() throws {
        let (_, tv) = NoteItTextView.make()
        let item: [NSAttributedString.Key: Any] = [.font: EditorStyle.bodyFont, .paragraphStyle: EditorStyle.listParagraphStyle(level: 0)]
        tv.storage.setAttributedString(NSAttributedString(string: "\u{2610}\ttest\n", attributes: item))
        let text = range(of: "test", in: tv)
        let customFont = NSFont.systemFont(ofSize: 11)
        tv.storage.addAttribute(.font, value: customFont, range: text)
        tv.setSelectedRange(NSRange(location: text.upperBound, length: 0))

        XCTAssertTrue(tv.handleNewline())

        let lm = try XCTUnwrap(tv.layoutManager as? NoteItLayoutManager)
        let newItem = tv.paragraphRange(at: tv.selectedRange().location)
        let box = lm.checkboxRect(forCharacterAt: newItem.location, origin: .zero)
        let firstBox = lm.checkboxRect(forCharacterAt: 0, origin: .zero)
        XCTAssertEqual(box.width, firstBox.width)
    }

    func testReturnOnWhitespaceOnlyListItemEndsTheList() {
        let (_, tv) = NoteItTextView.make()
        let text = NSMutableAttributedString(attributedString: EditorStyle.bullet("a"))
        text.append(EditorStyle.bullet("  "))
        tv.storage.setAttributedString(text)
        tv.setSelectedRange(NSRange(location: tv.storage.length - 1, length: 0))

        tv.insertNewline(nil)

        XCTAssertEqual(tv.string, "\u{2022}\ta\n\n")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: tv.storage.length - 1, length: 0))
    }

    func testReturnOverSelectionInListItemContinuesTheList() {
        let (_, tv) = NoteItTextView.make()
        tv.storage.setAttributedString(EditorStyle.bullet("abcdef"))
        tv.setSelectedRange(NSRange(location: range(of: "cd", in: tv).location, length: 2))

        tv.insertNewline(nil)

        XCTAssertEqual(tv.string, "\u{2022}\tab\n\u{2022}\tef\n")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: range(of: "ef", in: tv).location, length: 0))
    }

    func testJoiningLinesRedrawsTheTextThatMovesUp() {
        let (scrollView, tv) = NoteItTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scrollView
        tv.isEditable = true
        var item: [NSAttributedString.Key: Any] = [.font: EditorStyle.bodyFont, .paragraphStyle: EditorStyle.listParagraphStyle(level: 0)]
        let text = NSMutableAttributedString(string: "\u{2610}\t", attributes: item)
        item[.font] = NSFont.systemFont(ofSize: 11)
        text.append(NSAttributedString(string: "test\n", attributes: item))
        item[.font] = EditorStyle.bodyFont
        text.append(NSAttributedString(string: "\u{2610}\t\n", attributes: item))
        text.append(EditorStyle.paragraph("", kind: .body))
        text.append(EditorStyle.paragraph("#welcome", kind: .body))
        tv.storage.setAttributedString(text)
        settleAndDisplay(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "test\n").upperBound + 2, length: 0))
        tv.deleteBackward(nil)
        settleAndDisplay(tv)

        let drawn = recordingDrawnRects(of: tv) {
            tv.deleteBackward(nil)
            settleAndDisplay(tv)
        }

        XCTAssertTrue(tv.string.hasSuffix("\u{2610}\ttest\n\n#welcome\n"), tv.string)
        let lm = tv.layoutManager!
        let glyphs = lm.glyphRange(forCharacterRange: (tv.string as NSString).range(of: "#welcome"), actualCharacterRange: nil)
        let moved = lm.boundingRect(forGlyphRange: glyphs, in: tv.textContainer!)
            .offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
        XCTAssertTrue(drawn.contains { $0.contains(moved) }, "The line that moved up must be redrawn: \(moved) not in \(drawn)")
    }

    private func settleAndDisplay(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view.displayIfNeeded()
    }

    private func recordingDrawnRects(of view: NSView, during body: () -> Void) -> [NSRect] {
        let selector = #selector(NSView.draw(_:))
        let method = class_getInstanceMethod(NSTextView.self, selector)!
        typealias Draw = @convention(c) (NSView, Selector, NSRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Draw.self)
        var rects: [NSRect] = []
        let block: @convention(block) (NSView, NSRect) -> Void = { target, rect in
            if target === view { rects.append(rect) }
            original(target, selector, rect)
        }
        let previous = method_setImplementation(method, imp_implementationWithBlock(block))
        defer { method_setImplementation(method, previous) }
        body()
        return rects
    }

    func testQuoteCodeDividerTableAndImage() throws {
        let tv = editor([
            "Quoted words", "Second quote",
            "# not a heading", "- not a list", "```", "let x = **1**",
            "After the code",
        ])
        apply(.block(.quote), from: "Quoted words", to: "Second quote", in: tv)
        apply(.block(.code), from: "# not a heading", to: "let x = **1**", in: tv)
        tv.setSelectedRange(NSRange(location: range(of: "After the code", in: tv).upperBound, length: 0))
        tv.perform(.divider)
        let table = EditorStyle.table(header: ["Name", "Qty"], rows: [["Apples", "3"], ["Pears | ripe", "5"]])
        tv.replace(NSRange(location: tv.storage.length, length: 0), with: table)
        try appendImage(to: tv)

        let blocks = structure(tv.attributedString())
        XCTAssertEqual(Array(blocks.dropLast()), [
            "quote: Quoted words",
            "quote: Second quote",
            "code: # not a heading",
            "code: - not a list",
            "code: ```",
            "code: let x = **1**",
            "body: After the code",
            "divider",
            "row: Name | Qty",
            "row: Apples | 3",
            "row: Pears | ripe | 5",
        ])
        XCTAssertTrue(blocks.last?.hasPrefix("body: [image]true ") ?? false, blocks.last ?? "")
        try assertRoundTrip(tv)
    }

    func testParagraphsAndLineBreaks() throws {
        let tv = editor([
            "First paragraph.",
            "Second paragraph with a\u{2028}line break and **stars**.",
            "Item with a\u{2028}second line",
            "Quote with a\u{2028}second line",
            "Ends with a break\u{2028}- not a list\u{2028}# not a heading\u{2028}---\u{2028}=",
        ])
        apply(.list(.bullet), to: "Item with a", in: tv)
        apply(.block(.quote), to: "Quote with a", in: tv)

        XCTAssertEqual(structure(tv.attributedString()), [
            "body: First paragraph.",
            "body: Second paragraph with a⏎line break and **stars**.",
            "bullet level 0: Item with a⏎second line",
            "quote: Quote with a⏎second line",
            "body: Ends with a break⏎- not a list⏎# not a heading⏎---⏎=",
        ])
        try assertRoundTrip(tv)
    }

    func testMarkdownFromOtherAppsIsStableAfterOneRead() {
        let markdown = """
        # Trip

        A paragraph written
        over two lines.


        Another paragraph after extra blank lines.
        Line with a hard break\\
        and the next line.

        * Star bullet
        * __Bold__ and _italic_
            * Nested with four spaces

        1) Paren numbered
        2) Second

        - [ ] Task
        - [X] Done

        > Quote line one
        > quote line two
        >
        > Second quote paragraph

        ~~~
        code with ``` inside
        ~~~

        ***

        | A | B |
        |:--|--:|
        | 1 | `x \\| y` |

        Text then a [[Wiki link]] and https://example.com.
        """
        let first = MarkdownWriter.write(MarkdownReader.attributedString(from: markdown), title: "Trip").markdown
        let second = MarkdownWriter.write(MarkdownReader.attributedString(from: first), title: "Trip").markdown
        XCTAssertEqual(second, first)
        XCTAssertFalse(first.contains("\n\n\n"), first)
        XCTAssertTrue(first.contains("A paragraph written\\\nover two lines.\n\nAnother paragraph after extra blank lines."), first)
        XCTAssertTrue(first.contains("> Quote line one\\\n> quote line two\n>\n> Second quote paragraph"), first)
    }

    func testWikiLinksRoundTripThroughImporter() async throws {
        let work = Notebook(id: UUID(), name: "Work", symbol: "book", colorHex: "#0A84FF", sortIndex: 0)
        func meta(_ title: String) -> NoteMeta {
            NoteMeta(id: UUID(), notebookID: work.id, title: title, preview: "", isPinned: false,
                     createdAt: Date(), updatedAt: Date(), tags: [])
        }
        let atlas = meta("Atlas"), plan = meta("Plan")
        func body(_ title: String, _ text: String, _ link: NoteLink) -> NSAttributedString {
            let out = NSMutableAttributedString(attributedString: EditorStyle.paragraph(title, kind: .title))
            var attrs = EditorStyle.bodyAttributes
            attrs[.link] = link.url
            out.append(NSAttributedString(string: text, attributes: attrs))
            out.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
            return out
        }
        let bodies = [atlas.id: body("Atlas", "the plan", .note(id: plan.id, heading: "Steps")),
                      plan.id: body("Plan", "Atlas", .note(id: atlas.id, heading: nil))]
        let result = try NoteExporter.exportNotebook(work, notes: [atlas, plan], format: .markdown, to: folder) { bodies[$0]! }

        let store = NoteStore(location: LibraryLocation(url: folder.appendingPathComponent("Library", isDirectory: true), seedsFreshLibrary: false))
        _ = await MarkdownImporter(store: store).run(MarkdownImporter.items(for: [result.folder])) { _ in }
        let ids = Dictionary(uniqueKeysWithValues: store.notes.map { ($0.title, $0.id) })
        func links(_ id: UUID?) -> [NoteLink] {
            guard let id else { return [] }
            let text = store.body(for: id)
            var out: [NoteLink] = []
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let url = value as? URL, let link = NoteLink(url: url) { out.append(link) }
            }
            return out
        }
        XCTAssertEqual(links(ids["Atlas"]), [.note(id: ids["Plan"]!, heading: "Steps")])
        XCTAssertEqual(links(ids["Plan"]), [.note(id: ids["Atlas"]!, heading: nil)])
        XCTAssertTrue(store.body(for: ids["Atlas"]!).string.contains("the plan"))
    }

    func testSameNamedNotesInTwoNotebooksKeepTheirLinks() async throws {
        try await sameNamedRoundTrip(work: "Work", home: "Home", written: "[[Work/Plan]] [[Home/Plan|home]]")
    }

    func testFolderPartsOfLinksDropLinkSyntaxCharacters() async throws {
        try await sameNamedRoundTrip(work: "C# Work", home: "[Old]", written: "[[C Work/Plan]] [[Old/Plan|home]]")
    }

    private func sameNamedRoundTrip(work workName: String, home homeName: String, written: String) async throws {
        let work = Notebook(id: UUID(), name: workName, symbol: "book", colorHex: "#0A84FF", sortIndex: 0)
        let home = Notebook(id: UUID(), name: homeName, symbol: "book", colorHex: "#0A84FF", sortIndex: 1)
        func meta(_ title: String, _ notebook: Notebook) -> NoteMeta {
            NoteMeta(id: UUID(), notebookID: notebook.id, title: title, preview: "", isPinned: false,
                     createdAt: Date(), updatedAt: Date(), tags: [])
        }
        let workPlan = meta("Plan", work), homePlan = meta("Plan", home), index = meta("Index", home)
        func body(_ title: String, _ links: [(String, NoteLink)]) -> NSAttributedString {
            let out = NSMutableAttributedString(attributedString: EditorStyle.paragraph(title, kind: .title))
            for (text, link) in links {
                var attrs = EditorStyle.bodyAttributes
                attrs[.link] = link.url
                out.append(NSAttributedString(string: text, attributes: attrs))
                out.append(NSAttributedString(string: " ", attributes: EditorStyle.bodyAttributes))
            }
            out.append(NSAttributedString(string: "\n", attributes: EditorStyle.bodyAttributes))
            return out
        }
        let bodies = [workPlan.id: body("Plan", []), homePlan.id: body("Plan", []),
                      index.id: body("Index", [("Plan", .note(id: workPlan.id, heading: nil)),
                                               ("home", .note(id: homePlan.id, heading: nil))])]
        let result = try NoteExporter.exportAll(notebooks: [work, home], notes: [workPlan, homePlan, index],
                                                format: .markdown, to: folder) { bodies[$0]! }
        let markdown = try String(contentsOf: result.folder.appendingPathComponent(homeName + "/Index.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains(written), markdown)

        let store = NoteStore(location: LibraryLocation(url: folder.appendingPathComponent("Library", isDirectory: true), seedsFreshLibrary: false))
        _ = await MarkdownImporter(store: store).run(MarkdownImporter.items(for: [result.folder])) { _ in }
        let notebookNames = Dictionary(uniqueKeysWithValues: store.notebooks.map { ($0.id, $0.name) })
        func id(_ title: String, in notebook: String) throws -> UUID {
            try XCTUnwrap(store.notes.first { $0.title == title && $0.notebookID.flatMap { notebookNames[$0] }?.hasSuffix(notebook) == true }).id
        }
        let imported = try id("Index", in: homeName)
        var links: [NoteLink] = []
        let text = store.body(for: imported)
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL, let link = NoteLink(url: url) { links.append(link) }
        }
        XCTAssertEqual(links, [.note(id: try id("Plan", in: workName), heading: nil), .note(id: try id("Plan", in: homeName), heading: nil)])
    }
}
