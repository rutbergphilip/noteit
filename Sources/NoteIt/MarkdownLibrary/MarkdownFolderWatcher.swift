import CoreServices
import Foundation

/// Watches the content folder with FSEvents (spec §3.5). File-level events arrive after 0.3 s; once 0.5 s pass
/// without another one, or at most `maxDelay` after the first, `onChange` asks for a rescan, which compares every file with `markdown-files.json` and so
/// also covers editors that save through a temp file and a rename. Events for files NoteIt just wrote (still
/// carrying a hash in the ledger) and for `.noteit/` are dropped. `onRootChanged` reports the folder itself
/// being moved, renamed or unmounted. FSEvents doesn't see changes made by other Macs on a network volume, so there
/// the folder is also rescanned every `networkPollInterval`.
final class MarkdownFolderWatcher: @unchecked Sendable {
    static let latency: CFTimeInterval = 0.3
    static let debounce: TimeInterval = 0.5
    /// A file that keeps changing (a log, a sync client) can't hold back the rescan longer than this.
    static let maxDelay: TimeInterval = 2
    static let networkPollInterval: TimeInterval = 15

    private let root: URL
    private let ledger: WriteLedger
    private let onChange: @MainActor () -> Void
    private let onRootChanged: @MainActor () -> Void
    private let queue = DispatchQueue(label: "NoteIt.MarkdownFolderWatcher")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    /// The first event the pending rescan waits for; runs on `queue`.
    private var firstPendingEvent: DispatchTime?
    private var poll: DispatchSourceTimer?

    init(root: URL, ledger: WriteLedger, onChange: @escaping @MainActor () -> Void,
         onRootChanged: @escaping @MainActor () -> Void) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.ledger = ledger
        self.onChange = onChange
        self.onRootChanged = onRootChanged
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<MarkdownFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let flags = (0..<count).map { eventFlags[$0] }
            watcher.handle(Array(zip(list, flags)))
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        if (try? root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.networkPollInterval, repeating: Self.networkPollInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onChange() } }
            }
            timer.resume()
            poll = timer
        }
        return true
    }

    func stop() {
        poll?.cancel()
        poll = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync { pending?.cancel() }
    }

    /// Runs on `queue`.
    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        var relevant = false
        for event in events {
            if event.flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onRootChanged() } }
                return
            }
            let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped)
            if event.flags & rescan != 0 || isRelevant(event.path, flags: event.flags) { relevant = true }
        }
        guard relevant else { return }
        pending?.cancel()
        let now = DispatchTime.now()
        let first = firstPendingEvent ?? now
        firstPendingEvent = first
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.firstPendingEvent = nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onChange() } }
        }
        pending = work
        queue.asyncAfter(deadline: min(now + Self.debounce, first + Self.maxDelay), execute: work)
    }

    private func isRelevant(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
        guard let relative = Self.relativePath(path, root: root.path) else { return true }
        if relative.isEmpty { return true }
        if relative == MarkdownBodyStorage.privateFolder || relative.hasPrefix(MarkdownBodyStorage.privateFolder + "/") {
            return false
        }
        guard flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, relative.lowercased().hasSuffix(".md"),
              let data = FileManager.default.contents(atPath: path) else { return true }
        return !ledger.isOwnWrite(path: relative, sha256: AttachmentStore.sha256(data))
    }

    /// FSEvents reports real paths (`/private/var/…`), so both sides are compared after resolving.
    static func relativePath(_ path: String, root: String) -> String? {
        if path == root { return "" }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if resolved == root { return "" }
        guard resolved.hasPrefix(root + "/") else { return nil }
        return String(resolved.dropFirst(root.count + 1))
    }
}
