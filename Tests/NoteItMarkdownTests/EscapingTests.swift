import NoteItDoc
import XCTest
@testable import NoteItMarkdown

final class EscapingTests: XCTestCase {
    @discardableResult
    private func assertRoundTrip(_ blocks: [DocNode], file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let markdown = MarkdownCodec.serialize(BodyContainer(doc: .doc(blocks), attachments: [:]), frontMatter: .empty,
                                               profile: .library, attachmentPath: { $0 }, previous: nil)
        XCTAssertEqual(try MarkdownCodec.parse(markdown).body.doc, .doc(blocks), markdown, file: file, line: line)
        XCTAssertFalse(markdown.contains("doc="), markdown, file: file, line: line)
        return markdown
    }

    private func paragraph(_ text: String) -> DocNode {
        .paragraph(align: nil, indent: nil, content: [.text(text, marks: [])])
    }

    func testMarkdownSyntaxInTextStaysText() throws {
        let texts = ["*not italic*", "_not italic_", "snake_case_name", "**not bold**", "==not highlighted==", "a = b == c",
                     "~~not struck~~", "`not code`", "<u>not underlined</u>", "<mark>x</mark> <br>", "&amp; &#10; & done",
                     "back\\slash\\", "\\*", "[[not a link]]", "[text](https://example.com)", "![alt](x.png)", "a]b[c",
                     "<!-- noteit: align=center -->", "https://example.com and www.example.com", "<https://example.com>",
                     "end!", "1 * 2 * 3", "50% off (today)"]
        for text in texts { try assertRoundTrip([paragraph(text)]) }
    }

    func testLineStartsThatWouldStartABlock() throws {
        let texts = ["# not a heading", "#hashtag", "- not a list", "+ not a list", "1. not a list", "12) not a list",
                     "> not a quote", "---", "***", "___", "===", "```", "~~~", "    four spaces", "\ttab", "trailing  "]
        for text in texts { try assertRoundTrip([paragraph(text)]) }
        XCTAssertEqual(try assertRoundTrip([paragraph("# x")]), "\\# x\n")
        XCTAssertEqual(try assertRoundTrip([paragraph("1. x")]), "1\\. x\n")
        try assertRoundTrip([.paragraph(align: nil, indent: nil, content: [.text("a", marks: []), .hardBreak, .text("# b", marks: []),
                                                                           .hardBreak, .text("2. c", marks: []), .hardBreak])])
        try assertRoundTrip([.listItem(kind: .bullet, level: 0, number: nil, checked: nil, align: nil, content: [.text("1. x", marks: [])])])
        try assertRoundTrip([.heading(level: 2, align: nil, indent: nil, content: [.text("Ends in ##", marks: [])])])
    }

    func testPipesAndBackslashesInTableCells() throws {
        let cell = { (text: String, header: Bool) in
            TableCell(header: header, content: [.paragraph(align: nil, indent: nil, content: [.text(text, marks: [])])])
        }
        let markdown = try assertRoundTrip([.table(columnWidths: nil, rows: [[cell("a|b", true), cell("c\\", true)],
                                                                             [cell("\\|", false), cell("`|`", false)]])])
        XCTAssertTrue(markdown.hasPrefix("| a\\|b |"), markdown)
        try assertRoundTrip([.table(columnWidths: nil, rows: [[TableCell(header: false, content: [
            .paragraph(align: nil, indent: nil, content: [.text("x|y", marks: [.code])]),
        ])]])])
    }

    func testMarkedTextNextToPunctuation() throws {
        try assertRoundTrip([.paragraph(align: nil, indent: nil, content: [
            .text("(", marks: []), .text("bold", marks: [.bold]), .text(")x ", marks: []), .text(" spaced ", marks: [.italic]),
            .text("*", marks: [.bold]), .text("_", marks: [.italic]), .text("=", marks: [.highlight(MarkdownStyle.yellowHighlight)]),
        ])])
    }

    func testCanonicalDelimitersWhenTheyReadBack() throws {
        let markdown = try assertRoundTrip([.paragraph(align: nil, indent: nil, content: [
            .text("bold", marks: [.bold]), .text(" and ", marks: []), .text("both", marks: [.bold, .italic]),
        ])])
        XCTAssertEqual(markdown, "**bold** and ***both***\n")
    }
}
