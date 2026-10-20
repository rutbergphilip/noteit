import Foundation

/// Which link targets a document may hold. Owned by the web-app plan (the same list as TS `LINK_SCHEMES`); the
/// `noteit:` rule is the foundations plan's (Task 2.1).
public enum LinkPolicy {
    public static let schemes = ["http", "https", "mailto", "tel", "noteit"]

    /// A `noteit:` href must name the note host (`noteit://note/<id>` or `noteit://note?title=…`); this is the interim
    /// rule until note links get their own parser.
    public static func allows(_ href: String) -> Bool {
        guard let components = URLComponents(string: href), let scheme = components.scheme?.lowercased(),
              schemes.contains(scheme) else { return false }
        if scheme == "noteit" { return components.host?.lowercased() == "note" }
        return true
    }
}
