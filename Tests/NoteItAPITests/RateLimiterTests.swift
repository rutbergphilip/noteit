import Foundation
import NoteItAPI
import XCTest

final class RateLimiterTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSinceReferenceDate: 0)
        var now: Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    func testClockGoingBackwardsDoesNotRefill() {
        let clock = Clock()
        let limiter = RateLimiter(rules: [.general: .init(perSecond: 1, burst: 2)], now: { clock.now })
        XCTAssertNil(limiter.consume(client: "a", bucket: .general))
        XCTAssertNil(limiter.consume(client: "a", bucket: .general))
        clock.advance(-10)
        XCTAssertNotNil(limiter.consume(client: "a", bucket: .general))
        clock.advance(10)
        XCTAssertNotNil(limiter.consume(client: "a", bucket: .general))
        clock.advance(1)
        XCTAssertNil(limiter.consume(client: "a", bucket: .general))
        XCTAssertNotNil(limiter.consume(client: "a", bucket: .general))
    }

    func testBucketBurstThenRefill() {
        let clock = Clock()
        let limiter = RateLimiter(rules: [.general: .init(perSecond: 2, burst: 3)], now: { clock.now })
        for _ in 0..<3 { XCTAssertNil(limiter.consume(client: "a", bucket: .general)) }
        XCTAssertEqual(limiter.consume(client: "a", bucket: .general), 1)
        clock.advance(0.5)
        XCTAssertNil(limiter.consume(client: "a", bucket: .general))
        XCTAssertNotNil(limiter.consume(client: "a", bucket: .general))
        clock.advance(100)
        for _ in 0..<3 { XCTAssertNil(limiter.consume(client: "a", bucket: .general)) }
        XCTAssertNotNil(limiter.consume(client: "a", bucket: .general))
    }

    func testRetryAfterRoundsUp() {
        let clock = Clock()
        let limiter = RateLimiter(rules: [.upload: .init(perSecond: 0.5, burst: 1), .general: .init(perSecond: 100, burst: 100)],
                                  now: { clock.now })
        XCTAssertNil(limiter.consume(client: "a", bucket: .upload))
        XCTAssertEqual(limiter.consume(client: "a", bucket: .upload), 2)
        clock.advance(0.1)
        XCTAssertEqual(limiter.consume(client: "a", bucket: .upload), 2)   // 1.9 s → 2
        clock.advance(1.85)
        XCTAssertEqual(limiter.consume(client: "a", bucket: .upload), 1)   // 0.05 s → at least 1

        let fast = RateLimiter(rules: [.general: .init(perSecond: 1000, burst: 1)], now: { clock.now })
        XCTAssertNil(fast.consume(client: "a", bucket: .general))
        XCTAssertEqual(fast.consume(client: "a", bucket: .general), 1)
    }

    func testBucketsAreIndependentPerClient() {
        let clock = Clock()
        let limiter = RateLimiter(rules: [.general: .init(perSecond: 1, burst: 2), .write: .init(perSecond: 1, burst: 5),
                                          .unauthenticated: .init(perSecond: 1, burst: 1)],
                                  now: { clock.now })
        XCTAssertNil(limiter.consume(client: "a", bucket: .general))
        XCTAssertNil(limiter.consume(client: "a", bucket: .general))
        XCTAssertNotNil(limiter.consume(client: "a", bucket: .general))
        XCTAssertNil(limiter.consume(client: "b", bucket: .general))
        XCTAssertNil(limiter.consume(client: "anon", bucket: .unauthenticated))

        // A write also takes from the client's general bucket, and nothing is taken when that one is empty.
        XCTAssertNotNil(limiter.consume(client: "a", bucket: .write))
        XCTAssertNil(limiter.consume(client: "b", bucket: .write))
        XCTAssertNotNil(limiter.consume(client: "b", bucket: .general))
        clock.advance(1)
        XCTAssertNil(limiter.consume(client: "a", bucket: .write))
        XCTAssertNotNil(limiter.consume(client: "a", bucket: .general))
    }
}
