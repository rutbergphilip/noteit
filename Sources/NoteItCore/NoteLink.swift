import Foundation

/// A link from one note to another, stored as a `noteit://note…` URL. Shape owned by the linking plan; built in
/// foundations Task 5.3. Grammar (linking spec §1), parsed case-insensitively, written in canonical form:
/// `noteit://note/<UUID>[?heading=<text>]` or `noteit://note?title=<text>[&heading=<text>]`.
public enum NoteLink: Equatable, Hashable, Sendable {
    case note(id: UUID, heading: String?)
    case unresolved(title: String, heading: String?)

    /// Longer titles and headings are rejected; callers cut to this first.
    public static let maxTextLength = 120

    /// nil for anything that isn't the grammar above.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "noteit",
              components.host?.lowercased() == "note",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil
        else { return nil }

        var title: String?
        var heading: String?
        var seen = Set<String>()
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            guard seen.insert(name).inserted else { return nil }
            switch name {
            case "title": title = item.value ?? ""
            case "heading": heading = item.value ?? ""
            default: return nil
            }
        }
        if let value = heading {
            guard value.count <= Self.maxTextLength else { return nil }
            heading = value.isEmpty ? nil : value
        }

        let path = components.path
        if path.isEmpty || path == "/" {
            guard let title, !title.isEmpty, title.count <= Self.maxTextLength else { return nil }
            self = .unresolved(title: title, heading: heading)
        } else {
            guard title == nil, path.hasPrefix("/") else { return nil }
            let rest = path.dropFirst()
            guard !rest.contains("/"), let id = UUID(uuidString: String(rest)) else { return nil }
            self = .note(id: id, heading: heading)
        }
    }

    /// The canonical form, with an uppercase UUID.
    public var url: URL {
        var components = URLComponents()
        components.scheme = "noteit"
        components.host = "note"
        var items: [URLQueryItem] = []
        switch self {
        case let .note(id, heading):
            components.path = "/" + id.uuidString
            if let heading { items.append(URLQueryItem(name: "heading", value: Self.encode(heading))) }
        case let .unresolved(title, heading):
            items.append(URLQueryItem(name: "title", value: Self.encode(title)))
            if let heading { items.append(URLQueryItem(name: "heading", value: Self.encode(heading))) }
        }
        if !items.isEmpty { components.percentEncodedQueryItems = items }
        return components.url!
    }

    public var heading: String? {
        switch self {
        case let .note(_, heading), let .unresolved(_, heading): return heading
        }
    }

    /// The link with its title and heading cut to `maxTextLength`, so its URL can be read back.
    public var clamped: NoteLink {
        let heading = heading.map { String($0.prefix(Self.maxTextLength)) }
        switch self {
        case let .note(id, _): return .note(id: id, heading: heading)
        case let .unresolved(title, _): return .unresolved(title: String(title.prefix(Self.maxTextLength)), heading: heading)
        }
    }

    public func withHeading(_ heading: String?) -> NoteLink {
        switch self {
        case let .note(id, _): return .note(id: id, heading: heading)
        case let .unresolved(title, _): return .unresolved(title: title, heading: heading)
        }
    }

    /// Query rules, plus `&`, `=`, `+` and `#`, so a value always reads back as written.
    private static let valueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#")
        return set
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
    }
}

/// The text typed after `[[`, as `title#heading|alias`. Shape owned by the linking plan; built in foundations
/// Task 5.3. `heading` is the text after the first `#` and `alias` the text after the first `|`; each is nil
/// when absent or empty. Parts are trimmed.
public struct LinkQuery: Equatable, Sendable {
    public var title: String
    public var heading: String?
    public var alias: String?

    public init(_ raw: String) {
        var head = Substring(raw)
        var alias: Substring?
        if let bar = head.firstIndex(of: "|") {
            alias = head[head.index(after: bar)...]
            head = head[..<bar]
        }
        var heading: Substring?
        if let hash = head.firstIndex(of: "#") {
            heading = head[head.index(after: hash)...]
            head = head[..<hash]
        }
        self.title = Self.trimmed(head) ?? ""
        self.heading = heading.flatMap(Self.trimmed)
        self.alias = alias.flatMap(Self.trimmed)
    }

    private static func trimmed(_ text: Substring) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
