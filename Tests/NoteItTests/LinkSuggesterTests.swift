import AppKit
import NoteItCore
import XCTest
@testable import NoteIt

@MainActor
final class LinkSuggesterTests: XCTestCase {
    private let now = Date()

    private func candidate(_ title: String, age: TimeInterval = 0, id: UUID = UUID()) -> LinkCandidate {
        LinkCandidate(id: id, title: title, notebookName: "Work", updatedAt: now.addingTimeInterval(-age))
    }

    private func titles(_ suggestions: [LinkSuggestion]) -> [String] {
        suggestions.map {
            switch $0 {
            case .note(_, let title, _, _): title
            case .heading(_, let text, _): "#" + text
            case .create(let title): "+" + title
            }
        }
    }

    func testEmptyQueryShowsRecent() {
        let candidates = (0..<10).map { candidate("Note \($0)", age: TimeInterval($0)) }
        let result = LinkSuggester.suggestions(for: LinkQuery(""), candidates: candidates.shuffled(), headings: { _ in [] })
        XCTAssertEqual(titles(result), (0..<8).map { "Note \($0)" })
    }

    func testExactTitleFirst() {
        let candidates = [candidate("Atlas Planning", age: 0), candidate("atlas", age: 100), candidate("Atlases", age: 0)]
        let result = LinkSuggester.suggestions(for: LinkQuery("Atlas"), candidates: candidates, headings: { _ in [] })
        XCTAssertEqual(titles(result).first, "atlas")
        XCTAssertFalse(titles(result).contains { $0.hasPrefix("+") })
    }

    func testExcludesCurrentAndEmptyTitles() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-suggest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(location: LibraryLocation(url: root, seedsFreshLibrary: false))
        let current = store.createNote(in: nil, initial: NSAttributedString(string: "Current")).id
        store.createNote(in: nil, initial: NSAttributedString(string: ""))
        let other = store.createNote(in: nil, initial: NSAttributedString(string: "Other")).id
        let candidates = store.linkCandidates(excluding: current)
        XCTAssertEqual(candidates.map(\.id), [other])
        XCTAssertEqual(titles(LinkSuggester.suggestions(for: LinkQuery(""), candidates: candidates, headings: { _ in [] })), ["Other"])
    }

    func testCreateRowWhenNoExactMatch() {
        let candidates = [candidate("Atlas Planning")]
        XCTAssertEqual(titles(LinkSuggester.suggestions(for: LinkQuery("Atlas"), candidates: candidates, headings: { _ in [] })),
                       ["Atlas Planning", "+Atlas"])
        XCTAssertEqual(titles(LinkSuggester.suggestions(for: LinkQuery("Zebra"), candidates: candidates, headings: { _ in [] })),
                       ["+Zebra"])
        let many = (0..<20).map { candidate("Atlas \($0)", age: TimeInterval($0)) }
        let limited = LinkSuggester.suggestions(for: LinkQuery("Atlas"), candidates: many, headings: { _ in [] })
        XCTAssertEqual(limited.count, 8)
        XCTAssertEqual(limited.last, .create(title: "Atlas"))
    }

    func testHeadingMode() {
        let target = candidate("Atlas")
        let outline = [OutlineItem(level: 0, text: "Atlas", range: NSRange(location: 0, length: 5)),
                       OutlineItem(level: 1, text: "Budget", range: NSRange(location: 6, length: 6)),
                       OutlineItem(level: 2, text: "Timeline", range: NSRange(location: 13, length: 8))]
        let headings: (UUID) -> [OutlineItem] = { $0 == target.id ? outline : [] }
        var query = LinkQuery("Atlas#bud")
        XCTAssertEqual(LinkSuggester.suggestions(for: query, candidates: [candidate("Atlas Old"), target], headings: headings),
                       [.heading(noteID: target.id, text: "Budget", level: 1)])
        query = LinkQuery("Atlas")
        query.heading = ""
        XCTAssertEqual(titles(LinkSuggester.suggestions(for: query, candidates: [target], headings: headings)), ["#Budget", "#Timeline"])
    }

    func testAliasDoesNotFilter() {
        let candidates = [candidate("Atlas")]
        let result = LinkSuggester.suggestions(for: LinkQuery("Atlas|the plan"), candidates: candidates, headings: { _ in [] })
        XCTAssertEqual(titles(result), ["Atlas"])
    }
}
