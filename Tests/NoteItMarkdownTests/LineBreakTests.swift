import NoteItDoc
import XCTest
@testable import NoteItMarkdown

final class LineBreakTests: XCTestCase {
    private func content(_ markdown: String) throws -> [Inline] {
        guard case .doc(let blocks) = try MarkdownCodec.parse(markdown).body.doc, let first = blocks.first else { return [] }
        switch first {
        case .paragraph(_, _, let content), .listItem(_, _, _, _, _, let content), .heading(_, _, _, let content): return content
        default: return []
        }
    }

    private func write(_ blocks: [DocNode], previous: ParsedMarkdown? = nil) -> String {
        MarkdownCodec.serialize(BodyContainer(doc: .doc(blocks)), frontMatter: previous?.frontMatter ?? .empty, profile: .library,
                                attachmentPath: { $0 }, previous: previous)
    }

    func testHardWrappedParagraphEditAddsNoBackslashes() throws {
        let source = "Intro.\n\nOne two three\nfour five six\nseven eight\n"
        let parsed = try MarkdownCodec.parse(source)
        guard case .doc(var blocks) = parsed.body.doc, case .paragraph(let align, let indent, var content) = blocks[1] else {
            return XCTFail("\(parsed.body.doc)")
        }
        XCTAssertEqual(content, [.text("One two three", marks: []), .softBreak, .text("four five six", marks: []), .softBreak,
                                 .text("seven eight", marks: [])])
        content[0] = .text("One 2 three", marks: [])
        blocks[1] = .paragraph(align: align, indent: indent, content: content)
        XCTAssertEqual(write(blocks, previous: parsed), "Intro.\n\nOne 2 three\nfour five six\nseven eight\n")
        XCTAssertEqual(write(blocks), "Intro.\n\nOne 2 three\nfour five six\nseven eight\n")
    }

    func testBackslashAndTwoSpacesStayHard() throws {
        XCTAssertEqual(try content("a  \nb\\\nc\nd\n"), [.text("a", marks: []), .hardBreak, .text("b", marks: []), .hardBreak,
                                                       .text("c", marks: []), .softBreak, .text("d", marks: [])])
        XCTAssertEqual(try content("- a  \n  b\n  c\n"), [.text("a", marks: []), .hardBreak, .text("b", marks: []), .softBreak,
                                                         .text("c", marks: [])])
        let typed: [Inline] = [.text("a", marks: []), .hardBreak, .text("b", marks: []), .softBreak, .text("c", marks: [])]
        XCTAssertEqual(write([.paragraph(align: nil, indent: nil, content: typed)]), "a\\\nb\nc\n")
    }

    func testSoftBreaksWithoutAPlainNewlineFormBecomeHard() throws {
        let soft: [Inline] = [.softBreak, .text("a", marks: []), .softBreak, .softBreak, .text("b", marks: []), .softBreak]
        XCTAssertEqual(write([.paragraph(align: nil, indent: nil, content: soft)]), "\\\na\\\n\\\nb\\\n")
        XCTAssertEqual(write([.heading(level: 1, align: nil, indent: nil, content: soft)]), "# <br>a<br><br>b<br>\n")
        XCTAssertEqual(try content("a\nb\n===\n"), [.text("a", marks: []), .hardBreak, .text("b", marks: [])])
    }

    func testSoftBreakJSONReadsAsAHardBreakAttribute() throws {
        let data = try JSONEncoder().encode(Inline.softBreak)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "hardBreak")
        XCTAssertEqual((object["attrs"] as? [String: Any])?["soft"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(Inline.self, from: data), .softBreak)
    }
}
