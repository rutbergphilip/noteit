import Foundation

/// Where a `noteit://append` link or an API append puts its text. Declared here so `NoteItCore` doesn't depend on
/// `NoteItAPI`, which aliases it. Shape owned by the automation plan; built in foundations Task 5.3.
public enum AppendPosition: String, Codable, Sendable { case end, start }

/// The `x-success`, `x-error` and `x-cancel` callbacks of a `noteit://` link. Shape owned by the automation plan;
/// built in foundations Task 5.3.
public struct XCallback: Equatable, Sendable {
    public var success: URL?
    public var error: URL?
    public var cancel: URL?

    public init(success: URL? = nil, error: URL? = nil, cancel: URL? = nil) {
        self.success = success
        self.error = error
        self.cancel = cancel
    }

    /// False for `http` and `https`: a web page never receives a note's id, title or link.
    public static func mayReceiveNoteDetails(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme != "http" && scheme != "https"
    }

    static let droppedSchemes: Set<String> = ["javascript", "file", "data", "noteit"]
}

/// Shape owned by the automation plan; built in foundations Task 5.3.
public enum URLCommandError: Error, Equatable, Sendable { case unknownHost(String), invalid(String), tooLarge }

/// A parsed `noteit://` link. Shape and parsing rules owned by the automation plan (its Task 5); built in
/// foundations Task 5.3. Foundation only, so the Mac and the phone share it. Routing is automation's.
public enum URLCommand: Equatable, Sendable {
    /// `noteit://note/<UUID>[?heading=]`, through `NoteLink`.
    case note(id: UUID, heading: String?)
    /// `noteit://note?title=[&heading=]`, through `NoteLink`.
    case noteTitle(title: String, heading: String?)
    case new(title: String?, text: String, notebook: String?, tags: [String], open: Bool)
    /// `noteit://new?inbox=<UUID>`: an item the Share extension saved after the user pressed Save.
    case shareInbox(UUID)
    case append(target: AppendTarget, text: String, position: AppendPosition, timestamp: Bool)
    case open(OpenTarget)
    case search(String)
    case daily
    case settings(tab: String)
    /// Any non-reserved host, with the whole URL (fragment included); dispatched through `URLRouteRegistry`.
    case registered(host: String, url: URL)

    public enum AppendTarget: Equatable, Sendable { case id(UUID), title(String), daily }
    public enum OpenTarget: Equatable, Sendable { case id(UUID), title(String) }

    public static let reservedHosts: Set<String> = ["new", "append", "open", "note", "search", "daily", "settings", "x-callback-url"]
    /// Program §9 Settings tab raw values, in order.
    public static let settingsTabs: [String] = ["general", "shortcuts", "editor", "sync", "data", "sharing", "smart", "integrations", "plugins", "about"]
    /// The limit for all of a link's parameter values together, in UTF-8 bytes.
    public static let maxTextBytes = 100_000

    /// True for the links that change notes and so ask first (`new`, `append`, daily append included). False for
    /// `shareInbox`, which is exempt from confirmation, and for every link that only opens or shows something.
    public var changesNotes: Bool {
        switch self {
        case .new, .append: return true
        case .note, .noteTitle, .shareInbox, .open, .search, .daily, .settings, .registered: return false
        }
    }

    /// Returns the command and its callbacks. Callback URLs with `javascript`, `file`, `data` or `noteit` schemes
    /// are dropped. Note links use `NoteLink(url:)`.
    public static func parse(_ url: URL) -> Result<(URLCommand, XCallback), URLCommandError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "noteit"
        else { return .failure(.invalid("scheme")) }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return .failure(.invalid("host")) }

        let items = components.queryItems ?? []
        let callback = XCallback(success: callbackURL(named: "x-success", in: items),
                                 error: callbackURL(named: "x-error", in: items),
                                 cancel: callbackURL(named: "x-cancel", in: items))
        let parameters = items.filter { !$0.name.lowercased().hasPrefix("x-") }
        let textBytes = parameters.reduce(0) { $0 + ($1.value?.utf8.count ?? 0) }
        guard textBytes <= maxTextBytes else { return .failure(.tooLarge) }

        var action = host
        var path = components.path
        if host == "x-callback-url" {
            let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first else { return .failure(.invalid("action")) }
            action = first.lowercased()
            path = parts.count > 1 ? "/" + parts[1] : ""
        }

        return command(action: action, path: path, parameters: parameters, url: url).map { ($0, callback) }
    }

    /// `base` with `items` added after any query it already has.
    public static func callbackURL(_ base: URL, adding items: [URLQueryItem]) -> URL {
        guard !items.isEmpty, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        let encoded = items.map { URLQueryItem(name: encode($0.name), value: $0.value.map(encode)) }
        components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? []) + encoded
        return components.url ?? base
    }

    private static func command(action: String, path: String, parameters: [URLQueryItem],
                                url: URL) -> Result<URLCommand, URLCommandError> {
        let query = Query(parameters)
        switch action {
        case "note":
            var link = URLComponents()
            link.scheme = "noteit"
            link.host = "note"
            link.path = path
            if !parameters.isEmpty {
                link.percentEncodedQueryItems = parameters.map { URLQueryItem(name: encode($0.name), value: $0.value.map(encode)) }
            }
            guard let linkURL = link.url, let noteLink = NoteLink(url: linkURL) else { return .failure(.invalid("note")) }
            switch noteLink {
            case let .note(id, heading): return .success(.note(id: id, heading: heading))
            case let .unresolved(title, heading): return .success(.noteTitle(title: title, heading: heading))
            }

        case "new":
            if let inbox = query["inbox"] {
                guard let id = UUID(uuidString: inbox) else { return .failure(.invalid("inbox")) }
                return .success(.shareInbox(id))
            }
            let text = query["text"] ?? ""
            return .success(.new(title: query.nonEmpty("title"), text: text, notebook: query.nonEmpty("notebook"),
                                 tags: tags(query["tags"]), open: query.bool("open")))

        case "append":
            let target: AppendTarget
            if let id = query["id"] {
                guard let uuid = UUID(uuidString: id) else { return .failure(.invalid("id")) }
                target = .id(uuid)
            } else if let title = query.nonEmpty("title") {
                target = .title(title)
            } else if let daily = query["daily"] {
                guard daily.lowercased() == "today" else { return .failure(.invalid("daily")) }
                target = .daily
            } else {
                return .failure(.invalid("target"))
            }
            guard let text = query.nonEmpty("text") else { return .failure(.invalid("text")) }
            let position: AppendPosition
            if let raw = query["position"] {
                guard let value = AppendPosition(rawValue: raw.lowercased()) else { return .failure(.invalid("position")) }
                position = value
            } else {
                position = .end
            }
            return .success(.append(target: target, text: text, position: position, timestamp: query.bool("timestamp")))

        case "open":
            if let id = query["id"] {
                guard let uuid = UUID(uuidString: id) else { return .failure(.invalid("id")) }
                return .success(.open(.id(uuid)))
            }
            guard let title = query.nonEmpty("title") else { return .failure(.invalid("target")) }
            return .success(.open(.title(title)))

        case "search":
            guard let q = query["q"] else { return .failure(.invalid("q")) }
            return .success(.search(q))

        case "daily":
            return .success(.daily)

        case "settings":
            guard let tab = query["tab"]?.lowercased() else { return .success(.settings(tab: "general")) }
            guard settingsTabs.contains(tab) else { return .failure(.invalid("tab")) }
            return .success(.settings(tab: tab))

        default:
            guard action.unicodeScalars.allSatisfy(isHostCharacter) else { return .failure(.unknownHost(action)) }
            return .success(.registered(host: action, url: url))
        }
    }

    private struct Query {
        private var values: [String: String] = [:]

        init(_ items: [URLQueryItem]) {
            for item in items where values[item.name.lowercased()] == nil {
                values[item.name.lowercased()] = item.value ?? ""
            }
        }

        subscript(_ name: String) -> String? { values[name] }

        func nonEmpty(_ name: String) -> String? {
            guard let value = values[name], !value.isEmpty else { return nil }
            return value
        }

        func bool(_ name: String) -> Bool {
            guard let value = values[name]?.lowercased() else { return false }
            return ["1", "true", "yes"].contains(value)
        }
    }

    private static func tags(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func isHostCharacter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "."
    }

    private static func callbackURL(named name: String, in items: [URLQueryItem]) -> URL? {
        guard let raw = items.first(where: { $0.name.lowercased() == name })?.value,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              !XCallback.droppedSchemes.contains(scheme)
        else { return nil }
        return url
    }

    private static let valueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#")
        return set
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
    }
}
