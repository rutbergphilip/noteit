import AppKit
import XCTest
@testable import NoteIt

final class PasteboardSnapshotTests: XCTestCase {
    private var pasteboards: [NSPasteboard] = []
    private let customType = NSPasteboard.PasteboardType("com.example.noteit-test.custom")

    override func tearDown() {
        for pasteboard in pasteboards {
            pasteboard.releaseGlobally()
        }
        pasteboards = []
        super.tearDown()
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("noteit-test-\(UUID())"))
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func contents(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var result: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                result[type] = item.data(forType: type)
            }
            return result
        }
    }

    func testMultiItemMultiTypeRoundTrip() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("Hello", forType: .string)
        first.setString("<b>Hello</b>", forType: .html)
        first.setData(Data([0, 1, 2, 255]), forType: customType)
        let second = NSPasteboardItem()
        second.setString("https://example.com", forType: .URL)
        second.setString("Second", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let before = contents(of: pasteboard)
        XCTAssertEqual(before.count, 2)

        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Temporary", forType: .string)

        snapshot.restore(to: pasteboard)
        let after = contents(of: pasteboard)
        XCTAssertEqual(after, before)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: customType), Data([0, 1, 2, 255]))
        XCTAssertEqual(pasteboard.pasteboardItems?.last?.string(forType: .string), "Second")
    }

    func testSnapshotIsIndependentOfLaterChanges() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("Original", forType: .string)
        let snapshot = PasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("Changed", forType: .string)
        snapshot.restore(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Original")
    }

    func testRestoreToAnotherPasteboard() {
        let source = makePasteboard()
        let target = makePasteboard()
        source.clearContents()
        source.setString("Copied", forType: .string)
        source.setData(Data("rtf".utf8), forType: .rtf)
        target.clearContents()
        target.setString("Old", forType: .string)

        PasteboardSnapshot(source).restore(to: target)
        XCTAssertEqual(contents(of: target), contents(of: source))
    }

    func testEmptySnapshotClearsPasteboard() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot(pasteboard)

        pasteboard.setString("Leftover", forType: .string)
        snapshot.restore(to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
    }
}
