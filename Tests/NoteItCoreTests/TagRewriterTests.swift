import Foundation
import NoteItCore
import XCTest

final class TagRewriterTests: XCTestCase {
    private func apply(_ edit: TagEdit, _ text: String, masked: String? = nil) -> String {
        let result = NSMutableString(string: text)
        for change in TagRewriter.edits(for: edit, inMasked: masked ?? text) {
            result.replaceCharacters(in: change.range, with: change.replacement)
        }
        return result as String
    }

    func testRenameKeepsNestedSegments() {
        XCTAssertEqual(apply(.rename(from: "work", to: "job"), "a #work b #work/q3 c #workshop"),
                       "a #job b #job/q3 c #workshop")
    }

    func testRenameIsCaseInsensitiveAndWritesTargetAsTyped() {
        XCTAssertEqual(apply(.rename(from: "work", to: "Projects/Job"), "#Work done"), "#Projects/Job done")
    }

    func testRenameRefusesInsideItselfAndBadNames() {
        XCTAssertEqual(TagRewriter.renameProblem(from: "work", to: "work/sub"), TagRewriter.insideItselfMessage)
        XCTAssertEqual(TagRewriter.renameProblem(from: "work", to: "bad name"), TagRewriter.invalidNameMessage)
        XCTAssertNil(TagRewriter.renameProblem(from: "work", to: "#job"))
    }

    func testDeleteRemovesTagAndOneSpace() {
        XCTAssertEqual(apply(.delete("draft"), "one #draft two"), "one two")
        XCTAssertEqual(apply(.delete("draft"), "one #draft"), "one")
        XCTAssertEqual(apply(.delete("draft"), "#draft/x start"), "start")
    }

    func testMaskedRangesAreUntouched() {
        let text = "`#work` and #work"
        let masked = String(repeating: " ", count: 7) + " and #work"
        XCTAssertEqual(apply(.rename(from: "work", to: "job"), text, masked: masked), "`#work` and #job")
    }
}
