import AppKit
import Carbon.HIToolbox

enum SelectionReadResult: Equatable {
    case text(String)
    case empty
    case notTrusted
}

@MainActor
enum SelectionReader {
    static let copyTimeout: Duration = .milliseconds(400)
    static let pollInterval: Duration = .milliseconds(20)
    static let modifierReleaseTimeout: Duration = .milliseconds(300)
    static let modifierPollInterval: Duration = .milliseconds(10)
    static let manualAccessibilityRetryDelay: Duration = .milliseconds(150)
    /// How long a copy that lands after `copyTimeout` is still treated as ours and undone.
    static let lateCopyWindow: Duration = .seconds(1)

    private static var copyInProgress = false
    private static var lateCopyWatch: LateCopyWatch?
    private static var manualAccessibilityPIDs: Set<pid_t> = []

    static func readSelection(from app: NSRunningApplication) async -> SelectionReadResult {
        guard AccessibilityAccess.isTrusted else { return .notTrusted }
        let pid = app.processIdentifier
        let browser = isBrowser(bundleID: app.bundleIdentifier)
        let enableManualAccessibility = !manualAccessibilityPIDs.contains(pid) && isElectronApp(bundleURL: app.bundleURL)
        let (selection, enabled) = await AXRead.perform {
            selectedText(pid: pid, enableManualAccessibility: enableManualAccessibility)
        }
        if enabled { manualAccessibilityPIDs.insert(pid) }
        var step = selectionStep(accessibilitySelection(selection), isBrowser: browser,
                                 justEnabledManualAccessibility: enabled)
        if step == .retry {
            try? await Task.sleep(for: manualAccessibilityRetryDelay)
            let (retried, _) = await AXRead.perform { selectedText(pid: pid, enableManualAccessibility: false) }
            step = selectionStep(accessibilitySelection(retried), isBrowser: browser, justEnabledManualAccessibility: false)
        }
        switch step {
        case .text(let text): return .text(text)
        case .empty, .retry: return .empty
        case .copy: return await copySelection(pid: pid)
        }
    }

    // MARK: - Accessibility

    enum AXSelection: Equatable {
        /// The app reported its selection, possibly empty; ⌘C would copy a whole line or file names instead.
        case answered(String)
        /// The focused element doesn't expose selected text; ⌘C is the only way to read it.
        case unsupported
        /// The app didn't answer in time; a ⌘C could land much later, so none is sent.
        case timedOut
        /// Accessibility is off or the element is gone.
        case failed
    }

    nonisolated static func accessibilitySelection(_ result: Result<String, AXFailure>) -> AXSelection {
        switch result {
        case .success(let text): return .answered(text)
        case .failure(let failure) where failure.code == .cannotComplete: return .timedOut
        case .failure(let failure): return allowsCopyFallback(failure.code) ? .unsupported : .failed
        }
    }

    enum SelectionStep: Equatable {
        case text(String)
        case empty
        case copy
        case retry
    }

    /// Browsers can report an empty selection before their accessibility tree is ready, and copy nothing
    /// without a selection, so ⌘C is safe there. Elsewhere an empty answer is trusted: editors like VS Code
    /// copy the whole line and Finder copies file names. An Electron app whose tree was only just switched
    /// on (and may still be building it) gets one more read instead.
    nonisolated static func selectionStep(_ selection: AXSelection, isBrowser: Bool,
                                          justEnabledManualAccessibility: Bool) -> SelectionStep {
        switch selection {
        case .answered(let text):
            if case .text = textResult(text) { return .text(text) }
            if isBrowser { return .copy }
            return justEnabledManualAccessibility ? .retry : .empty
        case .unsupported:
            return justEnabledManualAccessibility ? .retry : .copy
        case .timedOut:
            return justEnabledManualAccessibility ? .retry : .empty
        case .failed:
            return .empty
        }
    }

    nonisolated static let firefoxBundleIDs: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    nonisolated static func isBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return BrowserSources.supportedBundleIDs.contains(bundleID) || firefoxBundleIDs.contains(bundleID)
    }

    nonisolated static func allowsCopyFallback(_ error: AXError) -> Bool {
        switch error {
        case .attributeUnsupported, .noValue, .notImplemented, .parameterizedAttributeUnsupported, .failure:
            return true
        default:
            return false
        }
    }

    /// Electron documents `AXManualAccessibility` as the switch assistive apps use to turn on its
    /// accessibility tree. The tree is built asynchronously, so `selectionStep` reads once more after enabling it.
    private nonisolated static func selectedText(pid: pid_t,
                                                 enableManualAccessibility: Bool) -> (Result<String, AXFailure>, Bool) {
        let app = AXRead.application(pid)
        let enabled = enableManualAccessibility && AXRead.setBool(app, "AXManualAccessibility", true)
        let selection = AXRead.element(app, kAXFocusedUIElementAttribute).flatMap {
            AXRead.string($0, kAXSelectedTextAttribute)
        }
        return (selection, enabled)
    }

    nonisolated static func isElectronApp(bundleURL: URL?,
                                          fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return fileExists(framework.path)
    }

    nonisolated static func textResult(_ string: String?) -> SelectionReadResult {
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        return .text(string)
    }

    // MARK: - ⌘C fallback

    private static func copySelection(pid: pid_t) async -> SelectionReadResult {
        guard !copyInProgress else { return .empty }
        copyInProgress = true
        defer { copyInProgress = false }
        let pasteboard = NSPasteboard.general
        var reusedSnapshot: PasteboardSnapshot?
        var earlierCopyPending = false
        if let watch = lateCopyWatch {
            watch.isCancelled = true
            lateCopyWatch = nil
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            switch lateCopyTakeover(baseline: watch.baseline, current: pasteboard.changeCount, frontmostPID: frontmost,
                                    watchedPID: watch.pid, capturePID: pid) {
            case .restoreThenReuseSnapshot:
                watch.snapshot.restore(to: pasteboard)
                reusedSnapshot = watch.snapshot
            case .reusePendingSnapshot:
                reusedSnapshot = watch.snapshot
                earlierCopyPending = true
            case .discard:
                break
            }
        }
        let snapshot = reusedSnapshot ?? PasteboardSnapshot(pasteboard)
        var baseline = pasteboard.changeCount

        _ = await waitForModifierRelease(timeout: modifierReleaseTimeout, interval: modifierPollInterval) {
            CGEventSource.flagsState(.combinedSessionState)
        }
        if copyLanded(baseline: baseline, current: pasteboard.changeCount) {
            snapshot.restore(to: pasteboard)
            baseline = pasteboard.changeCount
            earlierCopyPending = false
        }
        guard postCopy(to: pid) else {
            if copyLanded(baseline: baseline, current: pasteboard.changeCount) { snapshot.restore(to: pasteboard) }
            if earlierCopyPending { watchForLateCopy(snapshot: snapshot, baseline: pasteboard.changeCount, pid: pid) }
            return .empty
        }
        return await collectCopy(snapshot: snapshot, baseline: baseline, pid: pid, earlierCopyPending: earlierCopyPending)
    }

    /// Waits for a posted ⌘C to land, reads it and puts `snapshot` back; on timeout a watcher takes over.
    /// When an earlier ⌘C to the same app was still unanswered, it may land after ours, so it's watched for too.
    private static func collectCopy(snapshot: PasteboardSnapshot, baseline: Int, pid: pid_t,
                                    earlierCopyPending: Bool) async -> SelectionReadResult {
        let pasteboard = NSPasteboard.general
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: copyTimeout)
        while !copyLanded(baseline: baseline, current: pasteboard.changeCount) {
            if clock.now >= deadline || Task.isCancelled {
                watchForLateCopy(snapshot: snapshot, baseline: baseline, pid: pid)
                return .empty
            }
            try? await Task.sleep(for: pollInterval)
        }

        let copied = copiedString(from: pasteboard)
        snapshot.restore(to: pasteboard)
        if earlierCopyPending { watchForLateCopy(snapshot: snapshot, baseline: pasteboard.changeCount, pid: pid) }
        return textResult(copied)
    }

    nonisolated static func copyLanded(baseline: Int, current: Int) -> Bool {
        current != baseline
    }

    nonisolated static func copiedString(from pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string) { return string }
        for type in [NSPasteboard.PasteboardType.rtf, .rtfd] {
            if let data = pasteboard.data(forType: type),
               let attributed = NSAttributedString(rtf: data, documentAttributes: nil)
                ?? NSAttributedString(rtfd: data, documentAttributes: nil) {
                return attributed.string
            }
        }
        return nil
    }

    // MARK: Late copies

    private final class LateCopyWatch {
        let snapshot: PasteboardSnapshot
        let baseline: Int
        let pid: pid_t
        var isCancelled = false

        init(snapshot: PasteboardSnapshot, baseline: Int, pid: pid_t) {
            self.snapshot = snapshot
            self.baseline = baseline
            self.pid = pid
        }
    }

    enum LateCopyStep: Equatable {
        case keepWatching
        case restore
        case stop
    }

    /// A clipboard change counts as our late ⌘C only while the target app is still in front.
    nonisolated static func lateCopyStep(baseline: Int, current: Int,
                                         frontmostPID: pid_t?, targetPID: pid_t) -> LateCopyStep {
        guard frontmostPID == targetPID else { return .stop }
        return copyLanded(baseline: baseline, current: current) ? .restore : .keepWatching
    }

    enum LateCopyTakeover: Equatable {
        /// The earlier ⌘C landed while its app was in front: undo it and keep the earlier snapshot.
        case restoreThenReuseSnapshot
        /// The same app hasn't answered the earlier ⌘C yet: keep its snapshot, send a fresh ⌘C, and keep
        /// watching for the earlier one afterwards.
        case reusePendingSnapshot
        /// The watched app is no longer in front, or this capture targets another app: drop the watch.
        case discard
    }

    /// How a capture that starts while a late ⌘C is still awaited treats that watch.
    nonisolated static func lateCopyTakeover(baseline: Int, current: Int, frontmostPID: pid_t?,
                                             watchedPID: pid_t, capturePID: pid_t) -> LateCopyTakeover {
        switch lateCopyStep(baseline: baseline, current: current, frontmostPID: frontmostPID, targetPID: watchedPID) {
        case .stop: return .discard
        case .restore: return .restoreThenReuseSnapshot
        case .keepWatching: return capturePID == watchedPID ? .reusePendingSnapshot : .discard
        }
    }

    /// A slow app may still answer ⌘C after we gave up; put the user's clipboard back if it does.
    private static func watchForLateCopy(snapshot: PasteboardSnapshot, baseline: Int, pid: pid_t) {
        let watch = LateCopyWatch(snapshot: snapshot, baseline: baseline, pid: pid)
        lateCopyWatch = watch
        Task { @MainActor in
            defer { if lateCopyWatch === watch { lateCopyWatch = nil } }
            let pasteboard = NSPasteboard.general
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: lateCopyWindow)
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                if watch.isCancelled { return }
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                switch lateCopyStep(baseline: baseline, current: pasteboard.changeCount,
                                    frontmostPID: frontmost, targetPID: pid) {
                case .keepWatching: continue
                case .restore: snapshot.restore(to: pasteboard); return
                case .stop: return
                }
            }
        }
    }

    // MARK: Posting ⌘C

    nonisolated static func blocksCopy(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    /// Waits for ⌃, ⌥ and ⇧ from the capture hotkey to be let go, so the app sees a plain ⌘C.
    /// Returns false when they were still held at the timeout.
    nonisolated static func waitForModifierRelease(timeout: Duration, interval: Duration,
                                                   flags: @Sendable () -> CGEventFlags) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while blocksCopy(flags()) {
            if clock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: interval)
        }
        return true
    }

    private static func postCopy(to pid: pid_t) -> Bool {
        let keyCode = copyKeyCode(translate: MenuShortcutRules.commandLayerCharacter(keyCode:))
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// The key that types "c" with ⌘ held in the current layout (e.g. the ANSI I key on Dvorak),
    /// falling back to the ANSI C key for layouts without a Latin ⌘ layer.
    nonisolated static func copyKeyCode(translate: (Int) -> String?) -> CGKeyCode {
        let ansiC = kVK_ANSI_C
        for keyCode in [ansiC] + Array(0..<128) where translate(keyCode)?.lowercased() == "c" {
            return CGKeyCode(keyCode)
        }
        return CGKeyCode(ansiC)
    }
}
