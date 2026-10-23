import NoteItCore
import XCTest

final class TokenGrammarTests: XCTestCase {
    func testVectorTags() throws {
        for vector in try OrganiseVectors.section("tags") {
            let input = try XCTUnwrap(vector["input"] as? String)
            XCTAssertEqual(TokenGrammar.tags(inMasked: input), vector["tags"] as? [String], input)
        }
    }

    func testVectorTokens() throws {
        for vector in try OrganiseVectors.section("tokens") {
            let input = try XCTUnwrap(vector["input"] as? String)
            let expected = try XCTUnwrap(vector["tokens"] as? [[String: Any]])
            let tokens = TokenGrammar.tokens(inMasked: input)
            XCTAssertEqual(tokens.count, expected.count, input)
            for (token, want) in zip(tokens, expected) {
                XCTAssertEqual(token.range, NSRange(location: want["start"] as! Int, length: want["length"] as! Int), input)
                let value = want["value"] as! String
                switch want["kind"] as! String {
                case "tag": XCTAssertEqual(token.kind, .tag(value))
                case "due": XCTAssertEqual(token.kind, .due(LocalDateTime(token: value)!))
                default: XCTAssertEqual(token.kind, .remind(LocalDateTime(token: value)!, done: want["done"] as! Bool))
                }
            }
        }
    }

    func testNestedTag() {
        XCTAssertEqual(TokenGrammar.tags(inMasked: "see #Work/Acme"), ["work/acme"])
    }

    func testTagDepthCapsAtFive() {
        XCTAssertEqual(TokenGrammar.tags(inMasked: "#a/b/c/d/e/f/g"), ["a/b/c/d/e"])
        XCTAssertFalse(TokenGrammar.isValidTagName("a/b/c/d/e/f"))
        XCTAssertTrue(TokenGrammar.isValidTagName("a/b/c/d/e"))
    }

    func testTrailingSlashNotInTag() {
        let tokens = TokenGrammar.tokens(inMasked: "#work/ next")
        XCTAssertEqual(tokens, [TextToken(kind: .tag("work"), range: NSRange(location: 0, length: 5))])
    }

    func testOldBoundaryRulesStillHold() {
        let cases: [(String, [String])] = [
            ("#swift", ["swift"]), ("a #b c", ["b"]), ("x#y", []), ("?q=#swift", []), ("site.com/#anchor", []),
            ("(#p)", ["p"]), ("«#q»", ["q"]), ("“#r”", ["r"]), ("a,#s", ["s"]), ("a;#t", ["t"]), ("'#u'", ["u"]),
            ("#1abc", []), ("#ÅÄÖ", ["åäö"]), ("#tag-name_2", ["tag-name_2"]), ("#e\u{301}te", ["\u{e9}te"]),
            ("\n#line", ["line"]), ("\t#tab", ["tab"]), ("#a #a #A", ["a"]),
        ]
        for (input, tags) in cases { XCTAssertEqual(TokenGrammar.tags(inMasked: input), tags, input) }
    }

    func testDueAndRemindTokens() {
        let tokens = TokenGrammar.tokens(inMasked: "Pay @due(2026-10-21) @remind(2026-10-20 09:00 done)")
        XCTAssertEqual(tokens.map(\.kind), [
            .due(LocalDateTime(year: 2026, month: 10, day: 21)!),
            .remind(LocalDateTime(year: 2026, month: 10, day: 20, hour: 9, minute: 0)!, done: true),
        ])
    }

    func testInvalidDateNotAToken() {
        XCTAssertTrue(TokenGrammar.tokens(inMasked: "@due(2026-02-30) @due(2026-13-01) @remind(2026-10-20 25:00)").isEmpty)
        XCTAssertNotNil(LocalDateTime(token: "2028-02-29"))
        XCTAssertNil(LocalDateTime(token: "2027-02-29"))
    }

    func testLocalDateTimeCodableAndOrder() throws {
        let value = try XCTUnwrap(LocalDateTime(token: "2026-10-21 14:05"))
        let data = try JSONEncoder().encode([value])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["2026-10-21 14:05"]"#)
        XCTAssertEqual(try JSONDecoder().decode([LocalDateTime].self, from: data), [value])
        XCTAssertLessThan(LocalDateTime(token: "2026-10-21")!, value)
        XCTAssertLessThan(value, LocalDateTime(token: "2026-10-22")!)
    }
}
