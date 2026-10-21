import Foundation

/// Runs file-system work that can hang on an unreachable network volume (bookmark resolution, `stat` of a folder
/// on a NAS) on its own thread, and stops waiting for it after a timeout. While work for a key is still stuck, it
/// isn't started again, so a dead mount never piles up blocked threads; callers get nil right away instead.
public final class BoundedFileAccess: @unchecked Sendable {
    public static let shared = BoundedFileAccess()

    private let queue = DispatchQueue(label: "NoteIt.BoundedFileAccess", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var running: Set<String> = []

    public init() {}

    /// Whether work for `key` is still running, e.g. stuck on a dead mount after its caller gave up.
    public func isRunning(_ key: String) -> Bool {
        lock.withLock { running.contains(key) }
    }

    /// Calls `completion` exactly once, on an arbitrary thread: with the work's result, or with nil when it
    /// didn't finish within `timeout` or earlier work for `key` is still running.
    public func run<T>(key: String, timeout: TimeInterval, _ work: @escaping () -> T, completion: @escaping (T?) -> Void) {
        let started = lock.withLock { running.insert(key).inserted }
        guard started else { return completion(nil) }
        let once = Once()
        queue.async {
            let result = work()
            self.lock.withLock { _ = self.running.remove(key) }
            if once.claim() { completion(result) }
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            if once.claim() { completion(nil) }
        }
    }

    public func run<T>(key: String, timeout: TimeInterval, _ work: @escaping () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            run(key: key, timeout: timeout, work) { continuation.resume(returning: $0) }
        }
    }

    /// Blocks the calling thread for at most `timeout`. For launch, before there is anything else to do.
    public func runBlocking<T>(key: String, timeout: TimeInterval, _ work: @escaping () -> T) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        run(key: key, timeout: timeout, work) { result in
            box.value = result
            done.signal()
        }
        done.wait()
        return box.value
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}
