import XCTest
@testable import NoteItSync

final class BoundedFileAccessTests: XCTestCase {
    func testStuckWorkTimesOutAndIsNotStartedAgainUntilItReturns() async {
        let access = BoundedFileAccess()
        let release = DispatchSemaphore(value: 0)
        let calls = Counter()

        let started = Date()
        let first = await access.run(key: "nas", timeout: 0.1) { calls.increment(); release.wait(); return true }
        XCTAssertNil(first)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        let second = await access.run(key: "nas", timeout: 5) { calls.increment(); return true }
        XCTAssertNil(second, "a second probe of a stuck folder must not wait or start another thread")
        let other = await access.run(key: "other", timeout: 5) { true }
        XCTAssertEqual(other, true)
        XCTAssertEqual(calls.value, 1)

        release.signal()
        while access.isRunning("nas") { try? await Task.sleep(for: .milliseconds(10)) }
        let recovered = await access.run(key: "nas", timeout: 5) { calls.increment(); return true }
        XCTAssertEqual(recovered, true)
        XCTAssertEqual(calls.value, 2)
    }

    func testRunBlockingReturnsResultOrNilWithinTimeout() {
        let access = BoundedFileAccess()
        XCTAssertEqual(access.runBlocking(key: "k", timeout: 5) { 42 }, 42)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let started = Date()
        XCTAssertNil(access.runBlocking(key: "stuck", timeout: 0.1) { release.wait(); return 1 })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
