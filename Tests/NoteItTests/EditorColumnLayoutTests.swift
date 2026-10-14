import XCTest
@testable import NoteIt

final class EditorColumnLayoutTests: XCTestCase {
    func testNarrowEditorUsesMinimumInset() {
        let layout = EditorColumnLayout.fitting(width: 600, maxReadingWidth: 1100, minInset: 28)
        XCTAssertEqual(layout, EditorColumnLayout(inset: 28, containerWidth: 544))
    }

    func testColumnGrowsWithEditorUntilReadingWidth() {
        let narrow = EditorColumnLayout.fitting(width: 800, maxReadingWidth: 1100, minInset: 28)
        let wider = EditorColumnLayout.fitting(width: 1000, maxReadingWidth: 1100, minInset: 28)
        XCTAssertEqual(narrow.containerWidth, 744)
        XCTAssertEqual(wider.containerWidth, 944)
        XCTAssertEqual(EditorColumnLayout.fitting(width: 1156, maxReadingWidth: 1100, minInset: 28).containerWidth, 1100)
    }

    func testWideEditorCentersReadingWidth() {
        let layout = EditorColumnLayout.fitting(width: 2000, maxReadingWidth: 1100, minInset: 28)
        XCTAssertEqual(layout, EditorColumnLayout(inset: 450, containerWidth: 1100))
    }

    func testShrinkingBackGivesTheSameColumn() {
        let before = EditorColumnLayout.fitting(width: 900, maxReadingWidth: 1100, minInset: 28)
        _ = EditorColumnLayout.fitting(width: 1800, maxReadingWidth: 1100, minInset: 28)
        XCTAssertEqual(EditorColumnLayout.fitting(width: 900, maxReadingWidth: 1100, minInset: 28), before)
    }

    func testOddWidthsKeepWholePointInsets() {
        let layout = EditorColumnLayout.fitting(width: 1201, maxReadingWidth: 1100, minInset: 28)
        XCTAssertEqual(layout.inset, 50)
        XCTAssertEqual(layout.containerWidth, 1101)
    }

    func testKeepingCentersAnUnchangedColumn() {
        let layout = EditorColumnLayout.keeping(containerWidth: 700, in: 1000, minInset: 28)
        XCTAssertEqual(layout, EditorColumnLayout(inset: 150, containerWidth: 700))
    }

    func testKeepingAColumnWiderThanTheEditorClipsItsRightEdge() {
        let layout = EditorColumnLayout.keeping(containerWidth: 900, in: 700, minInset: 28)
        XCTAssertEqual(layout, EditorColumnLayout(inset: 28, containerWidth: 900))
    }

    func testDefaultReadingWidthLeavesRoomOnCommonWindows() {
        XCTAssertGreaterThanOrEqual(EditorStyle.maxReadingWidth, 1000)
        XCTAssertEqual(EditorColumnLayout.fitting(width: 1000).containerWidth, 1000 - 2 * EditorStyle.minHorizontalInset)
    }
}
