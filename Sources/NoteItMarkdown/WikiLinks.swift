import Foundation

/// The on-disk syntax of a link to another note: `[[target]]`, `[[target|shown text]]`, `[[target#heading]]`
/// (markdown-storage spec §3.4). In a table cell the `|` is written `\|`; the reader accepts both.
public struct WikiLink: Sendable, Equatable {
    /// File name or content-relative path, no ".md".
    public var target: String
    public var heading: String?
    /// nil when equal to target.
    public var shownText: String?

    public init(target: String, heading: String? = nil, shownText: String? = nil) {
        self.target = target
        self.heading = heading
        self.shownText = shownText
    }

    public func written(inTableCell: Bool = false) -> String {
        var text = "[[" + target
        if let heading { text += "#" + heading }
        if let shownText { text += (inTableCell ? "\\|" : "|") + shownText }
        return text + "]]"
    }

    /// The text between `[[` and `]]`.
    static func parse(_ inner: String) -> WikiLink? {
        var targetPart = inner
        var shown: String?
        if let range = inner.range(of: "\\|") ?? inner.range(of: "|") {
            targetPart = String(inner[..<range.lowerBound])
            shown = String(inner[range.upperBound...])
        }
        let (target, heading) = targetPart.splitOnce("#")
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty || heading != nil else { return nil }
        let shownText = shown.flatMap { $0.isEmpty || $0 == trimmed ? nil : $0 }
        return WikiLink(target: trimmed, heading: heading.map { $0.trimmingCharacters(in: .whitespaces) }, shownText: shownText)
    }

    // MARK: noteit:// links

    /// `noteit://note/<UUID>` when the target resolves, else `noteit://note?title=<target>`; a heading is added as
    /// `heading=`. A title or heading longer than NoteLink.maxTextLength (120) is kept in full so the file is written
    /// back unchanged; that href isn't a NoteLink, so the text isn't a note link in NoteIt.
    func href(resolve: (String) -> UUID?) -> String {
        if let id = resolve(target) {
            var href = "noteit://note/\(id.uuidString)"
            if let heading { href += "?heading=" + Self.queryEncoded(heading) }
            return href
        }
        var href = "noteit://note?title=" + Self.queryEncoded(target)
        if let heading { href += "&heading=" + Self.queryEncoded(heading) }
        return href
    }

    /// The parts of a note link href, only when `href(resolve:)` would give back the same string.
    enum NoteHref: Equatable {
        case resolved(UUID, heading: String?)
        case unresolved(title: String, heading: String?)
    }

    static func noteHref(_ href: String) -> NoteHref? {
        guard let components = URLComponents(string: href), components.scheme == "noteit", components.host == "note" else {
            return nil
        }
        let items = components.queryItems ?? []
        let heading = items.first { $0.name == "heading" }?.value
        let parsed: NoteHref
        if components.path.count > 1, let id = UUID(uuidString: String(components.path.dropFirst())) {
            guard items.allSatisfy({ $0.name == "heading" }), items.count <= 1 else { return nil }
            parsed = .resolved(id, heading: heading)
        } else if components.path.isEmpty, let title = items.first(where: { $0.name == "title" })?.value, !title.isEmpty {
            guard items.allSatisfy({ $0.name == "title" || $0.name == "heading" }), items.count <= 2 else { return nil }
            parsed = .unresolved(title: title, heading: heading)
        } else {
            return nil
        }
        let rebuilt: String
        switch parsed {
        case .resolved(let id, let heading):
            rebuilt = WikiLink(target: "", heading: heading).href(resolve: { _ in id })
        case .unresolved(let title, let heading):
            rebuilt = WikiLink(target: title, heading: heading).href(resolve: { _ in nil })
        }
        return rebuilt == href ? parsed : nil
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?/")
        return set
    }()

    static func queryEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }
}
