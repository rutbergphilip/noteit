import CoreServices
import Foundation

/// Watches the content folder with FSEvents (spec §3.5). File-level events arrive after 0.3 s; once 0.5 s pass
/// without another one, or at most `maxDelay` after the first, `onChange` asks for a rescan, which compares every file with `markdown-files.json` and so
/// also covers editors that save through a temp file and a rename; the rescan tells NoteIt's own writes (still
/// carrying a hash in the ledger) apart. Events for `.noteit/` are dropped, and no file is read here. `onRootChanged` reports the folder itself
/// being moved, renamed or unmounted. FSEvents doesn't see changes made by other Macs on a network volume, so there
/// the folder is also rescanned every `networkPollInterval`.
final class MarkdownFolderWatcher: @unchecked Sendable {
    static let latency: CFTimeInterval = 0.3
    static let debounce: TimeInterval = 0.5
    /// A file that keeps changing (a log, a sync client) can't hold back the rescan longer than this.
    static let maxDelay: TimeInterval = 2
    static let networkPollInterval: TimeInterval = 15

    private let root: URL
    private let onChange: @MainActor () -> Void
    private let onRootChanged: @MainActor () -> Void
    private let lock = NSLock()
    private var core: Core?
    private var stopped = false
    private var stream: FSEventStreamRef?
    private var poll: DispatchSourceTimer?

    init(root: URL, onChange: @escaping @MainActor () -> Void,
         onRootChanged: @escaping @MainActor () -> Void) {
        self.root = root
        self.onChange = onChange
        self.onRootChanged = onRootChanged
    }

    deinit { stop() }

    /// Resolves the folder and asks whether it's on a network volume, both of which can hang on a dead mount:
    /// call it off the main thread. A `stop()` meanwhile wins: the stream is then torn down again.
    @discardableResult
    func start() -> Bool {
        guard lock.withLock({ self.core == nil && !stopped }) else { return lock.withLock { stream != nil } }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let isNetwork = (try? resolved.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false
        let core = Core(root: resolved, onChange: onChange, onRootChanged: onRootChanged)
        let info = Unmanaged.passRetained(core).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil,
                                           release: { Unmanaged<Core>.fromOpaque($0!).release() }, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let core = Unmanaged<Core>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let flags = (0..<count).map { eventFlags[$0] }
            core.handle(Array(zip(list, flags)))
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, [resolved.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        else {
            Unmanaged<Core>.fromOpaque(info).release()
            return false
        }
        FSEventStreamSetDispatchQueue(created, core.queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        var timer: DispatchSourceTimer?
        if isNetwork {
            let source = DispatchSource.makeTimerSource(queue: core.queue)
            source.schedule(deadline: .now() + Self.networkPollInterval, repeating: Self.networkPollInterval)
            source.setEventHandler { [core] in core.requestRescan() }
            source.resume()
            timer = source
        }
        let installed = lock.withLock { () -> Bool in
            guard !stopped, self.core == nil else { return false }
            self.core = core
            stream = created
            poll = timer
            return true
        }
        if !installed {
            timer?.cancel()
            core.stop()
            Self.tearDown(created, on: core.queue)
        }
        return installed
    }

    /// Never waits: the stream is torn down on the watcher's queue, and nothing it still had pending is reported.
    func stop() {
        let (stream, core, poll) = lock.withLock { () -> (FSEventStreamRef?, Core?, DispatchSourceTimer?) in
            stopped = true
            defer {
                self.stream = nil
                self.poll = nil
            }
            return (self.stream, self.core, self.poll)
        }
        poll?.cancel()
        core?.stop()
        if let stream, let core { Self.tearDown(stream, on: core.queue) }
    }

    private static func tearDown(_ stream: FSEventStreamRef, on queue: DispatchQueue) {
        let box = StreamBox(stream)
        queue.async {
            FSEventStreamStop(box.stream)
            FSEventStreamInvalidate(box.stream)
            FSEventStreamRelease(box.stream)
        }
    }

    private struct StreamBox: @unchecked Sendable {
        let stream: FSEventStreamRef
        init(_ stream: FSEventStreamRef) { self.stream = stream }
    }

    /// What the stream's callbacks reach; it outlives the watcher until the stream is released.
    private final class Core: @unchecked Sendable {
        let root: URL
        let queue = DispatchQueue(label: "NoteIt.MarkdownFolderWatcher")
        private let onChange: @MainActor () -> Void
        private let onRootChanged: @MainActor () -> Void
        private let lock = NSLock()
        private var stopped = false
        /// Run on `queue`.
        private var pending: DispatchWorkItem?
        private var firstPendingEvent: DispatchTime?

        init(root: URL, onChange: @escaping @MainActor () -> Void, onRootChanged: @escaping @MainActor () -> Void) {
            self.root = root
            self.onChange = onChange
            self.onRootChanged = onRootChanged
        }

        func stop() { lock.withLock { stopped = true } }

        private var isStopped: Bool { lock.withLock { stopped } }

        func requestRescan() {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { if !isStopped { onChange() } }
            }
        }

        /// Runs on `queue`. Looks at paths only: reading a file here could hang on a network volume, and the
        /// rescan tells NoteIt's own writes apart through the ledger.
        func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
            guard !isStopped else { return }
            var relevant = false
            for event in events {
                if event.flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    DispatchQueue.main.async { [self] in
                        MainActor.assumeIsolated { if !isStopped { onRootChanged() } }
                    }
                    return
                }
                if isRelevant(event.path) { relevant = true }
            }
            guard relevant else { return }
            pending?.cancel()
            let now = DispatchTime.now()
            let first = firstPendingEvent ?? now
            firstPendingEvent = first
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.firstPendingEvent = nil
                self.requestRescan()
            }
            pending = work
            queue.asyncAfter(deadline: min(now + MarkdownFolderWatcher.debounce, first + MarkdownFolderWatcher.maxDelay), execute: work)
        }

        private func isRelevant(_ path: String) -> Bool {
            guard let relative = MarkdownFolderWatcher.relativePath(path, root: root.path) else { return true }
            return relative != MarkdownBodyStorage.privateFolder && !relative.hasPrefix(MarkdownBodyStorage.privateFolder + "/")
        }
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
