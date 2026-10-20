import Foundation

/// What the sidebar has selected. Moved from the app in foundations Task 1.1, which adds the program §9 cases.
public enum SidebarSelection: Hashable, Sendable {
    case allNotes, pinned, recent, conflicts, recentlyDeleted, notebook(UUID)
    /// The tag path; a flat tag is a one-segment path.
    case tag(String)
    /// Owned by linking; an empty list until linking ships.
    case today
    /// Owned by organise; an empty list until organise ships.
    case tasks
    /// Owned by organise; an empty list until organise ships.
    case smartFolder(UUID)
}

/// Program §9 sidebar order for the fixed library rows (foundations Task 1.1). Wave 0 doesn't reorder the
/// live sidebar; each owner places its row by this list when it adds one.
public enum SidebarLibraryRow: String, CaseIterable, Sendable {
    case allNotes, today, tasks, pinned, recent, conflicts, recentlyDeleted
}
