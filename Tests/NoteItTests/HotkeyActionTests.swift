import Foundation
@testable import NoteIt
import XCTest

final class HotkeyActionTests: XCTestCase {
    func testRawValuesUnique() {
        XCTAssertEqual(Set(HotkeyOrder.rawValues).count, HotkeyOrder.rawValues.count)
        XCTAssertEqual(HotkeyOrder.rawValues.count, 14)
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.rawValue)).count, HotkeyAction.allCases.count)
    }

    func testFirstSixUnchanged() {
        let first: [(HotkeyAction, String, UInt32)] = [
            (.showMainWindow, "showMainWindow", 1), (.newNote, "newNote", 2), (.quickCapture, "quickCapture", 3),
            (.openQuickly, "openQuickly", 4), (.commandPalette, "commandPalette", 5),
            (.captureSelection, "captureSelection", 6),
        ]
        XCTAssertEqual(Array(HotkeyAction.allCases.prefix(6)), first.map(\.0))
        for (action, raw, id) in first {
            XCTAssertEqual(action.rawValue, raw)
            XCTAssertEqual(action.hotkeyID, id, raw)
        }
    }

    func testOpenTodayIsSeventh() {
        XCTAssertEqual(HotkeyAction.openToday.rawValue, "openToday")
        XCTAssertEqual(HotkeyAction.openToday.hotkeyID, 7)
    }

    func testCasesFollowFrozenOrder() {
        var remaining = HotkeyOrder.rawValues[...]
        for action in HotkeyAction.allCases {
            guard let index = remaining.firstIndex(of: action.rawValue) else {
                return XCTFail("\(action.rawValue) is missing from HotkeyOrder or out of order")
            }
            remaining = remaining[(index + 1)...]
        }
    }

    func testHotkeyIDsComeFromTable() {
        for action in HotkeyAction.allCases {
            XCTAssertEqual(action.hotkeyID, UInt32(HotkeyOrder.rawValues.firstIndex(of: action.rawValue)! + 1))
            XCTAssertEqual(HotkeyOrder.rawValue(for: action.hotkeyID), action.rawValue)
        }
    }

    func testHotkeyIDRoundTrip() {
        for action in HotkeyAction.allCases {
            XCTAssertEqual(HotkeyAction(hotkeyID: action.hotkeyID), action)
        }
    }

    func testHotkeyIDGapsResolveToNil() {
        for id in UInt32(1)...14 {
            let raw = HotkeyOrder.rawValue(for: id)!
            if HotkeyAction(rawValue: raw) == nil {
                XCTAssertNil(HotkeyAction(hotkeyID: id), "ID \(id) (\(raw)) has no case")
            }
        }
        XCTAssertNil(HotkeyAction(hotkeyID: 0))
        XCTAssertNil(HotkeyAction(hotkeyID: 15))
        XCTAssertNil(HotkeyOrder.rawValue(for: 0))
        XCTAssertNil(HotkeyOrder.rawValue(for: 15))
    }

    @MainActor
    func testNoDefaultBindings() throws {
        let suite = "HotkeyActionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotkeyManager(defaults: defaults)
        for action in HotkeyAction.allCases {
            XCTAssertNil(manager.combo(for: action), action.rawValue)
        }
    }
}
