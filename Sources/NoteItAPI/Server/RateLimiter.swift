import Foundation

/// Token buckets per client and bucket (automation spec §6.7).
public final class RateLimiter: @unchecked Sendable {
    public struct Rule: Sendable {
        public var perSecond: Double
        public var burst: Double

        public init(perSecond: Double, burst: Double) {
            self.perSecond = perSecond
            self.burst = burst
        }
    }

    public static let defaults: [RouteBucket: Rule] = [
        .general: Rule(perSecond: 10, burst: 60),
        .write: Rule(perSecond: 2, burst: 20),
        .upload: Rule(perSecond: 0.5, burst: 10),
        .unauthenticated: Rule(perSecond: 0.5, burst: 10),
    ]

    private struct Key: Hashable {
        let client: String
        let bucket: RouteBucket
    }

    private struct Bucket {
        var tokens: Double
        var updated: Date
    }

    private let rules: [RouteBucket: Rule]
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var buckets: [Key: Bucket] = [:]

    public init(rules: [RouteBucket: Rule] = defaults, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rules = rules
        self.now = now
    }

    /// nil = allowed; otherwise whole seconds to wait (at least 1). Write and upload requests also consume from the
    /// client's `.general` bucket; nothing is taken unless every bucket involved has a token.
    public func consume(client: String, bucket: RouteBucket) -> Int? {
        let involved: [RouteBucket] = bucket == .write || bucket == .upload ? [bucket, .general] : [bucket]
        lock.lock()
        defer { lock.unlock() }
        let time = now()
        var refilled: [(Key, Bucket, Rule)] = []
        for name in involved {
            guard let rule = rules[name] else { continue }
            let key = Key(client: client, bucket: name)
            var state = buckets[key] ?? Bucket(tokens: rule.burst, updated: time)
            let elapsed = max(0, time.timeIntervalSince(state.updated))
            state.tokens = min(rule.burst, state.tokens + elapsed * rule.perSecond)
            state.updated = time
            refilled.append((key, state, rule))
        }
        let wait = refilled.filter { $0.1.tokens < 1 }
            .map { _, state, rule in rule.perSecond > 0 ? (1 - state.tokens) / rule.perSecond : .infinity }
            .max()
        for (key, var state, _) in refilled {
            if wait == nil { state.tokens -= 1 }
            buckets[key] = state
        }
        guard let wait else { return nil }
        return wait.isFinite ? max(1, Int(wait.rounded(.up))) : Int.max
    }
}
