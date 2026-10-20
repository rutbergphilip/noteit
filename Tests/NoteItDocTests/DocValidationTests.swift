import CryptoKit
import NoteItDoc
import XCTest

final class DocValidationTests: XCTestCase {
    private func container(_ blocks: [DocNode]) -> BodyContainer {
        BodyContainer(doc: .doc(blocks))
    }

    private func paragraph(marks: [Mark]) -> DocNode {
        .paragraph(align: nil, indent: nil, content: [.text("x", marks: marks)])
    }

    private func isReadOnly(_ c: BodyContainer) -> Bool {
        if case .readOnly = DocValidation.validate(c) { return true }
        return false
    }

    func testAPlainDocumentIsValid() {
        XCTAssertEqual(DocValidation.validate(container([
            .heading(level: 1, align: nil, indent: nil, content: [.text("T", marks: [.italic])]),
            paragraph(marks: [.bold, .textColor("#a0B1c2"), .highlight("#FFFFFF"), .fontSize(delta: 4)]),
            .listItem(kind: .ordered, level: 8, number: 3, checked: nil, align: nil, content: []),
            .blockquote(indent: 1, content: [paragraph(marks: [])]),
            .table(columnWidths: nil, rows: [[TableCell(header: true, content: [paragraph(marks: [])])]]),
            .codeBlock(align: nil, language: "brainfudge", content: []),
            .horizontalRule,
        ])), .valid)
    }

    func testUnknownNodeIsReadOnly() {
        XCTAssertTrue(isReadOnly(container([.unknown(type: "callout", json: Data(#"{"type":"callout"}"#.utf8))])))
        XCTAssertTrue(isReadOnly(container([.blockquote(indent: nil, content: [.unknown(type: "x", json: Data(#"{"type":"x"}"#.utf8))])])))
    }

    func testFormatAndVersion() {
        var c = container([])
        c.format = "other"
        XCTAssertTrue(isReadOnly(c))
        c = container([])
        c.version = 2
        XCTAssertTrue(isReadOnly(c))
    }

    func testColourRegex() {
        for good in ["#000000", "#abcdef", "#ABCDEF", "#09aF3c"] {
            XCTAssertEqual(DocValidation.validate(container([paragraph(marks: [.textColor(good)])])), .valid, good)
        }
        for bad in ["#00000", "#0000000", "000000", "#GGGGGG", "#00000g", "red", "#00 000", "＃000000", "#٠٠٠٠٠٠"] {
            XCTAssertTrue(isReadOnly(container([paragraph(marks: [.highlight(bad)])])), bad)
        }
    }

    func testLevelBounds() {
        for level in [1, 2, 3] {
            XCTAssertEqual(DocValidation.validate(container([.heading(level: level, align: nil, indent: nil, content: [])])), .valid)
        }
        for level in [0, 4] {
            XCTAssertTrue(isReadOnly(container([.heading(level: level, align: nil, indent: nil, content: [])])))
        }
        for level in [0, 8] {
            XCTAssertEqual(DocValidation.validate(container([.listItem(kind: .bullet, level: level, number: nil, checked: nil, align: nil, content: [])])), .valid)
        }
        for level in [-1, 9] {
            XCTAssertTrue(isReadOnly(container([.listItem(kind: .task, level: level, number: nil, checked: false, align: nil, content: [])])))
        }
    }

    func testFontSizeDelta() {
        XCTAssertEqual(DocValidation.validate(container([paragraph(marks: [.fontSize(delta: 88)])])), .valid)
        XCTAssertEqual(DocValidation.validate(container([paragraph(marks: [.fontSize(delta: -88)])])), .valid)
        XCTAssertTrue(isReadOnly(container([paragraph(marks: [.fontSize(delta: 89)])])))
        XCTAssertTrue(isReadOnly(container([paragraph(marks: [.fontSize(delta: -89)])])))
    }

    func testAttachmentKeyMustBeItsHash() {
        let data = Data("pdf".utf8)
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let good = BodyContainer(doc: .doc([]), attachments: [key: Attachment(mime: "application/pdf", name: "a.pdf", data: data)])
        XCTAssertEqual(DocValidation.validate(good), .valid)
        let upper = BodyContainer(doc: .doc([]), attachments: [key.uppercased(): Attachment(mime: "application/pdf", name: "a.pdf", data: data)])
        XCTAssertTrue(isReadOnly(upper))
        let wrong = BodyContainer(doc: .doc([]), attachments: [key: Attachment(mime: "application/pdf", name: "a.pdf", data: Data("x".utf8))])
        XCTAssertTrue(isReadOnly(wrong))
    }

    func testLinks() {
        let id = UUID().uuidString
        for href in ["https://example.com", "http://a.b/c?d=e", "mailto:a@b.c", "tel:+4612345", "HTTPS://EXAMPLE.COM",
                     "noteit://note/\(id)", "noteit://note/\(id)?heading=Intro", "noteit://note?title=Plan"] {
            XCTAssertEqual(DocValidation.validate(container([paragraph(marks: [.link(href: href)])])), .valid, href)
        }
        for href in ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "noteit://settings", "noteit:note", "", "no scheme"] {
            XCTAssertTrue(isReadOnly(container([paragraph(marks: [.link(href: href)])])), href)
        }
        XCTAssertEqual(LinkPolicy.schemes, ["http", "https", "mailto", "tel", "noteit"])
    }
}
