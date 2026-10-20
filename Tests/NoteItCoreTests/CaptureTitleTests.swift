import NoteItCore
import XCTest

final class CaptureTitleTests: XCTestCase {
    func testSkipsBlankFirstLines() {
        XCTAssertEqual(CaptureTitle.firstLine(of: "\n   \n\t\r\n  Shopping   list  \nmilk"), "Shopping list")
        XCTAssertNil(CaptureTitle.firstLine(of: " \n\u{2029}\t"))
        XCTAssertNil(CaptureTitle.singleLine("  \n "))
    }

    func testLongLineIsCutAtAWordBoundary() {
        let line = "The quick brown fox jumps over the lazy dog while the cat watches closely"
        let title = CaptureTitle.truncated(line)
        XCTAssertEqual(title, "The quick brown fox jumps over the lazy dog while the cat…")
        XCTAssertLessThanOrEqual(title.count, CaptureTitle.maxLength)
        XCTAssertEqual(CaptureTitle.truncated("Short title"), "Short title")
    }

    func testOnlyTheScanLimitIsRead() {
        let word = String(repeating: "a", count: 5_000)
        XCTAssertEqual(CaptureTitle.firstLine(of: word)?.count, CaptureTitle.scanLimit)
        let leading = String(repeating: "\n", count: 5_000) + "Title\n" + word
        XCTAssertEqual(CaptureTitle.firstLine(of: leading), "Title", "leading whitespace doesn't count toward the limit")
    }
}
