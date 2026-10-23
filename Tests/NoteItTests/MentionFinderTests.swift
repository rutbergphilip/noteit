import AppKit
import XCTest
@testable import NoteIt

final class MentionFinderTests: XCTestCase {
    private func text(_ body: String, title: String = "Title") -> NSMutableAttributedString {
        NSMutableAttributedString(string: title + "\n" + body, attributes: EditorStyle.bodyAttributes)
    }

    private func found(_ title: String, in text: NSAttributedString) -> [String] {
        MentionFinder.ranges(of: title, in: text).map { (text.string as NSString).substring(with: $0) }
    }

    func testWholeWordOnly() {
        let body = text("Atlas, atlases and Atlas2 and the atlas.")
        XCTAssertEqual(found("Atlas", in: body), ["Atlas", "atlas"])
        XCTAssertTrue(MentionFinder.mayMention("atlas", inFolded: "see atlas."))
        XCTAssertFalse(MentionFinder.mayMention("atlas", inFolded: "atlases and atlas2"))
    }

    func testIgnoresExistingLinksAndCode() {
        let body = text("Atlas linked, ")
        body.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 6, length: 5))
        body.append(NSAttributedString(string: "Atlas", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        body.append(NSAttributedString(string: " and Atlas plain", attributes: EditorStyle.bodyAttributes))
        XCTAssertEqual(MentionFinder.ranges(of: "Atlas", in: body).count, 1)
        XCTAssertEqual(found("Atlas", in: body), ["Atlas"])
        XCTAssertEqual(MentionFinder.ranges(of: "Atlas", in: body).first?.location, (body.string as NSString).range(of: "Atlas plain").location)
    }

    func testDiacriticAndCaseInsensitive() {
        XCTAssertEqual(found("Café Plan", in: text("the CAFE PLAN and the café plan")), ["CAFE PLAN", "café plan"])
    }

    func testSkipsTitleLine() {
        XCTAssertEqual(found("Atlas", in: text("nothing here", title: "Atlas notes")), [])
        XCTAssertEqual(found("Atlas", in: text("Atlas", title: "Atlas notes")), ["Atlas"])
    }
}
