import Foundation

/// Copies settings from Inkwell's defaults domain into NoteIt's on first launch.
public enum DefaultsMigration {
    public static let doneKey = "didMigrateFromInkwell"

    /// Copies every key from `legacyDomain` that `target` doesn't already have, then sets `doneKey`.
    /// Runs once: returns the copied keys, or nil if it had already run. Window and split-view
    /// geometry is skipped (it is recreated on first use). Must run before `register(defaults:)`
    /// so registered defaults don't count as "already set".
    @discardableResult
    public static func migrate(legacyDomain: [String: Any]?, into target: UserDefaults) -> [String]? {
        guard !target.bool(forKey: doneKey) else { return nil }
        var copied: [String] = []
        for (key, value) in legacyDomain ?? [:] where shouldCopy(key) && target.object(forKey: key) == nil {
            target.set(value, forKey: key)
            copied.append(key)
        }
        target.set(true, forKey: doneKey)
        return copied.sorted()
    }

    static func shouldCopy(_ key: String) -> Bool {
        key != doneKey && !key.hasPrefix("NSWindow Frame") && !key.hasPrefix("NSSplitView")
    }
}
