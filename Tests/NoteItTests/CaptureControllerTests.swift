import AppKit
import XCTest
@testable import NoteIt

@MainActor
final class CaptureControllerTests: XCTestCase {
    private var base: URL!
    private var store: NoteStore!
    private var defaults: UserDefaults!
    private var suiteName = ""

    private var selection: SelectionReadResult = .text("Hello from somewhere")
    private var source = CaptureSource(appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "Example",
                                       pageURL: URL(string: "https://example.com/page"), pageTitle: "Example Page",
                                       documentURL: nil)
    private var clipboard: String?
    private var frontmostIsNoteIt = false
    private var trusted = true
    private var readCount = 0
    private var resolvedWithLinks: [Bool] = []
    private var toasts: [CaptureToastContent] = []
    private var toastHandlers: [(CaptureToastEvent) -> Void] = []
    private var accessRequests = 0
    private var openedNotes: [UUID] = []
    private var consentRequests: [String] = []
    private var readGate: CheckedContinuation<Void, Never>?
    private var holdsReads = false

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("noteit-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = NoteStore(location: LibraryLocation(url: base.appendingPathComponent("lib", isDirectory: true), seedsFreshLibrary: false))
        suiteName = "noteit.capture.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    private func makeController() -> CaptureController {
        CaptureController(environment: CaptureController.Environment(
            frontmostApplication: { NSRunningApplication.current },
            isNoteIt: { [unowned self] _ in self.frontmostIsNoteIt },
            isTrusted: { [unowned self] in self.trusted },
            readSelection: { [unowned self] _ in
                self.readCount += 1
                if self.holdsReads {
                    await withCheckedContinuation { self.readGate = $0 }
                }
                return self.selection
            },
            resolveSource: { [unowned self] _, includeLinks in
                self.resolvedWithLinks.append(includeLinks)
                return self.source
            },
            clipboardText: { [unowned self] in self.clipboard },
            store: { [unowned self] in self.store },
            defaults: defaults,
            showToast: { [unowned self] content, handler in
                self.toasts.append(content)
                self.toastHandlers.append(handler)
            },
            requestAccess: { [unowned self] in self.accessRequests += 1 },
            openNote: { [unowned self] id in self.openedNotes.append(id) },
            requestBrowserConsent: { [unowned self] in self.consentRequests.append($0) }
        ))
    }

    private func waitForToasts(_ count: Int) async {
        for _ in 0..<200 where toasts.count < count { await Task.yield() }
    }

    // MARK: - Selected text

    func testSelectedTextIsSavedToTheNotebookForNewNotes() async throws {
        let inbox = store.createNotebook(name: "Inbox", symbol: "tray", colorHex: Tokens.Hex.notebookBlue)
        let controller = makeController()

        let outcome = await controller.capture(from: .current)

        guard case let .saved(noteID, notebookName, title)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        let note = try XCTUnwrap(store.note(with: noteID))
        let expected = CaptureFormatter.noteContent(for: CapturedSelection(text: "Hello from somewhere", source: source))
        XCTAssertEqual(note.notebookID, inbox.id)
        XCTAssertEqual(notebookName, "Inbox")
        XCTAssertEqual(title, note.title)
        XCTAssertFalse(note.title.isEmpty)
        XCTAssertEqual(store.body(for: noteID).string, expected.string)
        XCTAssertNil(store.selectedNoteID)
        XCTAssertTrue(openedNotes.isEmpty)
        XCTAssertEqual(toasts, [CaptureToastContent(symbol: "checkmark", tone: .success, title: "Saved to Inbox",
                                                    message: note.title, opensNoteOnClick: true)])
        XCTAssertFalse(controller.isCapturing)
    }

    func testClickingTheSavedNoticeOpensTheNote() async throws {
        let controller = makeController()
        let outcome = await controller.capture(from: .current)
        guard case let .saved(noteID, _, _)? = outcome else { return XCTFail("not saved") }

        toastHandlers.last?(.body)

        XCTAssertEqual(openedNotes, [noteID])
    }

    func testEmptyAndBlankSelectionsSaveNothing() async {
        let controller = makeController()
        for result in [SelectionReadResult.empty, .text("  \n\t ")] {
            selection = result
            let outcome = await controller.capture(from: .current)
            XCTAssertEqual(outcome, .nothingSelected)
        }
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(toasts.map(\.title), ["Nothing selected", "Nothing selected"])
        XCTAssertTrue(toasts.allSatisfy { $0.buttons.isEmpty })
    }

    // MARK: - Without Accessibility

    func testNotTrustedShowsTheNoticeWithoutReadingOrResolving() async {
        trusted = false
        let controller = makeController()

        let outcome = await controller.capture(from: .current)

        XCTAssertEqual(outcome, .notTrusted)
        XCTAssertEqual(readCount, 0)
        XCTAssertTrue(resolvedWithLinks.isEmpty)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(toasts.last?.title, "Allow NoteIt to read selected text")
        XCTAssertEqual(toasts.last?.buttons, [.captureClipboard, .allowAccess])
        XCTAssertEqual(CaptureToastButton.allowAccess.title, "Allow Access…")
        XCTAssertFalse(controller.isCapturing)

        toastHandlers.last?(.button(.allowAccess))
        XCTAssertEqual(accessRequests, 1)
        XCTAssertTrue(resolvedWithLinks.isEmpty)
    }

    func testReaderReportingNotTrustedShowsTheSameNotice() async {
        selection = .notTrusted
        let controller = makeController()

        let outcome = await controller.capture(from: .current)

        XCTAssertEqual(outcome, .notTrusted)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(toasts.map(\.title), ["Allow NoteIt to read selected text"])
    }

    func testCaptureClipboardResolvesTheSourceOnlyThen() async throws {
        trusted = false
        clipboard = "Copied earlier"
        defaults.set(false, forKey: PrefKey.captureIncludesBrowserLinks)
        let controller = makeController()
        await controller.capture(from: .current)
        XCTAssertTrue(resolvedWithLinks.isEmpty)

        toastHandlers.last?(.button(.captureClipboard))
        await waitForToasts(3)

        XCTAssertEqual(resolvedWithLinks, [false])
        let note = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(store.notes.count, 1)
        let expected = CaptureFormatter.noteContent(for: CapturedSelection(text: "Copied earlier", source: source))
        XCTAssertEqual(store.body(for: note.id).string, expected.string)
        XCTAssertEqual(toasts.last?.title, "Saved to NoteIt")
        XCTAssertEqual(toasts.last?.message, note.title)
    }

    func testCaptureClipboardWithoutTextSaysSo() async {
        trusted = false
        let controller = makeController()
        await controller.capture(from: .current)

        for text in [nil, " \n"] as [String?] {
            clipboard = text
            toastHandlers[0](.button(.captureClipboard))
            await waitForToasts(toasts.count + 1)
        }

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(resolvedWithLinks.isEmpty)
        XCTAssertEqual(toasts.dropFirst().map(\.title), ["Nothing on the clipboard", "Nothing on the clipboard"])
    }

    func testCaptureClipboardShowsSavingUntilTheResultReplacesIt() async {
        trusted = false
        clipboard = "Copied earlier"
        let controller = makeController()
        await controller.capture(from: .current)

        let task = controller.captureClipboard(from: .current)

        XCTAssertEqual(toasts.map(\.title), ["Allow NoteIt to read selected text", "Saving…"])
        XCTAssertTrue(toasts[1].isPending)
        XCTAssertTrue(toasts[1].buttons.isEmpty)
        XCTAssertTrue(controller.isCapturing)
        let outcome = await task?.value
        guard case .saved? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(toasts.last?.title, "Saved to NoteIt")
        XCTAssertFalse(controller.isCapturing)
    }

    func testCaptureClipboardIsIgnoredWhileACaptureIsRunning() async {
        holdsReads = true
        clipboard = "Copied earlier"
        let controller = makeController()
        controller.captureSelection()
        for _ in 0..<100 where readGate == nil { await Task.yield() }

        XCTAssertNil(controller.captureClipboard(from: .current))
        XCTAssertTrue(toasts.isEmpty)
        XCTAssertTrue(resolvedWithLinks.count <= 1)

        readGate?.resume()
        for _ in 0..<100 where controller.isCapturing { await Task.yield() }
        XCTAssertEqual(store.notes.count, 1)
    }

    // MARK: - Browser permission

    func testBrowserPermissionIsAskedForOnlyAfterASave() async {
        let controller = makeController()
        await controller.capture(from: .current)
        XCTAssertEqual(consentRequests, ["com.apple.Safari"])

        selection = .empty
        await controller.capture(from: .current)
        selection = .notTrusted
        await controller.capture(from: .current)
        trusted = false
        await controller.capture(from: .current)
        await controller.captureServiceText("  ", from: .current)
        clipboard = nil
        await controller.captureClipboard(from: .current)?.value

        XCTAssertEqual(consentRequests, ["com.apple.Safari"])
    }

    func testServiceAndClipboardSavesAskForBrowserPermission() async {
        trusted = false
        clipboard = "Copied earlier"
        let controller = makeController()
        await controller.captureServiceText("From a service", from: .current)
        await controller.captureClipboard(from: .current)?.value

        XCTAssertEqual(store.notes.count, 2)
        XCTAssertEqual(consentRequests, ["com.apple.Safari", "com.apple.Safari"])
    }

    func testBrowserPermissionIsNotAskedForWithLinksOffOrWithoutABrowser() async {
        defaults.set(false, forKey: PrefKey.captureIncludesBrowserLinks)
        let controller = makeController()
        await controller.capture(from: .current)
        defaults.set(true, forKey: PrefKey.captureIncludesBrowserLinks)
        source.bundleID = nil
        await controller.capture(from: .current)

        XCTAssertEqual(store.notes.count, 2)
        XCTAssertTrue(consentRequests.isEmpty)
    }

    // MARK: - Hotkey

    func testSecondPressWhileCapturingIsIgnored() async {
        holdsReads = true
        let controller = makeController()

        controller.captureSelection()
        for _ in 0..<100 where readGate == nil { await Task.yield() }
        XCTAssertTrue(controller.isCapturing)
        controller.captureSelection()
        let ignored = await controller.capture(from: .current)
        XCTAssertNil(ignored)
        XCTAssertEqual(readCount, 1)

        readGate?.resume()
        for _ in 0..<100 where controller.isCapturing { await Task.yield() }
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(toasts.count, 1)
    }

    func testPressingTheHotkeyInNoteItItselfOnlyShowsAHint() {
        frontmostIsNoteIt = true
        let controller = makeController()

        controller.captureSelection()

        XCTAssertEqual(readCount, 0)
        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(toasts.map(\.title), ["Select text in another app"])
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testBrowserLinksPreferenceDefaultsToOn() async {
        let controller = makeController()
        await controller.capture(from: .current)
        defaults.set(false, forKey: PrefKey.captureIncludesBrowserLinks)
        await controller.capture(from: .current)

        XCTAssertEqual(resolvedWithLinks, [true, false])
    }

    // MARK: - Service

    func testServiceSavesTheTextWithTheCallingAppAsSource() async throws {
        let controller = makeController()

        let outcome = await controller.captureServiceText("From a service", from: .current)

        guard case let .saved(noteID, _, _) = outcome else { return XCTFail("not saved") }
        let expected = CaptureFormatter.noteContent(for: CapturedSelection(text: "From a service", source: source))
        XCTAssertEqual(store.body(for: noteID).string, expected.string)
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(toasts.first?.tone, .success)
    }

    func testServiceWithoutTextSavesNothing() async {
        let controller = makeController()

        let outcome = await controller.captureServiceText(nil, from: .current)

        XCTAssertEqual(outcome, .nothingSelected)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(toasts.map(\.title), ["Nothing selected"])
    }

    // MARK: - Notice

    func testNoticeSitsInTheTopRightCornerOfTheVisibleFrame() {
        let visible = NSRect(x: 1440, y: -200, width: 2560, height: 1415)
        let size = NSSize(width: Tokens.Size.toastWidth, height: 64)

        let frame = CaptureToastController.frame(for: size, in: visible)

        XCTAssertEqual(frame.maxX, visible.maxX - CaptureToastController.margin)
        XCTAssertEqual(frame.maxY, visible.maxY - CaptureToastController.margin)
        XCTAssertEqual(frame.size, size)
        XCTAssertTrue(visible.contains(frame))
    }

    func testOnlyClickingASavedNoticeOpensNoteIt() {
        let saved = CaptureToastContent(.saved(noteID: UUID(), notebookName: nil, title: "A"))
        let notTrusted = CaptureToastContent(.notTrusted)
        XCTAssertTrue(saved.opensNoteIt(on: .body))
        XCTAssertFalse(notTrusted.opensNoteIt(on: .body))
        XCTAssertFalse(notTrusted.opensNoteIt(on: .button(.captureClipboard)))
        XCTAssertFalse(notTrusted.opensNoteIt(on: .button(.allowAccess)))
    }

    // MARK: - Clicks on a notice

    func testANoticeTakesOnlyItsFirstClick() {
        let hider = TransientSurfaceHider(environment: HiddenAppProbe().environment)
        var lifecycle = CaptureToastLifecycle()
        let notTrusted = CaptureToastContent(.notTrusted)
        let shown = lifecycle.willShow(notTrusted, appIsHidden: false, hider: hider)

        XCTAssertTrue(lifecycle.accept(.button(.captureClipboard), on: notTrusted, shown: shown, hider: hider))
        XCTAssertFalse(lifecycle.accept(.button(.captureClipboard), on: notTrusted, shown: shown, hider: hider))
        XCTAssertFalse(lifecycle.accept(.button(.allowAccess), on: notTrusted, shown: shown, hider: hider))
    }

    func testClosingOrReplacedNoticesIgnoreClicks() {
        let hider = TransientSurfaceHider(environment: HiddenAppProbe().environment)
        var lifecycle = CaptureToastLifecycle()
        let notTrusted = CaptureToastContent(.notTrusted)
        let first = lifecycle.willShow(notTrusted, appIsHidden: false, hider: hider)
        lifecycle.willDismiss()
        XCTAssertFalse(lifecycle.accept(.button(.captureClipboard), on: notTrusted, shown: first, hider: hider))

        let second = lifecycle.willShow(notTrusted, appIsHidden: false, hider: hider)
        XCTAssertFalse(lifecycle.accept(.button(.captureClipboard), on: notTrusted, shown: first, hider: hider))
        XCTAssertTrue(lifecycle.accept(.button(.captureClipboard), on: notTrusted, shown: second, hider: hider))

        let saving = lifecycle.willShow(.saving, appIsHidden: false, hider: hider)
        XCTAssertFalse(lifecycle.accept(.body, on: .saving, shown: saving, hider: hider))
    }

    // MARK: - NoteIt hidden with ⌘H

    func testNoticeHidesNoteItAgainAfterItCloses() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let shown = lifecycle.willShow(CaptureToastContent(.nothingSelected), appIsHidden: true, hider: hider)
        lifecycle.didClose(shown, hider: hider)
        XCTAssertEqual(env.hideCount, 1)

        lifecycle.didClose(shown, hider: hider)
        XCTAssertEqual(env.hideCount, 1)
    }

    func testCaptureClipboardKeepsOneSessionUntilTheResultCloses() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let notTrusted = CaptureToastContent(.notTrusted)
        let first = lifecycle.willShow(notTrusted, appIsHidden: true, hider: hider)
        XCTAssertTrue(lifecycle.accept(.button(.captureClipboard), on: notTrusted, shown: first, hider: hider))
        let saving = lifecycle.willShow(.saving, appIsHidden: false, hider: hider)
        lifecycle.didClose(first, hider: hider)
        let saved = CaptureToastContent(.saved(noteID: UUID(), notebookName: "Inbox", title: "A"))
        let result = lifecycle.willShow(saved, appIsHidden: false, hider: hider)
        lifecycle.didClose(saving, hider: hider)
        XCTAssertEqual(env.hideCount, 0)

        lifecycle.didClose(result, hider: hider)
        XCTAssertEqual(env.hideCount, 1)
    }

    func testOpeningTheNoteKeepsNoteItShown() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let saved = CaptureToastContent(.saved(noteID: UUID(), notebookName: "Inbox", title: "A"))
        let shown = lifecycle.willShow(saved, appIsHidden: true, hider: hider)
        XCTAssertTrue(lifecycle.accept(.body, on: saved, shown: shown, hider: hider))
        lifecycle.didClose(shown, hider: hider)
        XCTAssertEqual(env.hideCount, 0)

        let next = lifecycle.willShow(saved, appIsHidden: true, hider: hider)
        lifecycle.didClose(next, hider: hider)
        XCTAssertEqual(env.hideCount, 1)
    }

    func testReplacementNoticeKeepsTheOriginalHiddenState() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let content = CaptureToastContent(.nothingSelected)
        let first = lifecycle.willShow(content, appIsHidden: true, hider: hider)
        let second = lifecycle.willShow(content, appIsHidden: false, hider: hider)
        lifecycle.didClose(first, hider: hider)
        XCTAssertEqual(env.hideCount, 0)
        lifecycle.didClose(second, hider: hider)

        XCTAssertEqual(env.hideCount, 1)
    }

    func testVisibleOrActiveNoteItIsLeftAlone() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let content = CaptureToastContent(.nothingSelected)
        lifecycle.didClose(lifecycle.willShow(content, appIsHidden: false, hider: hider), hider: hider)
        XCTAssertEqual(env.hideCount, 0)

        env.appIsActive = true
        lifecycle.didClose(lifecycle.willShow(content, appIsHidden: true, hider: hider), hider: hider)
        XCTAssertEqual(env.hideCount, 0)
    }

    // MARK: - Notices and the global palette

    func testPaletteOpenedDuringANoticeHidesNoteItOnlyAfterBothClose() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let shown = lifecycle.willShow(CaptureToastContent(.nothingSelected), appIsHidden: true, hider: hider)
        hider.surfaceWillAppear(.palette, appIsHidden: false)

        lifecycle.didClose(shown, hider: hider)
        XCTAssertEqual(env.hideCount, 0)
        hider.surfaceDidClose(.palette)
        XCTAssertEqual(env.hideCount, 1)
    }

    func testNoticeShownDuringThePaletteOutlivesIt() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        hider.surfaceWillAppear(.palette, appIsHidden: true)
        let shown = lifecycle.willShow(CaptureToastContent(.nothingSelected), appIsHidden: false, hider: hider)

        hider.surfaceDidClose(.palette)
        XCTAssertEqual(env.hideCount, 0)
        XCTAssertTrue(lifecycle.isPresented)
        lifecycle.didClose(shown, hider: hider)
        XCTAssertEqual(env.hideCount, 1)
    }

    func testOpeningTheNoteFromANoticeEndsTheSessionWithoutHiding() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let saved = CaptureToastContent(.saved(noteID: UUID(), notebookName: "Inbox", title: "A"))
        let shown = lifecycle.willShow(saved, appIsHidden: true, hider: hider)
        hider.surfaceWillAppear(.palette, appIsHidden: false)
        XCTAssertTrue(lifecycle.accept(.body, on: saved, shown: shown, hider: hider))
        lifecycle.didClose(shown, hider: hider)
        hider.surfaceDidClose(.palette)

        XCTAssertEqual(env.hideCount, 0)
    }

    func testChoosingAPaletteRowKeepsNoteItShownAfterTheNoticeCloses() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let shown = lifecycle.willShow(CaptureToastContent(.nothingSelected), appIsHidden: true, hider: hider)
        hider.surfaceWillAppear(.palette, appIsHidden: false)
        hider.surfaceOpenedNoteIt()
        hider.surfaceDidClose(.palette)
        lifecycle.didClose(shown, hider: hider)

        XCTAssertEqual(env.hideCount, 0)
    }

    func testHidingNoteItEndsTheSessionWithoutLeavingStaleState() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        var lifecycle = CaptureToastLifecycle()
        let content = CaptureToastContent(.nothingSelected)
        let shown = lifecycle.willShow(content, appIsHidden: true, hider: hider)
        hider.appDidHide()
        lifecycle.didClose(shown, hider: hider)
        XCTAssertFalse(lifecycle.isPresented)
        XCTAssertTrue(hider.openSurfaces.isEmpty)

        lifecycle.didClose(lifecycle.willShow(content, appIsHidden: false, hider: hider), hider: hider)
        XCTAssertEqual(env.hideCount, 0)
    }

    func testActivatingNoteItDuringASessionKeepsItShown() {
        let env = HiddenAppProbe()
        let notifications = NotificationCenter()
        var deferred: [@MainActor () -> Void] = []
        let hider = TransientSurfaceHider(environment: env.environment, notifications: notifications,
                                          nextTurn: { deferred.append($0) })
        hider.surfaceWillAppear(.captureToast, appIsHidden: true)
        env.appIsActive = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        deferred.forEach { $0() }
        env.appIsActive = false
        hider.surfaceDidClose(.captureToast)
        XCTAssertEqual(env.hideCount, 0)

        deferred.removeAll()
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(deferred.isEmpty)
        hider.surfaceWillAppear(.palette, appIsHidden: true)
        hider.surfaceDidClose(.palette)
        XCTAssertEqual(env.hideCount, 1)
    }

    func testABriefActivationDoesNotEndTheSession() {
        let env = HiddenAppProbe()
        let notifications = NotificationCenter()
        var deferred: [@MainActor () -> Void] = []
        let hider = TransientSurfaceHider(environment: env.environment, notifications: notifications,
                                          nextTurn: { deferred.append($0) })
        hider.surfaceWillAppear(.captureToast, appIsHidden: true)
        env.appIsActive = true
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        env.appIsActive = false
        deferred.forEach { $0() }
        hider.surfaceDidClose(.captureToast)

        XCTAssertEqual(env.hideCount, 1)
    }

    func testAnActivationCheckedAfterItsSessionEndedIsIgnored() {
        let env = HiddenAppProbe()
        let notifications = NotificationCenter()
        var deferred: [@MainActor () -> Void] = []
        let hider = TransientSurfaceHider(environment: env.environment, notifications: notifications,
                                          nextTurn: { deferred.append($0) })
        hider.surfaceWillAppear(.captureToast, appIsHidden: false)
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        hider.surfaceDidClose(.captureToast)
        hider.surfaceWillAppear(.palette, appIsHidden: true)
        env.appIsActive = true
        deferred.forEach { $0() }
        env.appIsActive = false
        hider.surfaceDidClose(.palette)

        XCTAssertEqual(env.hideCount, 1)
    }

    func testHidingNoteItIsObserved() {
        let env = HiddenAppProbe()
        let notifications = NotificationCenter()
        let hider = TransientSurfaceHider(environment: env.environment, notifications: notifications)
        hider.surfaceWillAppear(.palette, appIsHidden: true)
        notifications.post(name: NSApplication.didHideNotification, object: nil)

        XCTAssertTrue(hider.openSurfaces.isEmpty)
        hider.surfaceDidClose(.palette)
        XCTAssertEqual(env.hideCount, 0)
    }

    func testOpeningNoteItWithNoPanelUpDoesNotCarryOver() {
        let env = HiddenAppProbe()
        let hider = TransientSurfaceHider(environment: env.environment)
        hider.surfaceOpenedNoteIt()
        hider.surfaceWillAppear(.palette, appIsHidden: true)
        hider.surfaceDidClose(.palette)

        XCTAssertEqual(env.hideCount, 1)
    }

    func testSavedNoticeFallsBackToUntitled() {
        let content = CaptureToastContent(.saved(noteID: UUID(), notebookName: "Work", title: "  "))
        XCTAssertEqual(content.title, "Saved to Work")
        XCTAssertEqual(content.message, "Untitled")
    }
}

@MainActor
private final class HiddenAppProbe {
    var appIsActive = false
    private(set) var hideCount = 0

    var environment: PaletteHiddenApp.Environment {
        PaletteHiddenApp.Environment(
            appIsActive: { self.appIsActive },
            otherWindowIsKey: { false },
            quickCaptureIsVisible: { false },
            hide: { self.hideCount += 1 }
        )
    }
}
