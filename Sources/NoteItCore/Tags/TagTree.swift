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
    /// True when `tag` is `selected` or nested under it (`work/acme` under `work`).
    public static func matches(_ tag: String, selected: String) -> Bool {
        tag == selected || (tag.count > selected.count && tag.hasPrefix(selected) && tag.dropFirst(selected.count).first == "/")
    }
}
