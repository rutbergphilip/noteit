import XCTest
@testable import NoteIt

final class FuzzyMatcherTests: XCTestCase {
    func testNonMatchReturnsNil() {
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "Grocery Notes"))
        XCTAssertNil(FuzzyMatcher.match("ab", in: "ba"))
        XCTAssertNil(FuzzyMatcher.match("long query", in: ""))
    }

    func testEmptyOrWhitespaceQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatcher.match("", in: "Anything"), FuzzyMatch(score: 0, matchedIndices: []))
        XCTAssertEqual(FuzzyMatcher.match("   \t", in: "Anything"), FuzzyMatch(score: 0, matchedIndices: []))
        XCTAssertEqual(FuzzyMatcher.match("", in: ""), FuzzyMatch(score: 0, matchedIndices: []))
    }

    func testCaseAndDiacriticFolding() {
        XCTAssertEqual(FuzzyMatcher.match("cafe", in: "Café")?.matchedIndices, [0, 1, 2, 3])
        XCTAssertEqual(FuzzyMatcher.match("CAFÉ", in: "cafe")?.matchedIndices, [0, 1, 2, 3])
        XCTAssertEqual(FuzzyMatcher.match("resume", in: "My Résumé")?.matchedIndices, [3, 4, 5, 6, 7, 8])
    }

    func testDecomposedCharactersKeepOriginalOffsets() {
        let candidate = "Cafe\u{301} au lait"
        XCTAssertEqual(candidate.count, 12)
        XCTAssertEqual(FuzzyMatcher.match("cafe", in: candidate)?.matchedIndices, [0, 1, 2, 3])
        XCTAssertEqual(FuzzyMatcher.match("lait", in: candidate)?.matchedIndices, [8, 9, 10, 11])
    }

    func testWidthFolding() {
        XCTAssertEqual(FuzzyMatcher.match("note", in: "ＮＯＴＥ")?.matchedIndices, [0, 1, 2, 3])
    }

    func testWordStartsBeatInWordMatches() throws {
        let words = try XCTUnwrap(FuzzyMatcher.match("gn", in: "Grocery Notes"))
        let inWord = try XCTUnwrap(FuzzyMatcher.match("gn", in: "Ginger"))
        XCTAssertGreaterThan(words.score, inWord.score)
        XCTAssertEqual(words.matchedIndices, [0, 8])
    }

    func testPrefersWordStartOccurrence() {
        XCTAssertEqual(FuzzyMatcher.match("n", in: "Grocery Notes")?.matchedIndices, [8])
        XCTAssertEqual(FuzzyMatcher.match("pl", in: "Simple Plan")?.matchedIndices, [7, 8])
    }

    func testCamelCaseBoundaryIsAWordStart() {
        XCTAssertEqual(FuzzyMatcher.match("nb", in: "myNoteBook")?.matchedIndices, [2, 6])
    }

    func testPrefixBeatsMiddleMatch() throws {
        let prefix = try XCTUnwrap(FuzzyMatcher.match("not", in: "Notes"))
        let middle = try XCTUnwrap(FuzzyMatcher.match("not", in: "My notes"))
        XCTAssertGreaterThan(prefix.score, middle.score)
    }

    func testShorterCandidateWins() throws {
        let short = try XCTUnwrap(FuzzyMatcher.match("plan", in: "Plan"))
        let long = try XCTUnwrap(FuzzyMatcher.match("plan", in: "Plan for the summer holidays"))
        XCTAssertGreaterThan(short.score, long.score)
    }

    func testConsecutiveRunBeatsScatteredMatch() throws {
        let run = try XCTUnwrap(FuzzyMatcher.match("ice", in: "Nice list"))
        let scattered = try XCTUnwrap(FuzzyMatcher.match("ice", in: "Indicate"))
        XCTAssertGreaterThan(run.score, scattered.score)
    }

    func testMultipleTermsMatchInAnyOrder() throws {
        let forward = try XCTUnwrap(FuzzyMatcher.match("grocery notes", in: "Grocery Notes"))
        let reversed = try XCTUnwrap(FuzzyMatcher.match("notes groc", in: "Grocery Notes"))
        XCTAssertEqual(forward.matchedIndices, [0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12])
        XCTAssertEqual(reversed.matchedIndices, [0, 1, 2, 3, 8, 9, 10, 11, 12])
        XCTAssertNil(FuzzyMatcher.match("notes xyz", in: "Grocery Notes"))
    }

    func testEmojiTitleIndices() {
        XCTAssertEqual(FuzzyMatcher.match("pizza", in: "🍕 Pizza night")?.matchedIndices, [2, 3, 4, 5, 6])
        XCTAssertEqual(FuzzyMatcher.match("fam", in: "👨‍👩‍👧 Family")?.matchedIndices, [2, 3, 4])
        XCTAssertEqual(FuzzyMatcher.match("🍕", in: "Party 🍕")?.matchedIndices, [6])
        XCTAssertEqual(FuzzyMatcher.match("x", in: "🇸🇪x")?.matchedIndices, [1])
    }

    func testExpandingFoldsKeepOriginalOffsets() {
        XCTAssertEqual(FuzzyMatcher.match("strasse", in: "Straße")?.matchedIndices, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(FuzzyMatcher.match("STRASSE", in: "Hauptstraße 5")?.matchedIndices, [5, 6, 7, 8, 9, 10])
        XCTAssertEqual(FuzzyMatcher.match("file", in: "ﬁle")?.matchedIndices, [0, 1, 2])
        XCTAssertEqual(FuzzyMatcher.match("ﬁ", in: "Profile")?.matchedIndices, [3, 4])
        XCTAssertEqual(FuzzyMatcher.match("istanbul", in: "İstanbul")?.matchedIndices, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(FuzzyMatcher.match("İst", in: "istanbul")?.matchedIndices, [0, 1, 2])
    }

    func testMatchedCharactersSpellTheQuery() throws {
        let cases: [(String, String)] = [
            ("strasse", "Die Straße"),
            ("file", "Mein ﬁle"),
            ("istanbul", "Trip to İstanbul"),
            ("cafe", "Cafe\u{301} au lait"),
            ("resume", "My Résumé"),
            ("gn", "Grocery Notes"),
            ("pizza", "🍕 Pizza night"),
            ("note", "ＮＯＴＥ")
        ]
        for (query, candidate) in cases {
            let match = try XCTUnwrap(FuzzyMatcher.match(query, in: candidate), "\(query) in \(candidate)")
            let characters = Array(candidate)
            let spelled = String(match.matchedIndices.map { characters[$0] })
            XCTAssertEqual(NoteStore.fold(spelled), NoteStore.fold(query), "\(query) in \(candidate)")
        }
    }

    // MARK: - Contiguity and exactness

    private func assertRanksAbove(_ query: String, _ better: String, _ worse: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let high = try XCTUnwrap(FuzzyMatcher.match(query, in: better), file: file, line: line)
        let low = try XCTUnwrap(FuzzyMatcher.match(query, in: worse), file: file, line: line)
        XCTAssertGreaterThan(high.score, low.score, "\(query): \(better) vs \(worse)", file: file, line: line)
    }

    func testWholeWordMidTitleBeatsScatteredWordStarts() throws {
        try assertRanksAbove("plan", "Project plan", "Pick Lamb And Noodles")
        try assertRanksAbove("test", "Unit test plan", "The East Side Trip")
        try assertRanksAbove("cat", "My cat", "Call A Taxi")
        XCTAssertEqual(FuzzyMatcher.match("plan", in: "Project plan")?.matchedIndices, [8, 9, 10, 11])
    }

    func testContiguousSubstringBeatsScatteredMatch() throws {
        try assertRanksAbove("ice", "Nice list", "I Can Eat")
        try assertRanksAbove("gn", "Signal", "Grocery Notes")
        try assertRanksAbove("note", "A very long title with notes somewhere in the middle of it", "N O T E")
    }

    func testRunStartingOnWordStartBeatsMidWordRun() throws {
        try assertRanksAbove("plan", "Project plan", "Explanation")
    }

    func testExactTitleRanksFirst() throws {
        let exact = try XCTUnwrap(FuzzyMatcher.match("plan", in: "Plan"))
        for other in ["Plan B", "Plans", "Planning", "Plan plan plan", "P l a n", "Project plan"] {
            let match = try XCTUnwrap(FuzzyMatcher.match("plan", in: other))
            XCTAssertGreaterThan(exact.score, match.score, other)
        }
        let folded = try XCTUnwrap(FuzzyMatcher.match("cafe", in: "CAFÉ"))
        let prefix = try XCTUnwrap(FuzzyMatcher.match("cafe", in: "Cafe"))
        XCTAssertEqual(folded.score, prefix.score)
        let repeated = try XCTUnwrap(FuzzyMatcher.match("plan plan plan", in: "Plan plan plan plan"))
        let exactRepeated = try XCTUnwrap(FuzzyMatcher.match("plan plan plan", in: "Plan Plan Plan"))
        XCTAssertGreaterThan(exactRepeated.score, repeated.score)
    }

    func testFoldedQueryIsReusable() {
        let query = FuzzyQuery("gro not")
        XCTAssertEqual(FuzzyMatcher.match(query, in: "Grocery Notes"), FuzzyMatcher.match("gro not", in: "Grocery Notes"))
        XCTAssertNil(FuzzyMatcher.match(query, in: "Ginger"))
        XCTAssertEqual(FuzzyMatcher.evaluate(FuzzyQuery("café"), in: "Cafe")?.isExact, true)
        XCTAssertEqual(FuzzyMatcher.evaluate(FuzzyQuery("caf"), in: "Cafe")?.isExact, false)
    }
}
