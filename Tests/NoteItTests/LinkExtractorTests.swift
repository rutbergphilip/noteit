import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

final class LinkExtractorTests: XCTestCase {
    private let target = UUID()

    private func noteURL(_ id: UUID) -> URL { NoteLink.note(id: id, heading: nil).url }

    func testExtractsNoteLinksOnly() {
        let text = NSMutableAttributedString(string: "See Atlas and the web and Budget.")
        text.addAttribute(.link, value: noteURL(target), range: NSRange(location: 4, length: 5))
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 18, length: 3))
        text.addAttribute(.link, value: URL(string: "noteit://open?id=x")!, range: NSRange(location: 22, length: 3))
        text.addAttribute(.link, value: NoteLink.unresolved(title: "Budget", heading: nil).url,
                          range: NSRange(location: 26, length: 6))
        let links = LinkExtractor.links(in: text)
        XCTAssertEqual(links.map(\.text), ["Atlas", "Budget"])
        XCTAssertEqual(links.map(\.location), [4, 26])
        XCTAssertEqual(links.first?.link, .note(id: target, heading: nil))
        XCTAssertEqual(links.last?.link, .unresolved(title: "Budget", heading: nil))
        XCTAssertEqual(links.first?.context, "See Atlas and the web and Budget.")
    }

    func testMergesAdjacentRuns() {
        let text = NSMutableAttributedString(string: "Project Atlas")
        text.addAttributes([.link: noteURL(target), .font: NSFont.boldSystemFont(ofSize: 12)],
                           range: NSRange(location: 0, length: 8))
        text.addAttributes([.link: noteURL(target), .font: NSFont.systemFont(ofSize: 12)],
                           range: NSRange(location: 8, length: 5))
        let links = LinkExtractor.links(in: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.text, "Project Atlas")
    }

    func testContextIsTrimmedToOneLine() {
        let before = String(repeating: "word ", count: 30)
        let after = String(repeating: " more", count: 30)
        let text = NSMutableAttributedString(string: "First line\n" + before + "Atlas\u{2028}" + after + "\nNext")
        let location = 11 + (before as NSString).length
        text.addAttribute(.link, value: noteURL(target), range: NSRange(location: location, length: 5))
        let context = try! XCTUnwrap(LinkExtractor.links(in: text).first?.context)
        XCTAssertLessThanOrEqual(context.count, 80)
        XCTAssertFalse(context.contains("\n"))
        XCTAssertFalse(context.contains("\u{2028}"))
        XCTAssertTrue(context.contains("Atlas"))
        XCTAssertTrue(context.hasPrefix("…"))
        XCTAssertTrue(context.hasSuffix("…"))
        XCTAssertFalse(context.contains("First line"))
    }

    func testStringLinkValue() {
        let text = NSMutableAttributedString(string: "Atlas")
        text.addAttribute(.link, value: noteURL(target).absoluteString, range: NSRange(location: 0, length: 5))
        XCTAssertEqual(LinkExtractor.links(in: text).first?.link, .note(id: target, heading: nil))
    }

    func testLimit() {
        let text = NSMutableAttributedString()
        for _ in 0..<(LinkExtractor.maxLinksPerNote + 10) {
            text.append(NSAttributedString(string: "x", attributes: [.link: noteURL(UUID())]))
            text.append(NSAttributedString(string: " "))
        }
        XCTAssertEqual(LinkExtractor.links(in: text).count, LinkExtractor.maxLinksPerNote)
    }
}
