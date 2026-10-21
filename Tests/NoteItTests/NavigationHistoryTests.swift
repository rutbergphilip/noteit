import XCTest
@testable import NoteIt

final class NavigationHistoryTests: XCTestCase {
    func testHistoryLimitAndDuplicates() {
        var history = NavigationHistory()
        let a = UUID()
        history.visit(a)
        history.visit(a)
        XCTAssertFalse(history.canGoBack)
        for _ in 0..<60 { history.visit(UUID()) }
        var steps = 0
        while history.back(isValid: { _ in true }) != nil { steps += 1 }
        XCTAssertEqual(steps, NavigationHistory.limit - 1)
        XCTAssertTrue(history.canGoForward)
        let next = history.forward(isValid: { _ in true })
        XCTAssertNotNil(next)
        history.visit(UUID())
        XCTAssertFalse(history.canGoForward)
    }

    func testBackSkipsInvalid() {
        var history = NavigationHistory()
        let a = UUID(), b = UUID(), c = UUID()
        history.visit(a)
        history.visit(b)
        history.visit(c)
        XCTAssertEqual(history.back(isValid: { $0 != b }), a)
        XCTAssertEqual(history.forward(isValid: { _ in true }), c)
        XCTAssertNil(history.forward(isValid: { _ in true }))
        XCTAssertEqual(history.back(isValid: { _ in true }), a)
        XCTAssertNil(history.back(isValid: { _ in false }))
    }
}
