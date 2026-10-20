import NoteItDoc
import XCTest

final class DocSchemaTests: XCTestCase {
    private func roundTrip(_ nodeJSON: String, file: StaticString = #filePath, line: UInt = #line) throws -> DocNode {
        let body = #"{"attachments":{},"doc":{"content":["# + nodeJSON + #"],"type":"doc"},"format":"noteit-doc","version":1}"#
        let container = try BodyContainer.decode(Data(body.utf8))
        XCTAssertEqual(String(decoding: try container.encoded(), as: UTF8.self), body, file: file, line: line)
        guard case .doc(let nodes) = container.doc, let node = nodes.first else {
            XCTFail("no node", file: file, line: line)
            return .horizontalRule
        }
        return node
    }

    func testEveryBlockRoundTrips() throws {
        XCTAssertEqual(try roundTrip(#"{"type":"paragraph"}"#), .paragraph(align: nil, indent: nil, content: []))
        XCTAssertEqual(try roundTrip(#"{"attrs":{"align":"center","indent":2},"content":[{"text":"Hi","type":"text"}],"type":"paragraph"}"#),
                       .paragraph(align: .center, indent: 2, content: [.text("Hi", marks: [])]))
        XCTAssertEqual(try roundTrip(#"{"attrs":{"level":2},"content":[{"text":"H","type":"text"}],"type":"heading"}"#),
                       .heading(level: 2, align: nil, indent: nil, content: [.text("H", marks: [])]))
        XCTAssertEqual(try roundTrip(#"{"attrs":{"align":"right","level":1},"type":"heading"}"#),
                       .heading(level: 1, align: .right, indent: nil, content: []))
        XCTAssertEqual(try roundTrip(#"{"type":"horizontalRule"}"#), .horizontalRule)
        XCTAssertEqual(try roundTrip(#"{"attrs":{"indent":1},"content":[{"type":"paragraph"}],"type":"blockquote"}"#),
                       .blockquote(indent: 1, content: [.paragraph(align: nil, indent: nil, content: [])]))
        XCTAssertEqual(try roundTrip(#"{"attrs":{"checked":true,"kind":"task","level":0},"content":[{"text":"Do","type":"text"}],"type":"listItem"}"#),
                       .listItem(kind: .task, level: 0, number: nil, checked: true, align: nil, content: [.text("Do", marks: [])]))
        XCTAssertEqual(try roundTrip(#"{"attrs":{"align":"justify","kind":"ordered","level":3,"number":7},"type":"listItem"}"#),
                       .listItem(kind: .ordered, level: 3, number: 7, checked: nil, align: .justify, content: []))
        XCTAssertEqual(try roundTrip(#"{"attrs":{"kind":"bullet","level":0},"type":"listItem"}"#),
                       .listItem(kind: .bullet, level: 0, number: nil, checked: nil, align: nil, content: []))
        let table = #"{"attrs":{"columnWidths":[40,60.5]},"content":[{"content":[{"content":[{"type":"paragraph"}],"type":"tableHeader"},"#
            + #"{"content":[],"type":"tableCell"}],"type":"tableRow"}],"type":"table"}"#
        XCTAssertEqual(try roundTrip(table), .table(columnWidths: [40, 60.5], rows: [[
            TableCell(header: true, content: [.paragraph(align: nil, indent: nil, content: [])]),
            TableCell(header: false, content: []),
        ]]))
        XCTAssertEqual(try roundTrip(#"{"content":[],"type":"table"}"#), .table(columnWidths: nil, rows: []))
    }

    func testCodeBlockLanguageRoundTrips() throws {
        XCTAssertEqual(try roundTrip(#"{"attrs":{"language":"swift"},"content":[{"text":"let x = 1","type":"text"}],"type":"codeBlock"}"#),
                       .codeBlock(align: nil, language: "swift", content: [.text("let x = 1", marks: [])]))
        XCTAssertEqual(try roundTrip(#"{"attrs":{"language":"not-a-known-language"},"type":"codeBlock"}"#),
                       .codeBlock(align: nil, language: "not-a-known-language", content: []))
        XCTAssertEqual(try roundTrip(#"{"type":"codeBlock"}"#), .codeBlock(align: nil, language: nil, content: []))
    }

    func testEveryInlineAndMarkRoundTrips() throws {
        let marks = #"[{"type":"bold"},{"type":"italic"},{"type":"underline"},{"type":"strike"},{"type":"code"},"#
            + ##"{"attrs":{"href":"https://example.com/a/b"},"type":"link"},{"attrs":{"color":"#FF0000"},"type":"textColor"},"##
            + ##"{"attrs":{"color":"#00ff00"},"type":"highlight"},{"attrs":{"delta":-2},"type":"fontSize"}]"##
        let content = #"[{"marks":"# + marks + #","text":"x","type":"text"},{"type":"hardBreak"},"#
            + #"{"attrs":{"mime":"image/png","name":"a.png","sha":"ab","width":120.5},"type":"image"},"#
            + #"{"attrs":{"mime":"image/png","name":"b.png","sha":"cd"},"type":"image"},"#
            + #"{"attrs":{"mime":"application/pdf","name":"c.pdf","sha":"ef"},"type":"attachment"}]"#
        XCTAssertEqual(try roundTrip(#"{"content":"# + content + #","type":"paragraph"}"#), .paragraph(align: nil, indent: nil, content: [
            .text("x", marks: [.bold, .italic, .underline, .strike, .code, .link(href: "https://example.com/a/b"),
                               .textColor("#FF0000"), .highlight("#00ff00"), .fontSize(delta: -2)]),
            .hardBreak,
            .image(sha: "ab", name: "a.png", mime: "image/png", width: 120.5),
            .image(sha: "cd", name: "b.png", mime: "image/png", width: nil),
            .attachment(sha: "ef", name: "c.pdf", mime: "application/pdf"),
        ]))
    }

    func testUnknownNodeKeepsItsBytes() throws {
        let node = #"{"attrs":{"big":9007199254740993,"x":1.50},"content":[{"type":"paragraph"}],"type":"callout"}"#
        guard case .unknown(let type, let json) = try roundTrip(node) else { return XCTFail("expected unknown") }
        XCTAssertEqual(type, "callout")
        XCTAssertEqual(String(decoding: json, as: UTF8.self), node)
    }

    func testUnknownInlineOrMarkKeepsTheBlockAsUnknown() throws {
        let inline = #"{"content":[{"text":"a","type":"text"},{"type":"mention"}],"type":"paragraph"}"#
        guard case .unknown(let type, _) = try roundTrip(inline) else { return XCTFail("expected unknown") }
        XCTAssertEqual(type, "paragraph")
        let mark = #"{"attrs":{"level":1},"content":[{"marks":[{"type":"sparkle"}],"text":"a","type":"text"}],"type":"heading"}"#
        guard case .unknown = try roundTrip(mark) else { return XCTFail("expected unknown") }
    }

    func testNonFiniteWidthsFailToDecode() {
        let image = #"{"content":[{"attrs":{"mime":"image/png","name":"a.png","sha":"ab","width":WIDTH},"type":"image"}],"type":"paragraph"}"#
        let table = #"{"attrs":{"columnWidths":[50,WIDTH]},"content":[],"type":"table"}"#
        for node in [image, table] {
            for width in ["1e999", "-1e999"] {
                let body = #"{"attachments":{},"doc":{"content":["# + node.replacingOccurrences(of: "WIDTH", with: width)
                    + #"],"type":"doc"},"format":"noteit-doc","version":1}"#
                XCTAssertThrowsError(try BodyContainer.decode(Data(body.utf8)), "\(width) in \(node)")
            }
        }
    }

    func testCodableMatchesTheCodec() throws {
        let node = DocNode.listItem(kind: .task, level: 1, number: nil, checked: false, align: nil,
                                    content: [.text("a", marks: [.link(href: "https://x.y")])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(node)
        XCTAssertEqual(try JSONDecoder().decode(DocNode.self, from: data), node)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"attrs":{"checked":false,"kind":"task","level":1},"content":[{"marks":[{"attrs":{"href":"https://x.y"},"type":"link"}],"text":"a","type":"text"}],"type":"listItem"}"#)
    }

    func testCodeLanguageRawValuesAreUnchanged() {
        let expected: [CodeLanguage] = [.plain, .bash, .c, .cpp, .csharp, .css, .go, .html, .java, .javascript, .json,
                                        .kotlin, .markdown, .php, .python, .ruby, .rust, .sql, .swift, .typescript, .yaml]
        for (offset, language) in expected.enumerated() { XCTAssertEqual(CodeLanguage(rawValue: offset + 1), language) }
        XCTAssertNil(CodeLanguage(rawValue: 0))
        XCTAssertNil(CodeLanguage(rawValue: 22))
    }
}
