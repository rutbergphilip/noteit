import Foundation

/// Program §5 gate. While false: Append to Today is unavailable, the daily API routes return
/// 501 not_implemented, and the daily CLI commands and the `daily` and `append?daily=` URL hosts are
/// unavailable. Linking changes the literal to true in the task that ships the daily-note UI.
/// Built in foundations Task 4.6.
public enum DailyNotes {
    public static let isAvailable = false
}
