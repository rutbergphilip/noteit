import NoteItCore
import XCTest

final class NoteStatisticsTests: XCTestCase {
    func testEmptyTextHasNothingToRead() {
        let stats = NoteStatistics(text: "")
        XCTAssertEqual(stats, NoteStatistics(words: 0, characters: 0))
        XCTAssertEqual(stats.readingMinutes, 0)
        XCTAssertEqual(stats.readingTimeText, "—")
    }

    func testWordsIgnorePunctuationAndLineBreaks() {
        let stats = NoteStatistics(text: "Hello, world!\n\nIt's  a - test.")
        XCTAssertEqual(stats.words, 5)
        XCTAssertEqual(stats.characters, 30)
    }

    func testAttachmentPlaceholdersAreNotCounted() {
        let stats = NoteStatistics(text: "a\u{FFFC}b \u{FFFC}")
        XCTAssertEqual(stats.characters, 3)
        XCTAssertEqual(stats.words, 2)
    }

    func testReadingTimeRoundsUp() {
        func text(words: Int) -> String { Array(repeating: "word", count: words).joined(separator: " ") }
        XCTAssertEqual(NoteStatistics(text: text(words: 10)).readingTimeText, "Less than a minute")
        XCTAssertEqual(NoteStatistics(text: text(words: 150)).readingTimeText, "1 min")
        XCTAssertEqual(NoteStatistics(text: text(words: 200)).readingTimeText, "1 min")
        XCTAssertEqual(NoteStatistics(text: text(words: 201)).readingTimeText, "2 min")
        XCTAssertEqual(NoteStatistics(text: text(words: 1000)).readingTimeText, "5 min")
    }

    func testGraphemeClustersCountOnce() {
        XCTAssertEqual(NoteStatistics(text: "e\u{301}👍🏽").characters, 2)
    }
}
