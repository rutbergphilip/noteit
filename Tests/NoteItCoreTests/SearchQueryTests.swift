import Foundation
import XCTest
@testable import NoteItCore

/// Renders a query tree in the vectors file's notation.
func describe(_ node: QueryNode) -> String {
    switch node {
    case .all: return "all"
    case .word(let v): return "word(\(v))"
    case .phrase(let v): return "phrase(\(v))"
    case .title(let v): return "title(\(v))"
    case .tag(let v): return "tag(\(v))"
    case .notebook(let v): return "notebook(\(v))"
    case .is(let f): return "is(\(f.rawValue))"
    case .has(let f): return "has(\(f.rawValue))"
    case .date(let field, let filter):
        let value: String
        switch filter {
        case .within(let t): value = "within(\(Int(t)))"
        case .olderThan(let t): value = "olderThan(\(Int(t)))"
        case .on(let d): value = "on(\(d.token))"
        case .after(let d): value = "after(\(d.token))"
        case .before(let d): value = "before(\(d.token))"
        case .today: value = "today"
        case .yesterday: value = "yesterday"
        case .thisWeek: value = "thisWeek"
        case .lastWeek: value = "lastWeek"
        case .thisMonth: value = "thisMonth"
        case .overdue: value = "overdue"
        }
        return "date(\(field.rawValue),\(value))"
    case .not(let inner): return "not(\(describe(inner)))"
    case .and(let nodes): return "and(\(nodes.map(describe).joined(separator: ",")))"
    case .or(let nodes): return "or(\(nodes.map(describe).joined(separator: ",")))"
    }
}

final class SearchQueryTests: XCTestCase {
    func testVectors() throws {
        for vector in try OrganiseVectors.section("queries") {
            let input = try XCTUnwrap(vector["input"] as? String)
            let query = SearchQuery.parse(input)
            XCTAssertEqual(describe(query.root), vector["tree"] as? String, input)
            if let highlight = vector["highlight"] as? [String] {
                XCTAssertEqual(query.highlightTerms, highlight, input)
            }
            if let text = vector["text"] as? Bool {
                XCTAssertEqual(query.hasTextTerms, text, input)
            }
            if let issues = vector["issues"] as? Int {
                XCTAssertEqual(query.issues.count, issues, input)
            }
            if let message = vector["message"] as? String {
                XCTAssertEqual(query.issues.first?.message, message, input)
            }
        }
    }

    func testEmptyQuery() {
        XCTAssertTrue(SearchQuery.parse("   ").isEmpty)
        XCTAssertFalse(SearchQuery.parse("a").isEmpty)
    }

    func testIssueRangeCoversTerm() throws {
        let text = "budget edited:<7x"
        let issue = try XCTUnwrap(SearchQuery.parse(text).issues.first)
        XCTAssertEqual(String(text[issue.range]), "edited:<7x")
    }

    func testUnclosedParenthesisReported() throws {
        let text = "x (a OR b"
        let issue = try XCTUnwrap(SearchQuery.parse(text).issues.first)
        XCTAssertEqual(String(text[issue.range]), "(")
    }

    func testOrIsCaseSensitive() {
        XCTAssertEqual(describe(SearchQuery.parse("a or b").root), "and(word(a),word(or),word(b))")
    }

    func testNamedPeriodsAndUnits() {
        let cases: [(String, String)] = [
            ("edited:today", "date(edited,today)"), ("edited:yesterday", "date(edited,yesterday)"),
            ("created:last-week", "date(created,lastWeek)"), ("created:this-month", "date(created,thisMonth)"),
            ("due:today", "date(due,today)"), ("edited:<3h", "date(edited,within(10800))"),
            ("edited:>1m", "date(edited,olderThan(2592000))"), ("edited:<1y", "date(edited,within(31536000))"),
        ]
        for (input, tree) in cases { XCTAssertEqual(describe(SearchQuery.parse(input).root), tree, input) }
    }

    func testQuotedKeyValueAndNegatedPhrase() {
        XCTAssertEqual(describe(SearchQuery.parse("-\"a phrase\" in:\"My Book\"").root),
                       "and(not(phrase(a phrase)),notebook(My Book))")
    }
}
