import NoteItDoc
import XCTest
@testable import NoteItMarkdown

/// Inputs built to blow the stack or go quadratic; the bounds are loose so slow CI machines pass, and looser still
/// on shared CI runners; a quadratic regression still blows well past either.
final class HostileInputTests: XCTestCase {
    private static let limit: TimeInterval = ProcessInfo.processInfo.environment["CI"] == nil ? 3 : 10

    private func assertParsesQuickly(_ text: String, within seconds: Double = limit, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let start = Date()
        XCTAssertNoThrow(try MarkdownCodec.parse(text), label, file: file, line: line)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, seconds, "\(label) took \(elapsed)s", file: file, line: line)
    }

    func testDeepQuoteNestingParses() throws {
        assertParsesQuickly(String(repeating: ">", count: 100_000) + " x\n", "one line of >")
        assertParsesQuickly(String(repeating: String(repeating: ">", count: 1000) + "\n", count: 100), "many lines of >")
        let quoted = try MarkdownCodec.parse(String(repeating: "> ", count: 40) + "x\n").body.doc
        guard case .doc(let blocks) = quoted, case .blockquote? = blocks.first else { return XCTFail("\(quoted)") }
    }

    func testDeepListNestingParses() {
        let nested = (0..<500).map { String(repeating: "  ", count: $0) + "- item\n" }.joined()
        assertParsesQuickly(nested, "nested bullets")
        let mixed = (0..<500).map { String(repeating: " ", count: $0 * 3) + ($0 % 2 == 0 ? "1. " : "> - ") + "x\n" }.joined()
        assertParsesQuickly(mixed, "nested lists and quotes")
    }

    // MARK: Inline scanning

    private func repeated(_ unit: String, toLength length: Int = 300_000) -> String {
        String(repeating: unit, count: length / unit.count)
    }

    func testUnmatchedEmphasisIsLinear() {
        assertParsesQuickly(repeated("*a ", toLength: 150_000) + repeated("a_ ", toLength: 150_000), "*a then a_")
        assertParsesQuickly(repeated("_a ", toLength: 150_000) + repeated("a* ", toLength: 150_000), "_a then a*")
        assertParsesQuickly(repeated("~a ", toLength: 150_000) + repeated("a~~ ", toLength: 150_000), "~ of other lengths")
        assertParsesQuickly(repeated("*a _", toLength: 150_000) + repeated("b_ c*", toLength: 150_000), "nested pairs")
    }

    func testUnclosedLinksAreLinear() {
        assertParsesQuickly(repeated("[a]("), "[a](")
        assertParsesQuickly(repeated("[a](((("), "open parens")
        assertParsesQuickly(repeated("[a](b (t"), "paren titles")
        assertParsesQuickly(repeated("[a](x) ["), "links after open brackets")
        assertParsesQuickly(repeated("![", toLength: 100_000) + repeated("](x)", toLength: 200_000), "nested images")
        assertParsesQuickly(repeated("[!", toLength: 100_000) + repeated("](x)", toLength: 200_000), "nested attachment links")
    }

    func testUnclosedWikiLinksAreLinear() {
        assertParsesQuickly(repeated("[["), "[[")
        assertParsesQuickly(repeated("[[a"), "[[a")
        assertParsesQuickly(repeated("![[a"), "![[a")
    }

    func testUnmatchedTagsAreLinear() {
        assertParsesQuickly(repeated("<u>", toLength: 150_000) + repeated("</b>", toLength: 150_000), "unmatched closers")
        assertParsesQuickly(repeated("<u><b>", toLength: 150_000) + repeated("</u>", toLength: 150_000), "nested matches")
    }

    func testOtherInlineRunsAreLinear() {
        assertParsesQuickly((1...700).map { String(repeating: "`", count: $0) + " " }.joined(), "backtick runs")
        assertParsesQuickly(repeated("(http://a|"), "bare URLs that fail")
        assertParsesQuickly("http://a" + repeated(")"), "bare URL with closing parens")
        assertParsesQuickly(repeated("a*"), "one long text run")
    }

    // MARK: Writing

    func testSaveWithManyMisplacedPreservedBlocksIsFast() throws {
        let source = (0..<2000).map { "p\($0)\n\n- a\n  - b\($0)\n" }.joined(separator: "\n")
        let previous = try MarkdownCodec.parse(source)
        guard case .doc(let blocks) = previous.body.doc else { return XCTFail() }
        let edited = blocks.filter { if case .listItem(_, 0, _, _, _, _) = $0 { false } else { true } }
        let start = Date()
        let output = MarkdownCodec.write(BodyContainer(doc: .doc(edited)), frontMatter: .empty, profile: .library,
                                         attachmentPath: { $0 }, previous: previous)
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.limit)
        XCTAssertEqual(output.fallbacks, 0)
        XCTAssertEqual(try MarkdownCodec.parse(output.text).body.doc, .doc(edited))
    }
}
