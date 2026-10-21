import Foundation

public struct TagNode: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String, name: String
    public var ownCount: Int, totalCount: Int
    public var children: [TagNode]

    public init(path: String, name: String, ownCount: Int, totalCount: Int, children: [TagNode]) {
        self.path = path
        self.name = name
        self.ownCount = ownCount
        self.totalCount = totalCount
        self.children = children
    }
}

public enum TagTree {
    /// One tree from the tags of each note. Parents a note doesn't name are implied; `totalCount` counts each note
    /// once however many of its tags are in the subtree. Siblings sort by name.
    public static func build(noteTags: [[String]]) -> [TagNode] {
        var own: [String: Int] = [:]
        var total: [String: Int] = [:]
        var paths = Set<String>()
        for tags in noteTags {
            var covered = Set<String>()
            for tag in Set(tags) where !tag.isEmpty {
                own[tag, default: 0] += 1
                for prefix in prefixes(of: tag) {
                    paths.insert(prefix)
                    covered.insert(prefix)
                }
            }
            for path in covered { total[path, default: 0] += 1 }
        }
        return tree(paths: paths, own: own, total: total)
    }

    /// A tree from per-tag note counts; a parent's `totalCount` adds up its subtree, so a note with two tags in it
    /// counts twice. Prefer `build(noteTags:)` when the notes are at hand.
    public static func build(counts: [String: Int]) -> [TagNode] {
        var total: [String: Int] = [:]
        var paths = Set<String>()
        for (tag, count) in counts where !tag.isEmpty {
            for prefix in prefixes(of: tag) {
                paths.insert(prefix)
                total[prefix, default: 0] += count
            }
        }
        return tree(paths: paths, own: counts, total: total)
    }

    /// `a/b/c` → `a`, `a/b`, `a/b/c`.
    static func prefixes(of tag: String) -> [String] {
        var result: [String] = []
        var index = tag.startIndex
        while let slash = tag[index...].firstIndex(of: "/") {
            if slash > tag.startIndex { result.append(String(tag[..<slash])) }
            index = tag.index(after: slash)
        }
        result.append(tag)
        return result
    }

    private static func tree(paths: Set<String>, own: [String: Int], total: [String: Int]) -> [TagNode] {
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for path in paths {
            if let slash = path.lastIndex(of: "/"), paths.contains(String(path[..<slash])) {
                children[String(path[..<slash]), default: []].append(path)
            } else {
                roots.append(path)
            }
        }
        func node(_ path: String) -> TagNode {
            let name = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
            let kids = (children[path] ?? []).map(node).sorted(by: order)
            return TagNode(path: path, name: name, ownCount: own[path] ?? 0, totalCount: total[path] ?? 0, children: kids)
        }
        return roots.map(node).sorted(by: order)
    }

    private static func order(_ a: TagNode, _ b: TagNode) -> Bool {
        let result = a.name.localizedStandardCompare(b.name)
        return result == .orderedSame ? a.path < b.path : result == .orderedAscending
    }

    /// True when `tag` is `selected` or nested under it (`work/acme` under `work`).
    public static func matches(_ tag: String, selected: String) -> Bool {
        tag == selected || (tag.count > selected.count && tag.hasPrefix(selected) && tag.dropFirst(selected.count).first == "/")
    }
}
