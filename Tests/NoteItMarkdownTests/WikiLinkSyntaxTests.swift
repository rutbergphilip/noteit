import NoteItDoc
import XCTest
@testable import NoteItMarkdown

final class WikiLinkSyntaxTests: XCTestCase {
    private let planHref = "noteit://note/" + MarkdownFixture.planID.uuidString

    private func serialize(_ blocks: [DocNode], profile: MarkdownProfile = .library,
                           noteLinkName: @escaping (UUID) -> String? = MarkdownFixture.noteLinkName) -> String {
        MarkdownCodec.serialize(BodyContainer(doc: .doc(blocks), attachments: [:]), frontMatter: .empty, profile: profile,
                                attachmentPath: { $0 }, noteLinkName: noteLinkName, previous: nil)
    }

    private func linked(_ text: String, _ href: String) -> DocNode {
        .paragraph(align: nil, indent: nil, content: [.text("See ", marks: []), .text(text, marks: [.link(href: href)])])
    }

    func testNoteLinksAreRawWikiLinks() throws {
        XCTAssertEqual(serialize([linked("Plan", planHref)]), "See [[Plan]]\n")
        let markdown = serialize([linked("the *best* plan_now", planHref)])
        XCTAssertEqual(markdown, "See [[Plan|the *best* plan_now]]\n")
        let parsed = try MarkdownCodec.parse(markdown, resolveNoteLink: MarkdownFixture.resolveNoteLink)
        XCTAssertEqual(parsed.body.doc, .doc([linked("the *best* plan_now", planHref)]))
        XCTAssertEqual(serialize([linked("Intro", planHref + "?heading=Intro")]), "See [[Plan#Intro|Intro]]\n")
        XCTAssertEqual(serialize([linked("Plan", "noteit://note?title=Plan")], noteLinkName: { _ in nil }), "See [[Plan]]\n")
    }

    func testLongTargetsAndHeadingsAreCutToTheLinkLimit() throws {
        let long = String(repeating: "x", count: 130)
        let parsed = try MarkdownCodec.parse("See [[\(long)]] and [[Plan#\(long)]]\n", resolveNoteLink: MarkdownFixture.resolveNoteLink)
        guard case .doc(let blocks) = parsed.body.doc, case .paragraph(_, _, let content)? = blocks.first else {
            return XCTFail("no paragraph")
        }
        let hrefs = content.compactMap { inline -> String? in
            guard case .text(_, let marks) = inline else { return nil }
            return marks.compactMap { if case .link(let href) = $0 { href } else { nil } }.first
        }
        let cut = String(repeating: "x", count: 120)
        XCTAssertEqual(hrefs, ["noteit://note?title=" + cut, planHref + "?heading=" + cut])
        XCTAssertEqual(WikiLink.noteHref(hrefs[0]), .unresolved(title: cut, heading: nil))
        XCTAssertNil(WikiLink.noteHref("noteit://note?title=" + long))
    }

    func testTableCellEscapesThePipe() throws {
        let cell = { (content: [Inline]) in TableCell(header: false, content: [.paragraph(align: nil, indent: nil, content: content)]) }
        let table = DocNode.table(columnWidths: nil, rows: [[cell([.text("shown", marks: [.link(href: planHref)])]),
                                                             cell([.text("b", marks: [])])]])
        let markdown = serialize([table])
        XCTAssertEqual(markdown, "|  |  |\n| --- | --- |\n| [[Plan\\|shown]] | b |\n")
        let parsed = try MarkdownCodec.parse(markdown, resolveNoteLink: MarkdownFixture.resolveNoteLink)
        XCTAssertEqual(parsed.body.doc, .doc([table]))
    }

    func testMissingNameWritesTheTitle() throws {
        let id = UUID()
        let markdown = serialize([linked("Some Note", "noteit://note/" + id.uuidString)], noteLinkName: { _ in nil })
        XCTAssertEqual(markdown, "See [[Some Note]]\n")
        let parsed = try MarkdownCodec.parse(markdown) { $0 == "Some Note" ? id : nil }
        XCTAssertEqual(parsed.body.doc, .doc([linked("Some Note", "noteit://note/" + id.uuidString)]))
    }

    func testClashingTargetsBecomeMarkdownLinks() throws {
        let other = UUID()
        let blocks = [linked("Plan", planHref), linked("Plan", "noteit://note/" + other.uuidString)]
        let markdown = serialize(blocks)
        XCTAssertTrue(markdown.hasPrefix("See [[Plan]]\n"), markdown)
        XCTAssertTrue(markdown.contains("[Plan](noteit://note/\(other.uuidString))"), markdown)
        XCTAssertEqual(try MarkdownCodec.parse(markdown, resolveNoteLink: MarkdownFixture.resolveNoteLink).body.doc, .doc(blocks))
    }

    func testPortableFlavourWritesTheSameSyntax() {
        XCTAssertEqual(serialize([linked("the intro", planHref)], profile: .portable), "See [[Plan|the intro]]\n")
    }
}
