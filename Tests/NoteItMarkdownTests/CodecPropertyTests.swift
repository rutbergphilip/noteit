import NoteItDoc
import NoteItDocTestSupport
import XCTest
@testable import NoteItMarkdown

final class CodecPropertyTests: XCTestCase {
    static func path(_ sha: String) -> String {
        "_attachments/" + sha.prefix(12) + "-file"
    }

    /// The doc as `parse` gives it back: attachments by path.
    static func readable(_ body: BodyContainer, profile: MarkdownProfile = .library) -> DocNode {
        MarkdownWriter.readable(body.doc, attachmentPath: path, profile: profile)
    }

    static func serialize(_ body: BodyContainer, _ profile: MarkdownProfile) -> String {
        MarkdownCodec.serialize(body, frontMatter: .empty, profile: profile, attachmentPath: path,
                                noteLinkName: { $0.uuidString }, previous: nil)
    }

    static func parse(_ markdown: String) throws -> ParsedMarkdown {
        try MarkdownCodec.parse(markdown, resolveNoteLink: { UUID(uuidString: $0) })
    }

    func testRandomDocumentsRoundTrip() throws {
        var failures = 0
        var portableChecked = 0
        for seed in UInt64(0)..<2000 {
            var generator = RandomDocGenerator(seed: seed)
            let body = generator.next()
            let markdown = Self.serialize(body, .library)
            let parsed = try Self.parse(markdown)
            if parsed.body.doc != Self.readable(body) || parsed.body.frontMatter != body.frontMatter {
                XCTFail("library flavour, seed \(seed)")
                failures += 1
            }
            if !markdown.contains(BlockAttributes.prefix), !markdown.contains("data-size") {
                let portable = try Self.parse(Self.serialize(body, .portable))
                if portable.body.doc != Self.readable(body, profile: .portable) {
                    XCTFail("portable flavour, seed \(seed)")
                    failures += 1
                }
                portableChecked += 1
            }
            if failures >= 10 { break }
        }
        XCTAssertGreaterThan(portableChecked, 20)
    }

    func testPortableFlavourHasNoNoteItSyntax() {
        for seed in UInt64(0)..<200 {
            var generator = RandomDocGenerator(seed: seed)
            let markdown = Self.serialize(generator.next(), .portable)
            XCTAssertFalse(markdown.contains("<!--"), "seed \(seed)")
            XCTAssertFalse(markdown.contains("data-size"), "seed \(seed)")
        }
    }

    func testSerializeIsStable() throws {
        for seed in UInt64(0)..<300 {
            var generator = RandomDocGenerator(seed: seed)
            let markdown = Self.serialize(generator.next(), .library)
            let parsed = try Self.parse(markdown)
            let again = MarkdownCodec.serialize(parsed.body, frontMatter: parsed.frontMatter, profile: .library, attachmentPath: { $0 },
                                                noteLinkName: { $0.uuidString }, previous: nil)
            XCTAssertEqual(again, markdown, "seed \(seed)")
        }
    }
}
