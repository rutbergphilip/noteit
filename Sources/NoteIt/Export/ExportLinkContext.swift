import Foundation
import NoteItCore

/// How note links are written in an export: the titles of linked notes, and the file names of the
/// notes that are part of the same export.
struct ExportLinkContext {
    /// nil when the note doesn't exist.
    var title: (UUID) -> String?
    /// The exported file name without extension; nil when the note isn't part of this export.
    var exportedName: (UUID) -> String?
    /// The folder, within the export, that holds the note's file.
    var folder: (UUID) -> String? = { _ in nil }
    /// The note being written, for relative links between folders.
    var source: UUID?

    static let titlesOnly = ExportLinkContext(title: { _ in nil }, exportedName: { _ in nil })

    static func titles(_ title: @escaping (UUID) -> String?) -> ExportLinkContext {
        ExportLinkContext(title: title, exportedName: { _ in nil })
    }

    static func files(_ files: [NotesExport.File], titles: [UUID: String]) -> ExportLinkContext {
        var names: [UUID: String] = [:]
        var folders: [UUID: String] = [:]
        for file in files {
            names[file.note.id] = file.url.deletingPathExtension().lastPathComponent
            folders[file.note.id] = file.url.deletingLastPathComponent().lastPathComponent
        }
        return ExportLinkContext(title: { titles[$0] }, exportedName: { names[$0] }, folder: { folders[$0] })
    }

    func from(_ source: UUID) -> ExportLinkContext {
        var copy = self
        copy.source = source
        return copy
    }

    /// The wiki-link name for `link`, or nil to write only its text.
    func wikiName(for link: NoteLink) -> String? {
        switch link {
        case let .note(id, _):
            if let name = exportedName(id) { return name }
            return title(id).map { Self.cleaned($0, removing: "[]|#^") }.flatMap { $0.isEmpty ? nil : $0 }
        case let .unresolved(title, _):
            let name = Self.cleaned(title, removing: "[]|#^")
            return name.isEmpty ? nil : name
        }
    }

    /// `[[Name]]`, `[[Name#Heading]]` and `[[Name|text]]`, or nil to write only the text.
    func wikiLink(for link: NoteLink, text: String) -> String? {
        guard let name = wikiName(for: link) else { return nil }
        var out = "[[" + name
        if let heading = link.heading.map({ Self.cleaned($0, removing: "[]|#^") }), !heading.isEmpty { out += "#" + heading }
        let shown = Self.cleaned(text, removing: "[]|").trimmingCharacters(in: .whitespaces)
        if !shown.isEmpty, shown != name { out += "|" + shown }
        return out + "]]"
    }

    /// A relative link to the linked note's exported file, or nil when it isn't in this export.
    func href(for link: NoteLink, fileExtension: String) -> String? {
        guard case let .note(id, heading) = link, let name = exportedName(id) else { return nil }
        var parts = [name + "." + fileExtension]
        if let target = folder(id), target != source.flatMap(folder) { parts = ["..", target] + parts }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?;")
        var out = parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
        if let heading, !heading.isEmpty { out += "#" + HeadingSlug.slug(heading) }
        return out
    }

    private static func cleaned(_ s: String, removing characters: String) -> String {
        let set = Set(characters)
        return String(s.filter { !set.contains($0) && !$0.isNewline })
    }
}

/// HTML `id`s for headings: lowercased, with runs of other characters turned into `-`.
enum HeadingSlug {
    static func slug(_ text: String) -> String {
        var out = ""
        var dash = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                if dash, !out.isEmpty { out += "-" }
                out.append(ch)
                dash = false
            } else {
                dash = true
            }
        }
        return out.isEmpty ? "heading" : out
    }

    /// Slugs unique within one document: `name`, `name-2`, `name-3`…
    struct Unique {
        private var used: [String: Int] = [:]
        mutating func next(_ text: String) -> String {
            let base = HeadingSlug.slug(text)
            let n = (used[base] ?? 0) + 1
            used[base] = n
            return n == 1 ? base : "\(base)-\(n)"
        }
    }
}
