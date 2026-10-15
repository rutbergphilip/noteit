import AppKit
import CoreServices

@MainActor
enum SourceResolver {
    static let browserScriptTimeout: TimeInterval = 1.5

    static func resolve(app: NSRunningApplication, includeBrowserLinks: Bool) async -> CaptureSource {
        let name = appName(localizedName: app.localizedName, bundleURL: app.bundleURL, bundleID: app.bundleIdentifier)
        var source = CaptureSource(appName: name, bundleID: app.bundleIdentifier, windowTitle: nil, pageURL: nil,
                                   pageTitle: nil, documentURL: nil)
        let pid = app.processIdentifier
        let readsBrowser = includeBrowserLinks
            && app.bundleIdentifier.map(BrowserSources.supportedBundleIDs.contains) == true

        async let page: (url: URL?, title: String?) = readsBrowser
            ? BrowserPageReader.read(bundleID: app.bundleIdentifier ?? "", timeout: browserScriptTimeout)
            : (nil, nil)
        let window = AccessibilityAccess.isTrusted ? await AXRead.perform { focusedWindow(pid: pid) } : nil

        source.windowTitle = cleanTitle(window?.title, appName: name)
        source.documentURL = documentURL(from: window?.document)
        let resolvedPage = await page
        source.pageURL = resolvedPage.url
        source.pageTitle = resolvedPage.title
        return source
    }

    private struct WindowInfo {
        var title: String?
        var document: String?
    }

    private nonisolated static func focusedWindow(pid: pid_t) -> WindowInfo? {
        let app = AXRead.application(pid)
        guard case .success(let window) = AXRead.element(app, kAXFocusedWindowAttribute) else { return nil }
        let title = AXRead.string(window, kAXTitleAttribute)
        if case .failure(let failure) = title, failure.code == .cannotComplete { return nil }
        return WindowInfo(title: try? title.get(), document: try? AXRead.string(window, kAXDocumentAttribute).get())
    }

    nonisolated static func appName(localizedName: String?, bundleURL: URL?, bundleID: String?) -> String {
        if let localizedName, !localizedName.isEmpty { return localizedName }
        if let bundleName = bundleURL?.deletingPathExtension().lastPathComponent, !bundleName.isEmpty {
            return bundleName
        }
        return bundleID ?? "Unknown App"
    }

    /// Trims the title and drops a trailing " — App" suffix; a title that only repeats the app name is dropped.
    nonisolated static func cleanTitle(_ title: String?, appName: String) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let padded = " " + title
        for separator in [" — ", " – ", " - "] where padded.hasSuffix(separator + appName) {
            title = String(padded.dropLast(separator.count + appName.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard !title.isEmpty, title != appName else { return nil }
        return title
    }

    /// `AXDocument` holds a URL string; only an existing local file is kept.
    nonisolated static func documentURL(from value: String?,
                                        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value)
        guard let url, url.isFileURL, !url.path.isEmpty, fileExists(url.path) else { return nil }
        return url
    }
}

private let automationConsentQueue = DispatchQueue(label: "NoteIt.AutomationConsent", qos: .utility)

/// Runs browser AppleScripts on `AppleScriptThread` (NSAppleScript isn't thread-safe), at most one at a time,
/// and only once the user has allowed NoteIt to automate that browser.
@MainActor
enum BrowserPageReader {
    /// Compiled scripts by source; only touched on `AppleScriptThread`.
    nonisolated(unsafe) private static var compiledScripts: [String: NSAppleScript] = [:]
    private static var isRunning = false
    private static var permissionChecks: Set<String> = []
    private static var consentRequests: Set<String> = []

    struct Dependencies: Sendable {
        var script: @Sendable (String) -> String?
        var scriptThreadBusy: @Sendable () -> Bool
        var permission: @Sendable (String) -> OSStatus
        var runScript: @Sendable (String) async -> ScriptOutcome

        static let live = Dependencies(
            script: { BrowserSources.appleScript(forBundleID: $0) },
            scriptThreadBusy: { AppleScriptThread.shared.isBusy },
            permission: { automationStatus(bundleID: $0, askUserIfNeeded: false) },
            runScript: { await runOnScriptThread($0) }
        )
    }

    /// Gives up after `timeout` without a link. A script still running then keeps the script thread busy, so
    /// later reads skip until it ends; a permission check that never returns only blocks its own browser.
    /// Never shows the Automation consent prompt; see `requestConsentIfNeeded`.
    static func read(bundleID: String, timeout: TimeInterval,
                     dependencies: Dependencies = .live) async -> (url: URL?, title: String?) {
        guard let script = dependencies.script(bundleID),
              canStartRead(bundleID: bundleID, isRunning: isRunning, permissionChecks: permissionChecks,
                           scriptThreadBusy: dependencies.scriptThreadBusy()) else { return (nil, nil) }
        isRunning = true
        defer { isRunning = false }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ScriptOutcome, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in
                once.resume(await runIfPermitted(script, bundleID: bundleID, dependencies: dependencies, once: once))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.timedOut)
            }
        }
        return pageInfo(outcome)
    }

    nonisolated static func canStartRead(bundleID: String, isRunning: Bool, permissionChecks: Set<String>,
                                         scriptThreadBusy: Bool) -> Bool {
        !isRunning && !scriptThreadBusy && !permissionChecks.contains(bundleID)
    }

    private static func runIfPermitted(_ script: String, bundleID: String, dependencies: Dependencies,
                                       once: ResumeOnce) async -> ScriptOutcome {
        permissionChecks.insert(bundleID)
        let status = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: dependencies.permission(bundleID))
            }
        }
        permissionChecks.remove(bundleID)
        guard automationDecision(status) == .run else { return ScriptOutcome(output: nil, errorNumber: Int(status)) }
        guard !once.isResolved, !dependencies.scriptThreadBusy() else { return .timedOut }
        return await dependencies.runScript(script)
    }

    enum AutomationDecision: Equatable {
        case run
        case needsConsent
        case skip
    }

    /// Never runs a script that would show the consent prompt, so the prompt can't hold up the script thread.
    nonisolated static func automationDecision(_ status: OSStatus) -> AutomationDecision {
        switch status {
        case noErr: return .run
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
        default: return .skip
        }
    }

    /// Shows "NoteIt wants to control …" for a supported browser, at most one prompt per browser at a time,
    /// without blocking the caller, the main thread or the script thread.
    static func requestConsentIfNeeded(bundleID: String) {
        requestConsentIfNeeded(bundleID: bundleID) { automationStatus(bundleID: $0, askUserIfNeeded: true) }
    }

    static func requestConsentIfNeeded(bundleID: String, prompt: @escaping @Sendable (String) -> OSStatus) {
        guard BrowserSources.supportedBundleIDs.contains(bundleID), consentRequests.insert(bundleID).inserted else {
            return
        }
        automationConsentQueue.async {
            _ = prompt(bundleID)
            Task { @MainActor in _ = consentRequests.remove(bundleID) }
        }
    }

    static func isRequestingConsent(bundleID: String) -> Bool {
        consentRequests.contains(bundleID)
    }

    static func isCheckingPermission(bundleID: String) -> Bool {
        permissionChecks.contains(bundleID)
    }

    private nonisolated static func automationStatus(bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard),
                                                     askUserIfNeeded)
    }

    struct ScriptOutcome: Equatable, Sendable {
        var output: String?
        var errorNumber: Int?

        static let timedOut = ScriptOutcome(output: nil, errorNumber: nil)
    }

    /// Any script error (e.g. -1743 Automation not allowed, -600 app not running) means no link.
    nonisolated static func pageInfo(_ outcome: ScriptOutcome) -> (url: URL?, title: String?) {
        guard outcome.errorNumber == nil, let output = outcome.output else { return (nil, nil) }
        let parsed = BrowserSources.parse(output)
        guard let url = parsed.url else { return (nil, nil) }
        return (url, parsed.title)
    }

    private nonisolated static func runOnScriptThread(_ source: String) async -> ScriptOutcome {
        do {
            return try await AppleScriptThread.shared.run { execute(source) }
        } catch {
            return ScriptOutcome(output: nil, errorNumber: -1)
        }
    }

    private nonisolated static func execute(_ source: String) -> ScriptOutcome {
        let script: NSAppleScript
        if let cached = compiledScripts[source] {
            script = cached
        } else if let created = NSAppleScript(source: source) {
            compiledScripts[source] = created
            script = created
        } else {
            return ScriptOutcome(output: nil, errorNumber: -1)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return ScriptOutcome(output: nil, errorNumber: error[NSAppleScript.errorNumber] as? Int ?? -1)
        }
        return ScriptOutcome(output: result.stringValue, errorNumber: nil)
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ScriptOutcome, Never>?

        var isResolved: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation == nil
        }

        init(_ continuation: CheckedContinuation<ScriptOutcome, Never>) {
            self.continuation = continuation
        }

        func resume(_ outcome: ScriptOutcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }
}
