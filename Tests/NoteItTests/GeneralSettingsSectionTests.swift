@testable import NoteIt
import XCTest

final class GeneralSettingsSectionTests: XCTestCase {
    func testFrozenOrder() {
        XCTAssertEqual(GeneralSettingsSection.allCases.map(\.rawValue),
                       ["appearance", "startup", "capture", "emailIn", "reminders", "cheatSheet", "updates"])
    }

    func testAvailableSections() {
        XCTAssertEqual(GeneralSettingsSection.allCases.filter(\.isAvailable), [.appearance, .startup, .capture, .reminders, .updates])
    }

    func testCheatSheetAfterRemindersAndBeforeUpdates() throws {
        let cases = GeneralSettingsSection.allCases
        let cheatSheet = try XCTUnwrap(cases.firstIndex(of: .cheatSheet))
        XCTAssertLessThan(try XCTUnwrap(cases.firstIndex(of: .reminders)), cheatSheet)
        XCTAssertEqual(cases.firstIndex(of: .updates), cheatSheet + 1)
    }

    /// Recorded from the General tab before it became a section list.
    func testExistingRowsKeepOrder() {
        let rows = GeneralSettingsSection.allCases.filter(\.isAvailable).flatMap(\.rowLabels)
        XCTAssertEqual(rows, [
            "Show NoteIt in", "Show menu bar icon",
            "Launch at login",
            "Read selected text", "Include page links from browsers",
            "Show reminders on this Mac", "Default time",
            "Check for Updates Automatically",
        ])
    }

    func testDefaultSizeNotSmaller() {
        XCTAssertGreaterThanOrEqual(GeneralSettingsLayout.idealHeight(updatesEnabled: false), 540)
        XCTAssertGreaterThanOrEqual(GeneralSettingsLayout.idealHeight(updatesEnabled: true), 620)
    }

    func testMinimumAllowsScrolling() {
        XCTAssertGreaterThan(GeneralSettingsLayout.minHeight, 0)
        for updates in [false, true] {
            XCTAssertLessThan(GeneralSettingsLayout.minHeight, GeneralSettingsLayout.idealHeight(updatesEnabled: updates))
        }
    }
}
