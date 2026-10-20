import Foundation

/// `_attachments/` naming and relative paths (markdown-storage spec §3.4). Paths are content-relative, `/`-separated,
/// with no leading `/`.
public enum AttachmentPaths {
    public static let folder = "_attachments"

    /// `<first 12 hex of SHA-256>-<sanitized original name>`.
    public static func fileName(sha256: String, originalName: String) -> String {
        String(sha256.lowercased().prefix(12)) + "-" + sanitized(originalName)
    }

    /// The path of `fileName` in `_attachments/` as written in the note at `notePath`.
    public static func relativePath(fromNoteAt notePath: String, fileName: String) -> String {
        let depth = components(of: notePath).count - 1
        return String(repeating: "../", count: max(0, depth)) + folder + "/" + fileName
    }

    /// A reference written in the note at `notePath` → a content-relative path, or nil when it leaves the content
    /// folder or isn't a relative path.
    public static func resolve(_ reference: String, fromNoteAt notePath: String) -> String? {
        let decoded = reference.removingPercentEncoding ?? reference
        guard !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.contains("://"), !decoded.lowercased().hasPrefix("file:") else {
            return nil
        }
        var parts = components(of: notePath)
        parts.removeLast()
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    static func components(of path: String) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return parts.isEmpty ? [""] : parts
    }

    /// Characters that are unsafe in a file name on macOS, Windows or in Markdown links become `-`; the name keeps
    /// its extension and is cut to 100 characters.
    static func sanitized(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|#[]^").union(.controlCharacters).union(.newlines)
        var result = String(String.UnicodeScalarView(name.unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }))
            .trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.isEmpty { result = "attachment" }
        guard result.count > 100 else { return result }
        let ext = (result as NSString).pathExtension
        let stem = (result as NSString).deletingPathExtension
        let keep = ext.isEmpty ? 100 : max(1, 100 - ext.count - 1)
        return String(stem.prefix(keep)) + (ext.isEmpty ? "" : "." + ext)
    }
}
