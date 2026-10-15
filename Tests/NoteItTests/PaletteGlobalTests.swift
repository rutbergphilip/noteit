import AppKit
import Carbon.HIToolbox
import XCTest
@testable import NoteIt
import NoteItSync

@MainActor
final class PaletteGlobalTests: XCTestCase {
    // MARK: - Hotkey toggle

    func testHotkeyOpensAClosedPaletteInItsMode() {
        XCTAssertEqual(PaletteToggle.decide(isVisible: false, currentMode: .everything, requested: .everything), .show(.everything))
        XCTAssertEqual(PaletteToggle.decide(isVisible: false, currentMode: .everything, requested: .commands), .show(.commands))
        XCTAssertEqual(PaletteToggle.decide(isVisible: false, currentMode: .commands, requested: .everything), .show(.everything))
    }

    func testHotkeyClosesThePaletteInTheSameMode() {
        XCTAssertEqual(PaletteToggle.decide(isVisible: true, currentMode: .everything, requested: .everything), .close)
        XCTAssertEqual(PaletteToggle.decide(isVisible: true, currentMode: .commands, requested: .commands), .close)
    }

    func testHotkeySwitchesThePaletteInTheOtherMode() {
        XCTAssertEqual(PaletteToggle.decide(isVisible: true, currentMode: .everything, requested: .commands), .switchTo(.commands))
        XCTAssertEqual(PaletteToggle.decide(isVisible: true, currentMode: .commands, requested: .everything), .switchTo(.everything))
    }

    func testSwitchingModeUsesTheModesQuery() {
        XCTAssertEqual(PaletteController.initialQuery(for: .commands), ">")
        XCTAssertEqual(PaletteController.initialQuery(for: .everything), "")
    }

    // MARK: - Menu shortcuts over another app

    func testMenuShortcutsOnlyCloseThePaletteOverAnotherApp() {
        XCTAssertEqual(PaletteHandOff.decide(appIsActive: true), .toMainWindow)
        XCTAssertEqual(PaletteHandOff.decide(appIsActive: false), .closeOnly)
    }

    // MARK: - Hidden NoteIt

    func testClosingWithoutAChoiceHidesNoteItAgain() {
        XCTAssertTrue(PaletteHiddenApp.shouldRehide(wasHidden: true, choseItem: false, appIsActive: false))
    }

    func testChoosingARowLeavesNoteItVisible() {
        XCTAssertFalse(PaletteHiddenApp.shouldRehide(wasHidden: true, choseItem: true, appIsActive: false))
        XCTAssertFalse(PaletteHiddenApp.shouldRehide(wasHidden: true, choseItem: true, appIsActive: true))
    }

    func testNoteItThatBecameActiveStaysVisible() {
        XCTAssertFalse(PaletteHiddenApp.shouldRehide(wasHidden: true, choseItem: false, appIsActive: true))
    }

    func testNoteItThatWasntHiddenIsLeftAlone() {
        XCTAssertFalse(PaletteHiddenApp.shouldRehide(wasHidden: false, choseItem: false, appIsActive: false))
        XCTAssertFalse(PaletteHiddenApp.shouldRehide(wasHidden: false, choseItem: true, appIsActive: false))
    }

    func testAnotherNoteItWindowTakingKeyKeepsNoteItVisible() {
        XCTAssertFalse(PaletteHiddenApp.shouldRehide(wasHidden: true, choseItem: false, appIsActive: false, otherWindowIsKey: true))
        XCTAssertFalse(PaletteHiddenApp.shouldRehide(wasHidden: true, choseItem: false, appIsActive: false, quickCaptureIsVisible: true))
    }

    func testClosingHidesNoteItAgainAndForgetsIt() {
        let env = RehideEnvironment()
        var hiddenApp = PaletteHiddenApp(wasHidden: true)
        hiddenApp.paletteClosed(env.environment)

        XCTAssertEqual(env.hideCount, 1)
        XCTAssertFalse(hiddenApp.wasHidden)

        hiddenApp.paletteClosed(env.environment)
        XCTAssertEqual(env.hideCount, 1)
    }

    func testChosenRowDoesNotHideNoteIt() {
        let env = RehideEnvironment()
        var hiddenApp = PaletteHiddenApp(wasHidden: true, closingForChosenItem: true)
        hiddenApp.paletteClosed(env.environment)

        XCTAssertEqual(env.hideCount, 0)
        XCTAssertFalse(hiddenApp.wasHidden)
    }

    func testActiveNoteItIsNotHidden() {
        let env = RehideEnvironment()
        env.appIsActive = true
        var hiddenApp = PaletteHiddenApp(wasHidden: true)
        hiddenApp.paletteClosed(env.environment)

        XCTAssertEqual(env.hideCount, 0)
        XCTAssertFalse(hiddenApp.wasHidden)
    }

    func testQuickCaptureTakingOverKeepsNoteItVisible() {
        let keyWindow = RehideEnvironment()
        keyWindow.otherWindowIsKey = true
        var first = PaletteHiddenApp(wasHidden: true)
        first.paletteClosed(keyWindow.environment)
        XCTAssertEqual(keyWindow.hideCount, 0)

        let capturing = RehideEnvironment()
        capturing.quickCaptureIsVisible = true
        var second = PaletteHiddenApp(wasHidden: true)
        second.paletteClosed(capturing.environment)
        XCTAssertEqual(capturing.hideCount, 0)
    }

    func testNoteItThatWasntHiddenIsNotQueried() {
        let env = RehideEnvironment()
        var hiddenApp = PaletteHiddenApp()
        hiddenApp.paletteClosed(env.environment)

        XCTAssertEqual(env.hideCount, 0)
        XCTAssertEqual(env.queryCount, 0)
    }

    // MARK: - Placement

    func testFrameIsCentredWithItsTopBelowTheAnchorTop() {
        let anchor = NSRect(x: 100, y: 50, width: 1000, height: 800)
        let frame = PaletteLayout.frame(in: anchor, height: 300)

        XCTAssertEqual(frame.width, PaletteLayout.width)
        XCTAssertEqual(frame.height, 300)
        XCTAssertEqual(frame.midX, anchor.midX, accuracy: 0.001)
        let expectedTop = anchor.maxY - 800 * PaletteLayout.topOffset
        XCTAssertEqual(frame.maxY, expectedTop, accuracy: 0.001)
    }

    func testPicksTheVisibleFrameOfTheScreenWithThePointer() {
        let left = (frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))
        let right = (frame: NSRect(x: 1440, y: -200, width: 2560, height: 1440), visibleFrame: NSRect(x: 1440, y: -200, width: 2560, height: 1415))
        let screens = [left, right]

        XCTAssertEqual(PaletteLayout.visibleFrame(containing: NSPoint(x: 2000, y: 0), screens: screens), right.visibleFrame)
        XCTAssertEqual(PaletteLayout.visibleFrame(containing: NSPoint(x: 10, y: 10), screens: screens), left.visibleFrame)
    }

    func testFallsBackToTheFirstScreenWhenThePointerIsOffScreen() {
        let only = (frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))

        XCTAssertEqual(PaletteLayout.visibleFrame(containing: NSPoint(x: -500, y: -500), screens: [only]), only.visibleFrame)
        XCTAssertNil(PaletteLayout.visibleFrame(containing: .zero, screens: []))
    }

    func testPanelOnASecondScreenStaysOnThatScreen() {
        let visible = NSRect(x: 1440, y: -200, width: 2560, height: 1415)
        let frame = PaletteLayout.frame(in: visible, height: PaletteLayout.height(rowCount: 10))

        XCTAssertTrue(visible.contains(frame))
    }

    // MARK: - Hotkey actions

    func testPaletteHotkeysAreAppendedSoExistingIDsKeepTheirValues() {
        XCTAssertEqual(HotkeyAction.showMainWindow.hotkeyID, 1)
        XCTAssertEqual(HotkeyAction.newNote.hotkeyID, 2)
        XCTAssertEqual(HotkeyAction.quickCapture.hotkeyID, 3)
        XCTAssertEqual(HotkeyAction.openQuickly.hotkeyID, 4)
        XCTAssertEqual(HotkeyAction.commandPalette.hotkeyID, 5)
        XCTAssertEqual(HotkeyAction(hotkeyID: 4), .openQuickly)
        XCTAssertEqual(HotkeyAction(hotkeyID: 5), .commandPalette)
    }

    func testCaptureSelectionHotkeyIsAppendedAndUnboundByDefault() throws {
        XCTAssertEqual(HotkeyAction.captureSelection.hotkeyID, 6)
        XCTAssertEqual(HotkeyAction(hotkeyID: 6), .captureSelection)
        XCTAssertEqual(HotkeyAction.allCases.last, .captureSelection)

        let suite = "noteit.capture.hotkeys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(HotkeyManager(defaults: defaults).bindings[.captureSelection])
    }

    func testPaletteHotkeysAreUnboundByDefault() throws {
        let suite = "noteit.palette.hotkeys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = HotkeyManager(defaults: defaults)
        XCTAssertNil(manager.bindings[.openQuickly])
        XCTAssertNil(manager.bindings[.commandPalette])
    }

    func testPaletteHotkeyBindingsRoundTrip() throws {
        let combo = KeyCombo(keyCode: kVK_ANSI_O, modifiers: controlKey | cmdKey)
        let bindings: [HotkeyAction: KeyCombo] = [.openQuickly: combo, .commandPalette: combo]
        XCTAssertEqual(try HotkeyManager.decode(HotkeyManager.encode(bindings)), bindings)
    }

    func testPaletteHotkeysHaveTitlesAndSymbols() {
        XCTAssertEqual(HotkeyAction.openQuickly.title, "Open Quickly")
        XCTAssertEqual(HotkeyAction.commandPalette.title, "Command Palette")
        for action in [HotkeyAction.openQuickly, .commandPalette] {
            XCTAssertFalse(action.description.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil), action.symbol)
        }
    }
}

@MainActor
private final class RehideEnvironment {
    var appIsActive = false
    var otherWindowIsKey = false
    var quickCaptureIsVisible = false
    private(set) var hideCount = 0
    private(set) var queryCount = 0

    var environment: PaletteHiddenApp.Environment {
        PaletteHiddenApp.Environment(
            appIsActive: { self.queryCount += 1; return self.appIsActive },
            otherWindowIsKey: { self.queryCount += 1; return self.otherWindowIsKey },
            quickCaptureIsVisible: { self.queryCount += 1; return self.quickCaptureIsVisible },
            hide: { self.hideCount += 1 }
        )
    }
}
