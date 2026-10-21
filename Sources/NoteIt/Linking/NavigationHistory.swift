import Foundation

/// Notes opened in one main window, for Go Back and Go Forward.
struct NavigationHistory {
    static let limit = 50

    private var entries: [UUID] = []
    private var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }
    var current: UUID? { entries.indices.contains(index) ? entries[index] : nil }

    /// Consecutive visits to the same note count once. Visiting drops anything ahead of the current entry.
    mutating func visit(_ id: UUID) {
        if current == id { return }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(id)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    /// The previous valid note; invalid entries on the way are dropped.
    mutating func back(isValid: (UUID) -> Bool) -> UUID? {
        while index > 0 {
            let candidate = index - 1
            if isValid(entries[candidate]) {
                index = candidate
                return entries[index]
            }
            entries.remove(at: candidate)
            index -= 1
        }
        return nil
    }

    mutating func forward(isValid: (UUID) -> Bool) -> UUID? {
        while index < entries.count - 1 {
            let candidate = index + 1
            if isValid(entries[candidate]) {
                index = candidate
                return entries[index]
            }
            entries.remove(at: candidate)
        }
        return nil
    }
}
