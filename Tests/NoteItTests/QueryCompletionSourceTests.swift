@testable import NoteIt
import XCTest

final class QueryCompletionSourceTests: XCTestCase {
    private func titles(_ text: String, tags: [String] = [], notebooks: [String] = []) -> [String] {
        QueryCompletionSource.suggestions(for: text, tags: tags, notebooks: notebooks).map(\.title)
    }

    func testCompletesKeys() {
        XCTAssertEqual(titles("apple t"), ["tag:", "title:"])
        XCTAssertEqual(QueryCompletionSource.suggestions(for: "apple -ta", tags: [], notebooks: []).first?.text, "apple -tag:")
        XCTAssertEqual(titles("apple "), [])
    }

    func testCompletesValuesForTheKey() {
        XCTAssertEqual(titles("is:t"), ["is:todo"])
        XCTAssertEqual(titles("tag:ac", tags: ["work", "work/acme", "home"]), ["tag:work/acme"])
        XCTAssertEqual(titles("due:ov"), ["due:overdue"])
        XCTAssertEqual(titles("edited:ov"), [])
    }

    func testQuotesNotebookNamesWithSpaces() {
        let suggestion = QueryCompletionSource.suggestions(for: "x in:cli", tags: [], notebooks: ["Client Work"]).first
        XCTAssertEqual(suggestion?.text, "x in:\"Client Work\" ")
    }
}
