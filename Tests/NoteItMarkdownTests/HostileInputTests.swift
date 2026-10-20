import NoteItDoc
import XCTest
@testable import NoteItMarkdown

/// Inputs built to blow the stack or go quadratic; the bounds are loose so slow CI machines pass.
final class HostileInputTests: XCTestCase {
    private func assertParsesQuickly(_ text: String, within seconds: Double = 3, _ label: String,
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
}
