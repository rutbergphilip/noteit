import NoteItCore
import XCTest

// Expected values are the output of `NoteStore.fold` before it moved here.
final class TextFoldTests: XCTestCase {
    func testCaseAndDiacriticFolding() {
        XCTAssertEqual(TextFold.fold("Éclair"), "eclair")
        XCTAssertEqual(TextFold.fold("Crème Brûlée"), "creme brulee")
        XCTAssertEqual(TextFold.fold("ÅÄÖ åäö"), "aao aao")
        XCTAssertEqual(TextFold.fold("e\u{301}"), "e")
    }

    func testWidthFolding() {
        XCTAssertEqual(TextFold.fold("ＡＢＣ１２３"), "abc123")
        XCTAssertEqual(TextFold.fold("ｶﾀｶﾅ"), "カタカナ")
    }

    func testEmptyString() {
        XCTAssertEqual(TextFold.fold(""), "")
    }
}
