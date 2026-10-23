@testable import NoteIt
import NoteItCore
import XCTest

final class SettingsTabTests: XCTestCase {
    func testCasesMatchFrozenOrder() {
        XCTAssertEqual(SettingsView.Tab.allCases.map(\.rawValue), URLCommand.settingsTabs)
    }

    func testAvailableTabsAreTheBuiltSix() {
        XCTAssertEqual(SettingsView.Tab.allCases.filter(\.isAvailable), [.general, .shortcuts, .editor, .sync, .integrations, .about])
    }

    func testHiddenOrUnknownStoredValueOpensGeneral() {
        XCTAssertEqual(SettingsView.Tab.resolved("plugins"), .general)
        XCTAssertEqual(SettingsView.Tab.resolved("smart"), .general)
        XCTAssertEqual(SettingsView.Tab.resolved("integrations"), .integrations)
        XCTAssertEqual(SettingsView.Tab.resolved("nonsense"), .general)
        XCTAssertEqual(SettingsView.Tab.resolved("sync"), .sync)
        XCTAssertEqual(SettingsView.Tab.plugins.availableOrGeneral, .general)
    }

    func testPlannedSymbols() {
        XCTAssertEqual(SettingsView.Tab.data.symbol, "externaldrive")
        XCTAssertEqual(SettingsView.Tab.sharing.symbol, "person.2")
        XCTAssertEqual(SettingsView.Tab.smart.symbol, "sparkles")
        XCTAssertEqual(SettingsView.Tab.integrations.symbol, "point.3.connected.trianglepath.dotted")
        XCTAssertEqual(SettingsView.Tab.plugins.symbol, "puzzlepiece.extension")
    }
}
