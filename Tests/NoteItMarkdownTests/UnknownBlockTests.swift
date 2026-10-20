import NoteItDoc
import XCTest
@testable import NoteItMarkdown

final class UnknownBlockTests: XCTestCase {
    private let unknown = DocNode.unknown(type: "mermaid", json: Data(#"{"attrs":{"src":"graph TD"},"type":"mermaid"}"#.utf8))

    private func body(_ blocks: [DocNode]) -> BodyContainer {
        BodyContainer(doc: .doc(blocks))
    }

    private func serialize(_ body: BodyContainer, _ profile: MarkdownProfile) -> String {
        MarkdownCodec.serialize(body, frontMatter: .empty, profile: profile, attachmentPath: { $0 },
                                noteLinkName: { _ in nil }, previous: nil)
    }

    private var paragraph: DocNode { .paragraph(align: nil, indent: nil, content: [.text("after", marks: [])]) }

    func testLibraryKeepsUnknownBlockAsComment() throws {
        let doc = [paragraph, unknown, paragraph]
        let markdown = serialize(body(doc), .library)
        XCTAssertTrue(markdown.contains(BlockAttributes.prefix + " doc="), markdown)
        let parsed = try MarkdownCodec.parse(markdown)
        XCTAssertEqual(parsed.body.doc, .doc(doc))
        XCTAssertEqual(serialize(parsed.body, .library), markdown)
    }

    func testUnknownBlockAloneRoundTrips() throws {
        let parsed = try MarkdownCodec.parse(serialize(body([unknown]), .library))
        XCTAssertEqual(parsed.body.doc, .doc([unknown]))
    }

    func testPortableDropsUnknownBlock() throws {
        let markdown = serialize(body([paragraph, unknown]), .portable)
        XCTAssertFalse(markdown.contains("<!--"), markdown)
        XCTAssertEqual(try MarkdownCodec.parse(markdown).body.doc, .doc([paragraph]))
    }
}
