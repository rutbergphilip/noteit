import NoteItDoc
import XCTest
@testable import NoteItMarkdown

final class SourcePreservationTests: XCTestCase {
    private let foreign = "Trip notes\n==========\n\nA __bold__ word.\n\n+ first\n+ second\n\nLast line.\n"

    private func blocks(_ parsed: ParsedMarkdown) -> [DocNode] {
        guard case .doc(let blocks) = parsed.body.doc else { return [] }
        return blocks
    }

    private func rewrite(_ parsed: ParsedMarkdown, _ blocks: [DocNode]) throws -> String {
        var body = parsed.body
        body.doc = .doc(blocks)
        let markdown = MarkdownCodec.serialize(body, frontMatter: parsed.frontMatter, profile: .library, attachmentPath: { $0 },
                                               noteLinkName: MarkdownFixture.noteLinkName, previous: parsed)
        XCTAssertEqual(try MarkdownCodec.parse(markdown, resolveNoteLink: MarkdownFixture.resolveNoteLink).body.doc, .doc(blocks))
        return markdown
    }

    func testUnchangedBlocksKeepTheirBytes() throws {
        let parsed = try MarkdownCodec.parse(foreign)
        var changed = blocks(parsed)
        changed[4] = .paragraph(align: nil, indent: nil, content: [.text("Changed ", marks: []), .text("line", marks: [.bold])])
        XCTAssertEqual(try rewrite(parsed, changed),
                       "Trip notes\n==========\n\nA __bold__ word.\n\n+ first\n+ second\n\nChanged **line**\n")
    }

    func testChangedBlocksAreCanonical() throws {
        let parsed = try MarkdownCodec.parse(foreign)
        var changed = blocks(parsed)
        changed[1] = .paragraph(align: nil, indent: nil, content: [.text("A ", marks: []), .text("bold", marks: [.bold]),
                                                                   .text(" word!", marks: [])])
        changed[0] = .heading(level: 1, align: nil, indent: nil, content: [.text("Trip", marks: [])])
        XCTAssertEqual(try rewrite(parsed, changed), "# Trip\n\nA **bold** word!\n\n+ first\n+ second\n\nLast line.\n")
    }

    func testFrontMatterExtraIsKept() throws {
        let parsed = try MarkdownCodec.parse("---\naliases:\n  - Weekly\ncssclass: wide\n---\nText\n")
        let markdown = try rewrite(parsed, [.paragraph(align: nil, indent: nil, content: [.text("New", marks: [])])])
        XCTAssertEqual(markdown, "---\naliases:\n  - Weekly\ncssclass: wide\n---\n\nNew\n")
    }

    func testForeignFilesKeepEveryBlock() throws {
        for fixture in try MarkdownFixture.load("foreign") {
            let parsed = try MarkdownCodec.parse(fixture.markdown, resolveNoteLink: MarkdownFixture.resolveNoteLink)
            let markdown = try rewrite(parsed, blocks(parsed))
            for unit in SourcePreservation.units(of: parsed) {
                XCTAssertTrue(markdown.contains(unit.text), "\(fixture.name): \(unit.text)")
            }
            XCTAssertFalse(markdown.contains("\r"), fixture.name)
        }
    }
}
