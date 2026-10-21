import Foundation
import NoteItCore
import XCTest

private struct RankDoc: SearchDocument {
    var title = ""
    var body = ""
    var image = ""
    var foldedText: [UInt8] { Array(TextFold.fold(title + "\n" + body).utf8) }
    var foldedImageText: [UInt8] { Array(TextFold.fold(image).utf8) }
    var foldedTitle: String { TextFold.fold(title) }
    var tags: [String] = []
    var notebookID: UUID?
    var isPinned = false
    var isConflict = false
    var createdAt = Date(timeIntervalSince1970: 0)
    var updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var openTaskCount = 0
    var doneTaskCount = 0
    var openDueDates: [LocalDateTime] = []
    var hasLiveReminder = false
    var hasAttachment = false
}

final class SearchRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func order(_ docs: [RankDoc], _ text: String) -> [Int] {
        SearchRanker.rank(docs, query: SearchQuery.parse(text), foldedQueryText: TextFold.fold(text), now: now).map(\.index)
    }

    func testTitleMatchOutranksBodyMatch() {
        let docs = [RankDoc(title: "Groceries", body: "buy invoice paper"), RankDoc(title: "Invoice", body: "send it")]
        XCTAssertEqual(order(docs, "invoice"), [1, 0])
    }

    func testWordStartOutranksMidWord() {
        let docs = [RankDoc(title: "A", body: "the reinvoiced batch"), RankDoc(title: "B", body: "the invoiced batch")]
        XCTAssertEqual(order(docs, "invoice"), [1, 0])
    }

    func testRecencyBreaksTies() {
        var old = RankDoc(title: "A", body: "budget review")
        old.updatedAt = now.addingTimeInterval(-200 * 86_400)
        let fresh = RankDoc(title: "B", body: "budget review")
        XCTAssertEqual(order([old, fresh], "budget"), [1, 0])
    }

    func testImageOnlyMatchIsFlagged() {
        let docs = [RankDoc(title: "Scan", body: "nothing here", image: "receipt total"), RankDoc(title: "Receipt", body: "")]
        let hits = SearchRanker.rank(docs, query: SearchQuery.parse("receipt"), foldedQueryText: "receipt", now: now)
        XCTAssertEqual(hits.map(\.index), [1, 0])
        XCTAssertEqual(hits.map(\.onlyInImage), [false, true])
    }

    func testAccentedTermMatchesWordStart() {
        let docs = [RankDoc(title: "A", body: "x\u{e9}t\u{e9} long"), RankDoc(title: "B", body: "\u{e9}t\u{e9} long")]
        XCTAssertEqual(order(docs, "été"), [1, 0])
    }
}

final class SearchHighlighterTests: XCTestCase {
    func testRangesFoldAccentsAndCase() {
        let text = "Café CAFE cafe"
        let ranges = SearchHighlighter.ranges(of: ["cafe"], in: text)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["Café", "CAFE", "cafe"])
    }

    func testRangesSurviveEmoji() {
        let text = "👍🏽 plan 👨‍👩‍👧 Plan"
        let ranges = SearchHighlighter.ranges(of: ["plan"], in: text)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["plan", "Plan"])
    }

    func testOverlappingRangesMerge() {
        let ranges = SearchHighlighter.ranges(of: ["invoice", "voice"], in: "invoice")
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 7)])
    }

    func testSnippetAddsEllipsesAroundMatch() throws {
        let text = String(repeating: "lorem ipsum ", count: 30) + "the invoice is late " + String(repeating: "dolor sit ", count: 30)
        let snippet = try XCTUnwrap(SearchHighlighter.snippet(of: text, terms: ["invoice"], maxLength: 60))
        XCTAssertTrue(snippet.text.hasPrefix("…"))
        XCTAssertTrue(snippet.text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(snippet.text.count, 62)
        let highlighted = snippet.highlights.map { (snippet.text as NSString).substring(with: $0) }
        XCTAssertEqual(highlighted, ["invoice"])
    }

    func testSnippetWithoutMatchIsNil() {
        XCTAssertNil(SearchHighlighter.snippet(of: "nothing to see", terms: ["invoice"], maxLength: 60))
    }
}
