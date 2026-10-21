import Foundation

/// Program §5 gate, on now that linking ships daily notes. When false: Append to Today is unavailable, the daily
/// API routes return 501 not_implemented, and the daily CLI commands and the `daily` and `append?daily=` URL hosts
/// are unavailable.
public enum DailyNotes {
    public static let isAvailable = true
}
