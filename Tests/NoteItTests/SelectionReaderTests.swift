import AppKit
import Carbon.HIToolbox
import XCTest
@testable import NoteIt

final class SelectionReaderTests: XCTestCase {
    func testCopyKeyIsANSICOnQWERTY() {
        let qwerty: [Int: String] = [kVK_ANSI_C: "c", kVK_ANSI_V: "v", kVK_ANSI_I: "i"]
        XCTAssertEqual(SelectionReader.copyKeyCode { qwerty[$0] }, CGKeyCode(kVK_ANSI_C))
    }

    func testCopyKeyFollowsLayoutWhoseCommandLayerMovesC() {
        let dvorak: [Int: String] = [kVK_ANSI_C: "j", kVK_ANSI_I: "c", kVK_ANSI_J: "h"]
        XCTAssertEqual(SelectionReader.copyKeyCode { dvorak[$0] }, CGKeyCode(kVK_ANSI_I))
    }

    func testCopyKeyAcceptsUppercaseC() {
        let layout: [Int: String] = [kVK_ANSI_X: "C"]
        XCTAssertEqual(SelectionReader.copyKeyCode { layout[$0] }, CGKeyCode(kVK_ANSI_X))
    }

    func testCopyKeyFallsBackToANSICWithoutLatinCommandLayer() {
        let cyrillic: [Int: String] = [kVK_ANSI_C: "с", kVK_ANSI_V: "м"]
        XCTAssertEqual(SelectionReader.copyKeyCode { cyrillic[$0] }, CGKeyCode(kVK_ANSI_C))
        XCTAssertEqual(SelectionReader.copyKeyCode { _ in nil }, CGKeyCode(kVK_ANSI_C))
    }

    func testCopyLandedOnlyWhenChangeCountMoved() {
        XCTAssertFalse(SelectionReader.copyLanded(baseline: 7, current: 7))
        XCTAssertTrue(SelectionReader.copyLanded(baseline: 7, current: 8))
        XCTAssertTrue(SelectionReader.copyLanded(baseline: 7, current: 9))
    }

    func testTextResultKeepsOriginalTextAndTreatsBlankAsEmpty() {
        XCTAssertEqual(SelectionReader.textResult("  hello\n"), .text("  hello\n"))
        XCTAssertEqual(SelectionReader.textResult(" \n\t "), .empty)
        XCTAssertEqual(SelectionReader.textResult(""), .empty)
        XCTAssertEqual(SelectionReader.textResult(nil), .empty)
    }

    func testCopiedStringPrefersPlainText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(rtf("rich"), forType: .rtf)
        pasteboard.writeObjects([item])
        XCTAssertEqual(SelectionReader.copiedString(from: pasteboard), "plain")
    }

    func testCopiedStringFallsBackToRTF() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(rtf("rich"), forType: .rtf)
        XCTAssertEqual(SelectionReader.copiedString(from: pasteboard), "rich")
    }

    func testCopiedStringIsNilWithoutText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertNil(SelectionReader.copiedString(from: pasteboard))
    }

    func testElectronDetectionLooksForTheFramework() {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        var checked: [String] = []
        XCTAssertTrue(SelectionReader.isElectronApp(bundleURL: bundle) { checked.append($0); return true })
        XCTAssertEqual(checked, ["/Applications/Example.app/Contents/Frameworks/Electron Framework.framework"])
        XCTAssertFalse(SelectionReader.isElectronApp(bundleURL: bundle) { _ in false })
        XCTAssertFalse(SelectionReader.isElectronApp(bundleURL: nil) { _ in true })
    }

    func testAnsweredSelectionIsTrustedEvenWhenEmpty() {
        XCTAssertEqual(SelectionReader.accessibilitySelection(.success("word")), .answered("word"))
        XCTAssertEqual(SelectionReader.accessibilitySelection(.success("")), .answered(""))
    }

    func testUnsupportedSelectionFallsBackToCopy() {
        for code: AXError in [.attributeUnsupported, .noValue, .notImplemented, .parameterizedAttributeUnsupported, .failure] {
            XCTAssertEqual(SelectionReader.accessibilitySelection(.failure(AXFailure(code: code))), .unsupported,
                           "AXError \(code.rawValue)")
        }
    }

    func testUnresponsiveAppNeverGetsCopy() {
        XCTAssertEqual(SelectionReader.accessibilitySelection(.failure(AXFailure(code: .cannotComplete))), .timedOut)
        for code: AXError in [.apiDisabled, .invalidUIElement, .illegalArgument, .invalidUIElementObserver] {
            XCTAssertEqual(SelectionReader.accessibilitySelection(.failure(AXFailure(code: code))), .failed,
                           "AXError \(code.rawValue)")
        }
        for browser in [false, true] {
            XCTAssertEqual(step(.timedOut, browser: browser, enabled: false), .empty)
        }
    }

    func testFreshElectronTreeThatTimesOutIsReadAgain() {
        XCTAssertEqual(step(.timedOut, browser: false, enabled: true), .retry)
    }

    func testSelectedTextIsUsedEverywhere() {
        for (browser, enabled) in [(false, false), (true, false), (false, true)] {
            XCTAssertEqual(step(.answered(" word "), browser: browser, enabled: enabled), .text(" word "))
        }
    }

    func testEmptyAnswerFallsBackToCopyOnlyInBrowsers() {
        XCTAssertEqual(step(.answered(""), browser: true, enabled: false), .copy)
        XCTAssertEqual(step(.answered("  \n"), browser: true, enabled: false), .copy)
        XCTAssertEqual(step(.answered(""), browser: false, enabled: false), .empty)
    }

    func testFreshElectronTreeIsReadAgainInsteadOfCopying() {
        XCTAssertEqual(step(.answered(""), browser: false, enabled: true), .retry)
        XCTAssertEqual(step(.unsupported, browser: false, enabled: true), .retry)
    }

    func testUnsupportedFallsBackToCopyAndFailureNeverDoes() {
        XCTAssertEqual(step(.unsupported, browser: false, enabled: false), .copy)
        XCTAssertEqual(step(.unsupported, browser: true, enabled: false), .copy)
        for (browser, enabled) in [(false, false), (true, false), (false, true)] {
            XCTAssertEqual(step(.failed, browser: browser, enabled: enabled), .empty)
        }
    }

    func testBrowserDetectionIncludesFirefox() {
        XCTAssertTrue(SelectionReader.isBrowser(bundleID: "com.apple.Safari"))
        XCTAssertTrue(SelectionReader.isBrowser(bundleID: "com.google.Chrome"))
        XCTAssertTrue(SelectionReader.isBrowser(bundleID: "org.mozilla.firefox"))
        XCTAssertTrue(SelectionReader.isBrowser(bundleID: "org.mozilla.firefoxdeveloperedition"))
        XCTAssertTrue(SelectionReader.isBrowser(bundleID: "org.mozilla.nightly"))
        XCTAssertFalse(SelectionReader.isBrowser(bundleID: "com.microsoft.VSCode"))
        XCTAssertFalse(SelectionReader.isBrowser(bundleID: nil))
    }

    func testTakeoverUndoesLandedLateCopyWhileTargetIsFrontmost() {
        XCTAssertEqual(takeover(current: 6, frontmost: 42, watched: 42, capture: 42), .restoreThenReuseSnapshot)
        XCTAssertEqual(takeover(current: 6, frontmost: 42, watched: 42, capture: 9), .restoreThenReuseSnapshot)
    }

    func testTakeoverSendsFreshCopyOnTopOfPendingOneFromTheSameApp() {
        XCTAssertEqual(takeover(current: 5, frontmost: 42, watched: 42, capture: 42), .reusePendingSnapshot)
    }

    func testTakeoverDropsPendingWatchForAnotherApp() {
        XCTAssertEqual(takeover(current: 5, frontmost: 42, watched: 42, capture: 9), .discard)
    }

    func testTakeoverDiscardsWatchOnceTheWatchedAppIsNotFrontmost() {
        XCTAssertEqual(takeover(current: 6, frontmost: 7, watched: 42, capture: 7), .discard)
        XCTAssertEqual(takeover(current: 5, frontmost: 7, watched: 42, capture: 42), .discard)
        XCTAssertEqual(takeover(current: 6, frontmost: nil, watched: 42, capture: 42), .discard)
    }

    func testLateCopyRestoresOnlyWhileTargetIsFrontmost() {
        XCTAssertEqual(SelectionReader.lateCopyStep(baseline: 3, current: 3, frontmostPID: 42, targetPID: 42), .keepWatching)
        XCTAssertEqual(SelectionReader.lateCopyStep(baseline: 3, current: 4, frontmostPID: 42, targetPID: 42), .restore)
        XCTAssertEqual(SelectionReader.lateCopyStep(baseline: 3, current: 4, frontmostPID: 7, targetPID: 42), .stop)
        XCTAssertEqual(SelectionReader.lateCopyStep(baseline: 3, current: 3, frontmostPID: 7, targetPID: 42), .stop)
        XCTAssertEqual(SelectionReader.lateCopyStep(baseline: 3, current: 4, frontmostPID: nil, targetPID: 42), .stop)
    }

    func testOnlyControlOptionAndShiftDelayTheCopy() {
        XCTAssertFalse(SelectionReader.blocksCopy([]))
        XCTAssertFalse(SelectionReader.blocksCopy([.maskCommand, .maskAlphaShift, .maskSecondaryFn]))
        XCTAssertTrue(SelectionReader.blocksCopy(.maskControl))
        XCTAssertTrue(SelectionReader.blocksCopy([.maskCommand, .maskAlternate]))
        XCTAssertTrue(SelectionReader.blocksCopy(.maskShift))
    }

    func testModifierWaitEndsWhenKeysAreReleased() async {
        let flags = FlagSequence([[.maskControl, .maskAlternate], .maskAlternate, .maskCommand])
        let released = await SelectionReader.waitForModifierRelease(timeout: .seconds(2), interval: .milliseconds(1)) {
            flags.next()
        }
        XCTAssertTrue(released)
        XCTAssertEqual(flags.reads, 3)
    }

    func testModifierWaitGivesUpAtTimeout() async {
        let flags = FlagSequence([.maskControl])
        let released = await SelectionReader.waitForModifierRelease(timeout: .milliseconds(30), interval: .milliseconds(5)) {
            flags.next()
        }
        XCTAssertFalse(released)
        XCTAssertGreaterThan(flags.reads, 1)
    }

    func testModifierWaitDoesNotWaitWhenNothingIsHeld() async {
        let flags = FlagSequence([[]])
        let released = await SelectionReader.waitForModifierRelease(timeout: .seconds(2), interval: .milliseconds(1)) {
            flags.next()
        }
        XCTAssertTrue(released)
        XCTAssertEqual(flags.reads, 1)
    }

    private func takeover(current: Int, frontmost: pid_t?, watched: pid_t,
                          capture: pid_t) -> SelectionReader.LateCopyTakeover {
        SelectionReader.lateCopyTakeover(baseline: 5, current: current, frontmostPID: frontmost,
                                         watchedPID: watched, capturePID: capture)
    }

    private func step(_ selection: SelectionReader.AXSelection, browser: Bool,
                      enabled: Bool) -> SelectionReader.SelectionStep {
        SelectionReader.selectionStep(selection, isBrowser: browser, justEnabledManualAccessibility: enabled)
    }

    private func rtf(_ string: String) -> Data {
        let attributed = NSAttributedString(string: string)
        return try! attributed.data(from: NSRange(location: 0, length: attributed.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}

/// Returns the given flags in order, repeating the last one.
private final class FlagSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [CGEventFlags]
    private var count = 0

    init(_ values: [CGEventFlags]) {
        self.values = values
    }

    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func next() -> CGEventFlags {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(count, values.count - 1)]
        count += 1
        return value
    }
}
