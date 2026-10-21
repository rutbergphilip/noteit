import AppKit
import XCTest
@testable import NoteIt

@MainActor
final class SearchHighlightControllerTests: XCTestCase {
    private func make(_ text: String) -> (SearchHighlightController, NoteItTextView, EditorController) {
        let (_, textView) = NoteItTextView.make()
        textView.storage.setAttributedString(NSAttributedString(string: text))
        let editor = EditorController()
        editor.textView = textView
        let controller = SearchHighlightController()
        controller.editor = editor
        return (controller, textView, editor)
    }

    private func highlighted(_ textView: NSTextView, at location: Int) -> Bool {
        textView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: location, effectiveRange: nil) != nil
    }

    func testHighlightsFoldedMatchesAndClearsOnEdit() {
        let (controller, textView, editor) = make("Café\nmeet at the CAFE")
        controller.apply(["cafe"])
        XCTAssertEqual(controller.ranges, [NSRange(location: 0, length: 4), NSRange(location: 17, length: 4)])
        XCTAssertTrue(highlighted(textView, at: 18))
        XCTAssertEqual(SearchHighlightController.firstTerm(in: textView), "cafe")
        textView.storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "x")
        XCTAssertTrue(controller.ranges.isEmpty)
        XCTAssertFalse(highlighted(textView, at: 19))
        XCTAssertNil(SearchHighlightController.firstTerm(in: textView))
        _ = editor
    }

    func testEmptySearchClears() {
        let (controller, textView, editor) = make("budget plan")
        controller.apply(["budget"])
        XCTAssertTrue(highlighted(textView, at: 1))
        controller.apply([])
        XCTAssertFalse(highlighted(textView, at: 1))
        _ = editor
    }
}
