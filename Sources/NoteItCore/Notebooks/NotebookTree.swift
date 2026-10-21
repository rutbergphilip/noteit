import Foundation

public struct NotebookNodeInput: Sendable, Hashable {
    public var id: UUID, parentID: UUID?, sortIndex: Int, name: String

    public init(id: UUID, parentID: UUID?, sortIndex: Int, name: String) {
        self.id = id
        self.parentID = parentID
        self.sortIndex = sortIndex
        self.name = name
    }
}

/// Notebooks as a tree. A parent that doesn't exist makes a notebook top level; in a cycle, the notebook with the
/// lowest UUID string becomes top level.
public struct NotebookTree: Sendable {
    public static let maxDepth = 4

    private let items: [UUID: NotebookNodeInput]
    private let parents: [UUID: UUID]
    private let childMap: [UUID: [UUID]]
    public let roots: [UUID]

    public init(_ items: [NotebookNodeInput]) {
        var byID: [UUID: NotebookNodeInput] = [:]
        for item in items where byID[item.id] == nil { byID[item.id] = item }
        var parents: [UUID: UUID] = [:]
        for item in byID.values {
            if let parent = item.parentID, parent != item.id, byID[parent] != nil { parents[item.id] = parent }
        }
        // Break cycles: walk up from each node; a revisited node means a cycle, cut at its lowest UUID string.
        for start in byID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            var seen: [UUID] = []
            var current: UUID? = start
            while let id = current {
                if let at = seen.firstIndex(of: id) {
                    let cycle = seen[at...]
                    if let lowest = cycle.min(by: { $0.uuidString < $1.uuidString }) { parents[lowest] = nil }
                    break
                }
                seen.append(id)
                current = parents[id]
            }
        }
        func order(_ a: UUID, _ b: UUID) -> Bool {
            let x = byID[a]!, y = byID[b]!
            if x.sortIndex != y.sortIndex { return x.sortIndex < y.sortIndex }
            let byName = x.name.localizedStandardCompare(y.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.uuidString < b.uuidString
        }
        var children: [UUID: [UUID]] = [:]
        var roots: [UUID] = []
        for id in byID.keys {
            if let parent = parents[id] { children[parent, default: []].append(id) } else { roots.append(id) }
        }
        for key in children.keys { children[key]?.sort(by: order) }
        self.items = byID
        self.parents = parents
        self.childMap = children
        self.roots = roots.sorted(by: order)
    }

    public func contains(_ id: UUID) -> Bool { items[id] != nil }

    public func children(of id: UUID) -> [UUID] { childMap[id] ?? [] }

    public func effectiveParent(of id: UUID) -> UUID? { parents[id] }

    public func depth(of id: UUID) -> Int {
        var depth = 1
        var current = parents[id]
        while let parent = current {
            depth += 1
            current = parents[parent]
        }
        return depth
    }

    public func descendants(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        func visit(_ node: UUID) {
            for child in children(of: node) {
                result.append(child)
                visit(child)
            }
        }
        visit(id)
        return result
    }

    /// Levels below `id`, counting `id` itself as 1.
    public func height(of id: UUID) -> Int {
        1 + (children(of: id).map(height(of:)).max() ?? 0)
    }

    public func path(of id: UUID) -> [String] {
        var names: [String] = []
        var current: UUID? = id
        while let node = current, let item = items[node] {
            names.insert(item.name, at: 0)
            current = parents[node]
        }
        return names
    }

    /// "Work/Clients" walks from the top level; a single name also matches a notebook at any level. Case-insensitive.
    public func id(forPath path: String) -> UUID? {
        let wanted = path.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let ordered = flattened(expanded: nil).map(\.id)
        let byName = ordered.first { Self.same(items[$0]!.name, wanted) }
        guard wanted.contains("/") else { return byName }
        var level = roots
        var found: UUID?
        for segment in wanted.split(separator: "/", omittingEmptySubsequences: true) {
            let name = segment.trimmingCharacters(in: .whitespaces)
            guard let match = level.first(where: { Self.same(items[$0]!.name, name) }) else { return byName }
            found = match
            level = children(of: match)
        }
        return found ?? byName
    }

    public func canMove(_ id: UUID, under parent: UUID?) -> Bool {
        guard contains(id) else { return false }
        guard let parent else { return height(of: id) <= Self.maxDepth }
        guard contains(parent), parent != id, !descendants(of: id).contains(parent) else { return false }
        return depth(of: parent) + height(of: id) <= Self.maxDepth
    }

    /// Depth-first in display order; `expanded` nil lists everything, otherwise only children of expanded notebooks.
    public func flattened(expanded: Set<UUID>?) -> [(id: UUID, depth: Int)] {
        var result: [(id: UUID, depth: Int)] = []
        func visit(_ id: UUID, _ depth: Int) {
            result.append((id, depth))
            guard expanded?.contains(id) ?? true else { return }
            for child in children(of: id) { visit(child, depth + 1) }
        }
        for root in roots { visit(root, 1) }
        return result
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }
}
