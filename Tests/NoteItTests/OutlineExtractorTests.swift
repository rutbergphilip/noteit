import AppKit
import XCTest
@testable import NoteIt

final class OutlineExtractorTests: XCTestCase {
    private func paragraph(_ text: String, _ kind: BlockKind) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: EditorStyle.attributes(for: kind))
    }

    func testOutlineLevels() {
        let text = NSMutableAttributedString()
        text.append(paragraph("Trip", .title))
        text.append(paragraph("Some body", .body))
        text.append(paragraph("Budget", .heading))
        text.append(paragraph("Flights", .subheading))
        let items = OutlineExtractor.items(in: text)
        XCTAssertEqual(items.map(\.level), [0, 1, 2])
        XCTAssertEqual(items.map(\.text), ["Trip", "Budget", "Flights"])
        XCTAssertEqual(items[1].range, NSRange(location: 15, length: 6))
    }

    func testOutlineSkipsTablesAndEmpty() {
        let text = NSMutableAttributedString()
        text.append(paragraph("", .heading))
        text.append(paragraph("Real", .heading))
        let table = NSTextTable()
        table.numberOfColumns = 1
        let style = (EditorStyle.attributes(for: .heading)[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        style.textBlocks = [NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)]
        text.append(NSAttributedString(string: "Cell\n", attributes: [.font: EditorStyle.headingFont, .paragraphStyle: style]))
        XCTAssertEqual(OutlineExtractor.items(in: text).map(\.text), ["Real"])
    }

    func testSectionRange() {
        let text = NSMutableAttributedString()
        text.append(paragraph("A", .heading))
        text.append(paragraph("a1", .subheading))
        text.append(paragraph("body", .body))
        text.append(paragraph("B", .heading))
        text.append(paragraph("tail", .body))
        let items = OutlineExtractor.items(in: text)
        XCTAssertEqual(OutlineExtractor.section(of: items[0], in: items, length: text.length), NSRange(location: 0, length: 10))
        XCTAssertEqual(OutlineExtractor.section(of: items[1], in: items, length: text.length), NSRange(location: 2, length: 8))
        XCTAssertEqual(OutlineExtractor.section(of: items[2], in: items, length: text.length),
                       NSRange(location: 10, length: text.length - 10))
    }
}
