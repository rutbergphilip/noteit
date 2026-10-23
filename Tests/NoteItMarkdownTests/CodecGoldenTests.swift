import NoteItDoc
import NoteItDocTestSupport
import XCTest
@testable import NoteItMarkdown

final class CodecGoldenTests: XCTestCase {
    func testParse() throws {
        let fixtures = try MarkdownFixture.load()
        XCTAssertGreaterThan(fixtures.count, 30)
        for fixture in fixtures {
            let parsed = try MarkdownCodec.parse(fixture.markdown, resolveNoteLink: MarkdownFixture.resolveNoteLink)
            XCTAssertEqual(parsed.body, fixture.body, fixture.name)
        }
    }

    func testSerialize() throws {
        let fixtures = try MarkdownFixture.load().filter(\.isCanonical)
        XCTAssertGreaterThan(fixtures.count, 30)
        for fixture in fixtures {
            let frontMatter = try MarkdownCodec.parse(fixture.markdown).frontMatter
            let markdown = MarkdownCodec.serialize(fixture.body, frontMatter: frontMatter, profile: .library, attachmentPath: { $0 },
                                                   noteLinkName: MarkdownFixture.noteLinkName, previous: nil)
            XCTAssertEqual(markdown, fixture.markdown, fixture.name)
        }
    }

    func testParseKeepsASourceRangePerBlock() throws {
        let markdown = "# Title\n\n```swift\na\nb\n```\n\n\n<!-- noteit: align=center -->\nText\n"
        let parsed = try MarkdownCodec.parse(markdown)
        guard case .doc(let blocks) = parsed.body.doc else { return XCTFail("not a doc") }
        XCTAssertEqual(blocks.count, parsed.sourceMap.blocks.count)
        XCTAssertEqual(parsed.sourceMap.blocks.map { String(markdown[$0]) },
                       ["# Title", "```swift\na\nb\n```", "```swift\na\nb\n```", "", "<!-- noteit: align=center -->\nText"])
    }

    func testAttachmentRefsAreInDocumentOrderWithoutDuplicates() throws {
        let markdown = "![b.png|300](_attachments/b.png) [a.pdf](_attachments/a%20b.pdf)\n\n![b.png|300](_attachments/b.png)\n"
        let parsed = try MarkdownCodec.parse(markdown)
        XCTAssertEqual(parsed.attachmentRefs, [AttachmentRef(path: "_attachments/b.png", displayName: "b.png", width: 300),
                                               AttachmentRef(path: "_attachments/a b.pdf", displayName: "a.pdf")])
    }

    /// The code-block cases of the `NoteItDoc` golden fixtures read back from their fenced form.
    func testGoldenCodeBlockCasesParse() throws {
        struct Case: Codable {
            var name: String
            var container: JSONValue
        }
        let file = try GoldenFixtures.load("doc-validate", as: GoldenFile<Case>.self)
        var checked = 0
        for golden in file.cases {
            let data = try JSONEncoder().encode(golden.container)
            guard let body = try? BodyContainer.decode(data), case .doc(let blocks) = body.doc else { continue }
            for case .codeBlock(_, let language, let content) in blocks {
                let text = content.compactMap { if case .text(let text, _) = $0 { text } else { nil } }.joined()
                guard content.allSatisfy({ if case .text(_, let marks) = $0 { marks.isEmpty } else { false } }) else { continue }
                let markdown = "```" + (language ?? "") + "\n" + text + "\n```\n"
                let parsed = try MarkdownCodec.parse(markdown)
                XCTAssertEqual(parsed.body.doc, .doc([.codeBlock(align: nil, language: language,
                                                                  content: text.isEmpty ? [] : [.text(text, marks: [])])]), golden.name)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
