import Foundation
import XCTest
@testable import NoteItCore

/// The `snippets`, `statistics` and `evaluate` sections of Vectors/organise-vectors.json, which the web app's port
/// (`web/packages/doc/test/organise.test.ts`) reads too, so Note Info and search filters agree on both.
final class WebParityVectorTests: XCTestCase {
    private struct Doc: SearchDocument {
        var foldedText: [UInt8]
        var foldedImageText: [UInt8] = []
        var foldedTitle: String
        var tags: [String]
        var notebookID: UUID?
        var isPinned: Bool
        var isConflict: Bool
        var createdAt: Date
        var updatedAt: Date
        var openTaskCount: Int
        var doneTaskCount: Int
        var openDueDates: [LocalDateTime]
        var hasLiveReminder: Bool
        var hasAttachment: Bool
    }

    /// `snippets`: search highlights and note list snippets (SearchHighlighter), as [start, end) UTF-16 offsets.
    func testSnippets() throws {
        let pairs: ([NSRange]) -> [[Int]] = { $0.map { [$0.location, NSMaxRange($0)] } }
        for vector in try OrganiseVectors.section("snippets") {
            let text = try XCTUnwrap(vector["text"] as? String)
            let terms = try XCTUnwrap(vector["terms"] as? [String])
            let maxLength = try XCTUnwrap(vector["maxLength"] as? Int)
            XCTAssertEqual(pairs(SearchHighlighter.ranges(of: terms, in: text)), vector["ranges"] as? [[Int]], text)
            let snippet = SearchHighlighter.snippet(of: text, terms: terms, maxLength: maxLength)
            if let expected = vector["snippet"] as? [String: Any] {
                XCTAssertEqual(snippet?.text, expected["text"] as? String, text)
                XCTAssertEqual(snippet.map { pairs($0.highlights) }, expected["highlights"] as? [[Int]], text)
            } else {
                XCTAssertNil(snippet, text)
            }
        }
    }

    func testStatistics() throws {
        for vector in try OrganiseVectors.section("statistics") {
            let text = try XCTUnwrap(vector["text"] as? String)
            let stats = NoteStatistics(text: text)
            XCTAssertEqual(stats.words, vector["words"] as? Int, text)
            XCTAssertEqual(stats.characters, vector["characters"] as? Int, text)
            XCTAssertEqual(stats.readingTimeText, vector["reading"] as? String, text)
        }
    }

    func testEvaluate() throws {
        let section = try XCTUnwrap(OrganiseVectors.load()["evaluate"] as? [String: Any])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: XCTUnwrap(section["timeZone"] as? String)))
        calendar.firstWeekday = 2
        func date(_ token: String?) throws -> Date {
            guard let token else { return Date(timeIntervalSince1970: 0) }
            return try XCTUnwrap(LocalDateTime(token: token)?.date(in: calendar))
        }
        let now = try date(section["now"] as? String)
        let notebooks = try XCTUnwrap(section["notebooks"] as? [[String: Any]]).map { nb in
            NotebookNodeInput(id: UUID(uuidString: nb["id"] as! String)!,
                              parentID: (nb["parent"] as? String).flatMap(UUID.init(uuidString:)),
                              sortIndex: nb["sortIndex"] as! Int, name: nb["name"] as! String)
        }
        let context = QueryContext(now: now, calendar: calendar, notebooks: NotebookTree(notebooks))
        for vector in try XCTUnwrap(section["cases"] as? [[String: Any]]) {
            let query = try XCTUnwrap(vector["query"] as? String)
            let d = try XCTUnwrap(vector["doc"] as? [String: Any])
            let doc = try Doc(foldedText: Array(TextFold.fold(d["text"] as? String ?? "").utf8),
                              foldedTitle: TextFold.fold(d["title"] as? String ?? ""),
                              tags: d["tags"] as? [String] ?? [],
                              notebookID: (d["notebook"] as? String).flatMap(UUID.init(uuidString:)),
                              isPinned: d["isPinned"] as? Bool ?? false, isConflict: d["isConflict"] as? Bool ?? false,
                              createdAt: date(d["createdAt"] as? String), updatedAt: date(d["updatedAt"] as? String),
                              openTaskCount: d["open"] as? Int ?? 0, doneTaskCount: d["done"] as? Int ?? 0,
                              openDueDates: (d["due"] as? [String] ?? []).compactMap(LocalDateTime.init(token:)),
                              hasLiveReminder: d["reminder"] as? Bool ?? false, hasAttachment: d["attachment"] as? Bool ?? false)
            XCTAssertEqual(QueryEvaluator.matches(SearchQuery.parse(query), doc, context: context), vector["match"] as? Bool, query)
        }
    }
}
