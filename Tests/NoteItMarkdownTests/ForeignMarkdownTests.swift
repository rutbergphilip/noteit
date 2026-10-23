import NoteItDoc
import XCTest
@testable import NoteItMarkdown

final class ForeignMarkdownTests: XCTestCase {
    func testForeignFilesParse() throws {
        let fixtures = try MarkdownFixture.load("foreign")
        XCTAssertEqual(Set(fixtures.map(\.name)), ["bear", "crlf", "ia-writer", "obsidian", "tabs"])
        for fixture in fixtures {
            let parsed = try MarkdownCodec.parse(fixture.markdown, resolveNoteLink: MarkdownFixture.resolveNoteLink)
            XCTAssertEqual(parsed.body, fixture.body, fixture.name)
        }
    }

    func testObsidianFrontMatterKeepsUnknownKeysAndReadsTags() throws {
        let fixture = try XCTUnwrap(MarkdownFixture.load("foreign").first { $0.name == "obsidian" })
        let parsed = try MarkdownCodec.parse(fixture.markdown)
        XCTAssertEqual(parsed.frontMatter.tags, ["work"])
        XCTAssertNil(parsed.frontMatter.id)
        XCTAssertEqual(parsed.attachmentRefs, [AttachmentRef(path: "diagram.png", displayName: "diagram.png")])
    }

    func testByteOrderMarkIsIgnored() throws {
        XCTAssertEqual(try MarkdownCodec.parse("\u{FEFF}# Title\n").body.doc, .doc([.heading(level: 1, align: nil, indent: nil, content: [.text("Title", marks: [])])]))
    }

    func testOtherHTMLAndUnsafeLinksStayText() throws {
        let parsed = try MarkdownCodec.parse("<div>x</div> [run](javascript:alert(1))\n")
        XCTAssertEqual(parsed.body.doc, .doc([.paragraph(align: nil, indent: nil, content: [.text("<div>x</div> run", marks: [])])]))
    }
}
