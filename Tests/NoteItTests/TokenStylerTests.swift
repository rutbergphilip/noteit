import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class TokenStylerTests: XCTestCase {
    private func chip(_ textView: NSTextView, at index: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(.tokenChip, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    func testStylesTokensButNotCode() {
        let (_, textView) = NoteItTextView.make()
        let text = NSMutableAttributedString(string: "Plan #work/acme @due(2026-01-02) ",
                                             attributes: [.font: NSFont.systemFont(ofSize: 14)])
        text.append(NSAttributedString(string: "#code", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]))
        textView.textStorage?.setAttributedString(text)
        let styler = textView.tokenStyler
        styler.today = { LocalDateTime(year: 2026, month: 1, day: 5)! }
        styler.restyleAll()
        XCTAssertEqual(chip(textView, at: 6), TokenStyler.tagFill)
        XCTAssertEqual(textView.layoutManager?.temporaryAttribute(.tokenTag, atCharacterIndex: 6, effectiveRange: nil) as? String, "work/acme")
        XCTAssertEqual(chip(textView, at: 18), TokenStyler.overdueFill)
        XCTAssertNil(chip(textView, at: 35))
        XCTAssertNil(chip(textView, at: 2))

        textView.textStorage?.replaceCharacters(in: NSRange(location: 5, length: 1), with: "x")
        styler.restyleAll()
        XCTAssertNil(chip(textView, at: 6))
    }

    func testTagCompletionRanksByMatchThenCount() {
        let ranked = TagCompletionSource.rank(query: "wo", counts: ["work": 2, "work/acme": 5, "home": 9, "wobble": 1])
        XCTAssertEqual(Set(ranked.map(\.0)), ["work", "work/acme", "wobble"])
        XCTAssertFalse(ranked.contains { $0.0 == "home" })
        XCTAssertEqual(TagCompletionSource.rank(query: "", counts: ["a": 1, "b": 3]).map(\.0), ["b", "a"])
    }

    func testCompletionEndsOnInvalidCharacters() {
        let source = TagCompletionSource(store: NoteStore(location: LibraryLocation(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("noteit-tagc-\(UUID().uuidString)"),
            seedsFreshLibrary: false)))
        XCTAssertFalse(source.shouldEnd(for: ""))
        XCTAssertFalse(source.shouldEnd(for: "work/"))
        XCTAssertTrue(source.shouldEnd(for: "work acme"))
        XCTAssertTrue(source.shouldEnd(for: "a/b/c/d/e/f"))
    }
}
