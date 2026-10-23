import Foundation

/// Wall-clock allowances for tests. Shared CI runners (`CI` is set) run several times slower than a developer's Mac,
/// so waits, hangs and time limits are stretched there by one factor, which keeps their proportions.
public enum TestTiming {
    public static let isCI = ProcessInfo.processInfo.environment["CI"] != nil
    public static let factor: Double = isCI ? 4 : 1

    public static func scaled(_ seconds: TimeInterval) -> TimeInterval { seconds * factor }

    public static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(scaled(seconds) * 1_000_000_000) }
}
