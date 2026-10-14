import AppKit
import XCTest
@testable import NoteIt

@MainActor
final class MarkdownReaderTests: XCTestCase {
    private struct Para {
        var text: String
        var kind: BlockKind
        var marker: ListMarker?
        var level: Int
        var attrs: [NSAttributedString.Key: Any]
        var range: NSRange
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
            let kind = EditorStyle.blockKind(paragraphStyle: ps, font: font)
            let marker = EditorStyle.listMarker(in: text)
            result.append(Para(text: text, kind: kind, marker: marker,
                               level: marker != nil ? EditorStyle.listLevel(of: ps) : EditorStyle.indentLevel(of: ps, kind: kind),
                               attrs: s.attributes(at: range.location, effectiveRange: nil), range: range))
        }
        return result
    }

    private func read(_ md: String, resolve: @escaping MarkdownReader.ImageResolver = { _ in nil }) -> NSAttributedString {
        MarkdownReader.attributedString(from: md, resolveImage: resolve)
    }

    private func attrs(_ s: NSAttributedString, of substring: String) -> [NSAttributedString.Key: Any] {
        let r = (s.string as NSString).range(of: substring)
        XCTAssertNotEqual(r.location, NSNotFound, "missing \(substring)")
        return r.location == NSNotFound ? [:] : s.attributes(at: r.location, effectiveRange: nil)
    }

    private func traits(_ s: NSAttributedString, _ substring: String) -> NSFontDescriptor.SymbolicTraits {
        (attrs(s, of: substring)[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
    }

    // MARK: Blocks

    func testHeadingLevels() {
        let p = paragraphs(read("# Trip plan\n\n## Packing\n\n### Shoes\n\n#### Socks\n\nPlain text"))
        XCTAssertEqual(p.map(\.text), ["Trip plan", "Packing", "Shoes", "Socks", "Plain text"])
        XCTAssertEqual(p.map(\.kind), [.title, .heading, .subheading, .subheading, .body])
    }

    func testHashWithoutSpaceIsATagNotAHeading() {
        let p = paragraphs(read("#groceries for the week"))
        XCTAssertEqual(p.map(\.kind), [.body])
        XCTAssertEqual(p.first?.text, "#groceries for the week")
    }

    func testInlineStyles() {
        let s = read("Some **bold**, *italic*, _also italic_, ~~gone~~ and `code` here.")
        XCTAssertEqual(s.string, "Some bold, italic, also italic, gone and code here.\n")
        XCTAssertTrue(traits(s, "bold").contains(.bold))
        XCTAssertTrue(traits(s, "italic,").contains(.italic))
        XCTAssertTrue(traits(s, "also italic").contains(.italic))
        XCTAssertEqual(attrs(s, of: "gone")[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        let code = attrs(s, of: "code")
        XCTAssertEqual(code[.font] as? NSFont, EditorStyle.inlineCodeFont)
        XCTAssertEqual(code[.backgroundColor] as? NSColor, EditorStyle.inlineCodeBackground)
        XCTAssertFalse(traits(s, "Some").contains(.bold))
    }

    func testIntrawordUnderscoreStaysLiteral() {
        XCTAssertEqual(read("snake_case_name stays").string, "snake_case_name stays\n")
    }

    func testEscapedCharacters() {
        XCTAssertEqual(read("Not \\*emphasis\\* and 1\\. item").string, "Not *emphasis* and 1. item\n")
    }

    func testLinks() {
        let s = read("See [the site](https://example.com/page) or <https://example.org> or https://example.net/x.")
        XCTAssertEqual(s.string, "See the site or https://example.org or https://example.net/x.\n")
        XCTAssertEqual(attrs(s, of: "the site")[.link] as? URL, URL(string: "https://example.com/page"))
        XCTAssertEqual(attrs(s, of: "https://example.org")[.link] as? URL, URL(string: "https://example.org"))
        XCTAssertEqual(attrs(s, of: "https://example.net/x")[.link] as? URL, URL(string: "https://example.net/x"))
    }

    func testRelativeLinkBecomesPlainText() {
        let s = read("Read [Other note](Other%20note.md) next")
        XCTAssertEqual(s.string, "Read Other note next\n")
        XCTAssertNil(attrs(s, of: "Other note")[.link])
    }

    func testBulletedAndNumberedListsWithNesting() {
        let md = """
        - Fruit
          - Apples
            - Green
          - Pears
        - Bread
        1. First
        2. Second
           1. Inner
        3. Third
        """
        let p = paragraphs(read(md))
        XCTAssertEqual(p.map(\.marker?.kind), [.bullet, .bullet, .bullet, .bullet, .bullet, .numbered(1), .numbered(2), .numbered(1), .numbered(3)])
        XCTAssertEqual(p.map(\.level), [0, 1, 2, 1, 0, 0, 0, 1, 0])
        XCTAssertEqual(p[1].text, EditorStyle.markerText(.bullet, level: 1) + "Apples")
        XCTAssertEqual(p[6].text, "2.\tSecond")
        XCTAssertTrue(p.allSatisfy { $0.kind == .body })
    }

    func testNumberedListStartsAtGivenNumber() {
        let p = paragraphs(read("4. Four\n5. Five"))
        XCTAssertEqual(p.map(\.marker?.kind), [.numbered(4), .numbered(5)])
    }

    func testTaskList() {
        let s = read("- [ ] Buy milk\n- [x] Call the plumber\n  - [X] Nested done")
        let p = paragraphs(s)
        XCTAssertEqual(p.map(\.marker?.kind), [.checkbox(checked: false), .checkbox(checked: true), .checkbox(checked: true)])
        XCTAssertEqual(p.map(\.level), [0, 0, 1])
        XCTAssertNil(attrs(s, of: "Buy milk")[.strikethroughStyle])
        let done = attrs(s, of: "Call the plumber")
        XCTAssertEqual(done[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(done[.foregroundColor] as? NSColor, EditorStyle.checkedTextColor)
    }

    func testQuote() {
        let p = paragraphs(read("> First line\n> Second **line**\n>\n> Next paragraph\n\nAfter"))
        XCTAssertEqual(p.map(\.kind), [.quote, .quote, .body])
        XCTAssertEqual(p.map(\.text), ["First line\u{2028}Second line", "Next paragraph", "After"])
    }

    func testFencedCodeBlockKeepsContentVerbatim() {
        let md = """
        Before
        ```swift
        let x = **1**
            indented()

        # not a heading
        ```
        After
        """
        let p = paragraphs(read(md))
        XCTAssertEqual(p.map(\.kind), [.body, .code, .code, .code, .code, .body])
        XCTAssertEqual(p.map(\.text), ["Before", "let x = **1**", "    indented()", "", "# not a heading", "After"])
    }

    func testDividers() {
        let p = paragraphs(read("Above\n\n---\n\n***\n\nBelow"))
        XCTAssertEqual(p.map(\.kind), [.body, .divider, .divider, .body])
    }

    func testTable() throws {
        let md = """
        | Name | Qty | Note |
        |:-----|----:|:----:|
        | **Tea** | 2 | `loose` |
        | Milk | 1 |
        """
        let s = read(md)
        let p = paragraphs(s)
        XCTAssertEqual(p.map(\.text), ["Name", "Qty", "Note", "Tea", "2", "loose", "Milk", "1", "", ""])
        let block = try XCTUnwrap((p[0].attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.numberOfColumns, 3)
        XCTAssertNotNil(block.backgroundColor, "header row")
        for (i, para) in p.prefix(9).enumerated() {
            let cell = try XCTUnwrap((para.attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock)
            XCTAssertTrue(cell.table === block.table)
            XCTAssertEqual(cell.startingRow, i / 3)
            XCTAssertEqual(cell.startingColumn, i % 3)
        }
        XCTAssertEqual((p[4].attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment, .right)
        XCTAssertTrue(traits(s, "Tea").contains(.bold))
        XCTAssertEqual(attrs(s, of: "loose")[.font] as? NSFont, EditorStyle.inlineCodeFont)
        XCTAssertEqual(p.last?.kind, .body)
        XCTAssertTrue((p.last?.attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty ?? false, "line after the table")
    }

    func testImageThroughResolver() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("image-1.png")
        try Self.pngData().write(to: png)

        var asked: [String] = []
        let s = read("Look:\n\n![](Trip plan assets/image-1.png)\n\n![missing](nowhere.png) and ![[image-1.png]]") { ref in
            asked.append(ref)
            return ref.hasSuffix("image-1.png") ? png : nil
        }
        XCTAssertEqual(asked, ["Trip plan assets/image-1.png", "nowhere.png", "image-1.png"])
        var attachments: [NSTextAttachment] = []
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let a = value as? NSTextAttachment { attachments.append(a) }
        }
        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(attachments.first?.fileWrapper?.preferredFilename, "image-1.png")
        XCTAssertEqual(attachments.first?.fileWrapper?.regularFileContents, try Data(contentsOf: png))
        XCTAssertTrue(s.string.contains("missing and "))
    }

    func testBlankLinesAndLineBreaks() {
        XCTAssertEqual(read("One\n\nTwo").string, "One\nTwo\n")
        XCTAssertEqual(read("One\n\n\n\nTwo").string, "One\nTwo\n")
        XCTAssertEqual(read("One\nTwo").string, "One\u{2028}Two\n")
        XCTAssertEqual(read("One\\\nTwo  \nThree").string, "One\u{2028}Two\u{2028}Three\n")
        XCTAssertEqual(read("- Item\n  more\n- Next").string,
                       EditorStyle.markerText(.bullet, level: 0) + "Item\u{2028}more\n" + EditorStyle.markerText(.bullet, level: 0) + "Next\n")
        XCTAssertEqual(read("Cell<br>break").string, "Cell\u{2028}break\n")
    }

    func testWhatInterruptsAParagraph() {
        let p = paragraphs(read("Text\n# Heading\nText\n2024. was good\n1. item\n> quote"))
        XCTAssertEqual(p.map(\.kind), [.body, .title, .body, .body, .quote])
        XCTAssertEqual(p.map(\.text), ["Text", "Heading", "Text\u{2028}2024. was good", "1.\titem", "quote"])
    }

    func testSetextHeadings() {
        let p = paragraphs(read("Title\n===\n\nSection\n---\n\nText\n\n---"))
        XCTAssertEqual(p.map(\.kind), [.title, .heading, .body, .divider])
        XCTAssertEqual(p.map(\.text).prefix(3), ["Title", "Section", "Text"])
    }

    func testNestedEmphasis() {
        let s = read("**bold *both*** *italic* ***all** italic* x*y*z 2 * 3 snake_case_name")
        XCTAssertEqual(s.string, "bold both italic all italic xyz 2 * 3 snake_case_name\n")
        func style(_ substring: String) -> NSFontDescriptor.SymbolicTraits { traits(s, substring).intersection([.bold, .italic]) }
        XCTAssertEqual(style("bold"), .bold)
        XCTAssertEqual(style("both"), [.bold, .italic])
        XCTAssertEqual(style(" italic all"), [])
        XCTAssertEqual(style("italic all"), .italic)
        XCTAssertEqual(style("all"), [.bold, .italic])
        XCTAssertEqual(style(" italic x"), .italic)
        XCTAssertEqual(style("y"), .italic)
        XCTAssertEqual(style("case"), [])
    }

    // MARK: Obsidian

    func testWikilinksBecomePlainText() {
        let s = read("See [[Shopping list]], [[Recipes|my recipes]] and [[Garden#Roses]].")
        XCTAssertEqual(s.string, "See Shopping list, my recipes and Garden › Roses.\n")
        XCTAssertNil(attrs(s, of: "Shopping list")[.link])
    }

    // MARK: Front matter

    func testFrontMatter() throws {
        let md = """
        ---
        title: "Weekly review"
        tags: [work, "planning"]
        created: 2024-03-01T09:30:00Z
        updated: 2024-03-02
        aliases: ignored
        ---
        Body text #existing
        """
        let note = MarkdownReader.note(from: md, fallbackTitle: "file name")
        XCTAssertEqual(note.title, "Weekly review")
        XCTAssertEqual(note.frontMatter.tags, ["work", "planning"])
        XCTAssertEqual(note.frontMatter.created, ISO8601DateFormatter().date(from: "2024-03-01T09:30:00Z"))
        let updated = try XCTUnwrap(note.frontMatter.updated)
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: updated), DateComponents(year: 2024, month: 3, day: 2))
        let p = paragraphs(note.body)
        XCTAssertEqual(p.map(\.text), ["Weekly review", "Body text #existing", "#work #planning"])
        XCTAssertEqual(p.map(\.kind), [.title, .body, .body])
        XCTAssertEqual(Set(NoteStore.parseTags(note.body)), ["existing", "work", "planning"])
        XCTAssertFalse(note.body.string.contains("aliases"))
    }

    func testFrontMatterTagList() {
        let md = "---\ntags:\n  - home\n  - '#garden'\n---\n# Seeds\n"
        let note = MarkdownReader.note(from: md, fallbackTitle: "x")
        XCTAssertEqual(note.title, "Seeds")
        XCTAssertEqual(paragraphs(note.body).map(\.text), ["Seeds", "#home #garden"])
    }

    func testTitleFallsBackToFileName() {
        let note = MarkdownReader.note(from: "Just a line\n\n# Later heading", fallbackTitle: "Loose thoughts")
        XCTAssertEqual(note.title, "Loose thoughts")
        XCTAssertEqual(paragraphs(note.body).map(\.text), ["Loose thoughts", "Just a line", "Later heading"])
        XCTAssertEqual(paragraphs(note.body).first?.kind, .title)
    }

    func testTitleFromFirstHeadingIsNotDuplicated() {
        let note = MarkdownReader.note(from: "# Groceries\n- Eggs", fallbackTitle: "groceries-file")
        XCTAssertEqual(note.title, "Groceries")
        XCTAssertEqual(paragraphs(note.body).map(\.kind), [.title, .body])
    }

    func testFrontMatterTitleMatchingHeadingIsNotDuplicated() {
        let note = MarkdownReader.note(from: "---\ntitle: Groceries\n---\n# Groceries\nEggs", fallbackTitle: "x")
        XCTAssertEqual(paragraphs(note.body).map(\.text), ["Groceries", "Eggs"])
    }

    func testDates() {
        XCTAssertNotNil(MarkdownReader.date(from: "2024-05-06T07:08:09.123+02:00"))
        XCTAssertNotNil(MarkdownReader.date(from: "2024-05-06 07:08"))
        XCTAssertNil(MarkdownReader.date(from: "next tuesday"))
    }

    // MARK: Helpers

    static func pngData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
