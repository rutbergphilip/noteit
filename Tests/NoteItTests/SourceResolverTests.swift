import CoreServices
import XCTest
import NoteItDocTestSupport
@testable import NoteIt

final class SourceResolverTests: XCTestCase {
    func testAppNamePrefersLocalizedName() {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        XCTAssertEqual(SourceResolver.appName(localizedName: "Example Pro", bundleURL: bundle, bundleID: "com.example"),
                       "Example Pro")
        XCTAssertEqual(SourceResolver.appName(localizedName: nil, bundleURL: bundle, bundleID: "com.example"), "Example")
        XCTAssertEqual(SourceResolver.appName(localizedName: "", bundleURL: nil, bundleID: "com.example"), "com.example")
        XCTAssertFalse(SourceResolver.appName(localizedName: nil, bundleURL: nil, bundleID: nil).isEmpty)
    }

    func testCleanTitleStripsAppSuffix() {
        XCTAssertEqual(SourceResolver.cleanTitle("Report — Google Chrome", appName: "Google Chrome"), "Report")
        XCTAssertEqual(SourceResolver.cleanTitle("Report – Preview", appName: "Preview"), "Report")
        XCTAssertEqual(SourceResolver.cleanTitle("main.swift - Code", appName: "Code"), "main.swift")
        XCTAssertEqual(SourceResolver.cleanTitle("  Notes.txt  ", appName: "TextEdit"), "Notes.txt")
        XCTAssertEqual(SourceResolver.cleanTitle("A - B - Code", appName: "Code"), "A - B")
    }

    func testCleanTitleKeepsUnrelatedDashes() {
        XCTAssertEqual(SourceResolver.cleanTitle("Q3 — Summary", appName: "Pages"), "Q3 — Summary")
        XCTAssertEqual(SourceResolver.cleanTitle("Google Chrome Help", appName: "Google Chrome"), "Google Chrome Help")
    }

    func testCleanTitleDropsEmptyOrAppOnlyTitles() {
        XCTAssertNil(SourceResolver.cleanTitle(nil, appName: "Finder"))
        XCTAssertNil(SourceResolver.cleanTitle("   ", appName: "Finder"))
        XCTAssertNil(SourceResolver.cleanTitle("Calculator", appName: "Calculator"))
        XCTAssertNil(SourceResolver.cleanTitle(" — Calculator", appName: "Calculator"))
    }

    func testDocumentURLKeepsExistingFileURLs() {
        let url = SourceResolver.documentURL(from: "file:///Users/someone/Notes%20Draft.txt") { _ in true }
        XCTAssertEqual(url?.path, "/Users/someone/Notes Draft.txt")
        XCTAssertEqual(SourceResolver.documentURL(from: "/Users/someone/a.txt") { _ in true }?.path, "/Users/someone/a.txt")
    }

    func testDocumentURLRejectsMissingRemoteOrEmptyValues() {
        XCTAssertNil(SourceResolver.documentURL(from: "file:///Users/someone/gone.txt") { _ in false })
        XCTAssertNil(SourceResolver.documentURL(from: "https://example.com/a.txt") { _ in true })
        XCTAssertNil(SourceResolver.documentURL(from: "") { _ in true })
        XCTAssertNil(SourceResolver.documentURL(from: nil) { _ in true })
    }

    func testDocumentURLChecksTheDecodedPath() {
        var checked: [String] = []
        _ = SourceResolver.documentURL(from: "file:///Users/someone/a%20b.md") { checked.append($0); return true }
        XCTAssertEqual(checked, ["/Users/someone/a b.md"])
    }

    func testPageInfoFromScriptOutput() {
        let info = BrowserPageReader.pageInfo(.init(output: "https://example.com/a\nExample Page", errorNumber: nil))
        XCTAssertEqual(info.url, URL(string: "https://example.com/a"))
        XCTAssertEqual(info.title, "Example Page")
    }

    func testPageInfoDropsTitleWithoutURL() {
        let info = BrowserPageReader.pageInfo(.init(output: "\nNew Tab", errorNumber: nil))
        XCTAssertNil(info.url)
        XCTAssertNil(info.title)
        XCTAssertNil(BrowserPageReader.pageInfo(.init(output: "", errorNumber: nil)).url)
    }

    func testPageInfoIgnoresScriptErrors() {
        for code in [-1743, -600, -1712, -1] {
            let info = BrowserPageReader.pageInfo(.init(output: "https://example.com\nTitle", errorNumber: code))
            XCTAssertNil(info.url, "error \(code)")
            XCTAssertNil(info.title, "error \(code)")
        }
    }

    func testPageInfoWithoutOutputOrTimeout() {
        let info = BrowserPageReader.pageInfo(.init(output: nil, errorNumber: nil))
        XCTAssertNil(info.url)
        XCTAssertNil(info.title)
        XCTAssertNil(BrowserPageReader.pageInfo(.timedOut).url)
    }

    func testAutomationRunsScriptOnlyWhenAllowed() {
        XCTAssertEqual(BrowserPageReader.automationDecision(noErr), .run)
    }

    func testAutomationReportsWhenConsentIsNeeded() {
        XCTAssertEqual(BrowserPageReader.automationDecision(OSStatus(errAEEventWouldRequireUserConsent)), .needsConsent)
        XCTAssertEqual(BrowserPageReader.automationDecision(-1744), .needsConsent)
    }

    func testAutomationSkipsDeniedOrMissingTargets() {
        XCTAssertEqual(BrowserPageReader.automationDecision(OSStatus(errAEEventNotPermitted)), .skip)
        XCTAssertEqual(BrowserPageReader.automationDecision(-1743), .skip)
        XCTAssertEqual(BrowserPageReader.automationDecision(OSStatus(procNotFound)), .skip)
        XCTAssertEqual(BrowserPageReader.automationDecision(-50), .skip)
    }

    func testScriptThreadReportsBusyWhileAJobIsQueuedOrRunning() async throws {
        let gate = DispatchSemaphore(value: 0)
        let job = Task { try await AppleScriptThread.shared.run { gate.wait() } }
        try await waitUntil { AppleScriptThread.shared.isBusy }
        gate.signal()
        try await job.value
        try await waitUntil { !AppleScriptThread.shared.isBusy }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(TestTiming.scaled(5))
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }

    func testReadGuardBlocksOnlyTheBrowserWithAPendingPermissionCheck() {
        XCTAssertTrue(BrowserPageReader.canStartRead(bundleID: "a", isRunning: false, permissionChecks: [],
                                                     scriptThreadBusy: false))
        XCTAssertFalse(BrowserPageReader.canStartRead(bundleID: "a", isRunning: false, permissionChecks: ["a"],
                                                      scriptThreadBusy: false))
        XCTAssertTrue(BrowserPageReader.canStartRead(bundleID: "b", isRunning: false, permissionChecks: ["a"],
                                                     scriptThreadBusy: false))
        XCTAssertFalse(BrowserPageReader.canStartRead(bundleID: "b", isRunning: true, permissionChecks: [],
                                                      scriptThreadBusy: false))
        XCTAssertFalse(BrowserPageReader.canStartRead(bundleID: "b", isRunning: false, permissionChecks: [],
                                                      scriptThreadBusy: true))
    }

    @MainActor
    func testHungPermissionCheckOnlyBlocksItsOwnBrowser() async throws {
        let gate = DispatchSemaphore(value: 0)
        let hung = fakeBrowser(permission: { _ in gate.wait(); return noErr })
        let start = ContinuousClock.now
        let first = await BrowserPageReader.read(bundleID: "test.hung", timeout: 0.05, dependencies: hung)
        XCTAssertNil(first.url)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertTrue(BrowserPageReader.isCheckingPermission(bundleID: "test.hung"))

        let counter = CallCounter()
        let again = await BrowserPageReader.read(bundleID: "test.hung", timeout: 0.5,
                                                 dependencies: fakeBrowser(permission: { _ in counter.hit(); return noErr }))
        XCTAssertNil(again.url)
        XCTAssertEqual(counter.count, 0)

        let other = await BrowserPageReader.read(bundleID: "test.other", timeout: 1, dependencies: fakeBrowser())
        XCTAssertEqual(other.url, URL(string: "https://example.com/page"))

        gate.signal()
        try await waitUntil { !BrowserPageReader.isCheckingPermission(bundleID: "test.hung") }
        let recovered = await BrowserPageReader.read(bundleID: "test.hung", timeout: 1, dependencies: fakeBrowser())
        XCTAssertEqual(recovered.url, URL(string: "https://example.com/page"))
    }

    @MainActor
    func testGivingUpOnASlowScriptFreesTheReader() async {
        let slow = fakeBrowser(runScript: { _ in
            try? await Task.sleep(for: .seconds(TestTiming.scaled(1)))
            return BrowserPageReader.ScriptOutcome(output: "https://example.com/late\nLate", errorNumber: nil)
        })
        let start = ContinuousClock.now
        let first = await BrowserPageReader.read(bundleID: "test.slow", timeout: 0.05, dependencies: slow)
        XCTAssertNil(first.url)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(TestTiming.scaled(0.8)))

        let next = await BrowserPageReader.read(bundleID: "test.slow", timeout: TestTiming.scaled(1), dependencies: fakeBrowser())
        XCTAssertEqual(next.url, URL(string: "https://example.com/page"))
    }

    @MainActor
    func testReadSkipsWithoutPermissionAndNeverPrompts() async {
        for status in [OSStatus(errAEEventWouldRequireUserConsent), OSStatus(errAEEventNotPermitted), OSStatus(procNotFound)] {
            let counter = CallCounter()
            let page = await BrowserPageReader.read(bundleID: "test.denied", timeout: 1, dependencies: fakeBrowser(
                permission: { _ in status },
                runScript: { _ in counter.hit(); return .timedOut }))
            XCTAssertNil(page.url)
            XCTAssertEqual(counter.count, 0)
            XCTAssertFalse(BrowserPageReader.isRequestingConsent(bundleID: "test.denied"))
        }
    }

    @MainActor
    func testReadSkipsWhileScriptThreadIsBusy() async {
        var busy = fakeBrowser()
        busy.scriptThreadBusy = { true }
        let page = await BrowserPageReader.read(bundleID: "test.busy", timeout: 1, dependencies: busy)
        XCTAssertNil(page.url)
    }

    @MainActor
    func testConsentRequestIsDedupedAndClearedWhenAnswered() async throws {
        let gate = DispatchSemaphore(value: 0)
        let counter = CallCounter()
        let prompt: @Sendable (String) -> OSStatus = { _ in counter.hit(); gate.wait(); return noErr }
        BrowserPageReader.requestConsentIfNeeded(bundleID: "com.apple.Safari", prompt: prompt)
        BrowserPageReader.requestConsentIfNeeded(bundleID: "com.apple.Safari", prompt: prompt)
        XCTAssertTrue(BrowserPageReader.isRequestingConsent(bundleID: "com.apple.Safari"))
        try await waitUntil { counter.count == 1 }
        gate.signal()
        try await waitUntil { !BrowserPageReader.isRequestingConsent(bundleID: "com.apple.Safari") }
        XCTAssertEqual(counter.count, 1)
    }

    @MainActor
    func testConsentRequestIgnoresUnsupportedApps() async throws {
        let counter = CallCounter()
        BrowserPageReader.requestConsentIfNeeded(bundleID: "com.example.editor") { _ in counter.hit(); return noErr }
        XCTAssertFalse(BrowserPageReader.isRequestingConsent(bundleID: "com.example.editor"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(counter.count, 0)
    }

    private func fakeBrowser(
        permission: @escaping @Sendable (String) -> OSStatus = { _ in noErr },
        runScript: @escaping @Sendable (String) async -> BrowserPageReader.ScriptOutcome = { _ in
            BrowserPageReader.ScriptOutcome(output: "https://example.com/page\nPage", errorNumber: nil)
        }
    ) -> BrowserPageReader.Dependencies {
        BrowserPageReader.Dependencies(script: { _ in "script" }, scriptThreadBusy: { false },
                                       permission: permission, runScript: runScript)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func hit() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
