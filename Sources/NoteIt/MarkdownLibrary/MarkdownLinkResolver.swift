import Foundation
import NoteItDoc
import NoteItMarkdown

/// Wiki-link targets of a Markdown library ↔ note ids, through `markdown-files.json` (spec §3.4, linking's rules):
/// exact content path, then a unique file name, then a unique path suffix (`[[Folder/Name]]`), then a former path
/// of a renamed file. Linking's import resolver is the `WikiLinkResolver` typealias, hence the name.
final class MarkdownLinkResolver: @unchecked Sendable {
    static let staleType = "noteit-stale-link"

    private let index: MarkdownPathIndex

    init(index: MarkdownPathIndex) {
        self.index = index
    }

    func noteID(for target: String, fromNoteAt notePath: String) -> UUID? {
        let target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let bare = Self.withoutMarkdownExtension(target)
        for candidate in [bare + ".md", bare + ".markdown", target] {
            if let id = index.id(forPath: candidate) { return id }
        }
        let components = bare.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty else { return nil }
        if components.count == 1, let id = unique(index.ids(withStem: components[0])) { return id }
        if components.count > 1, let id = unique(index.ids(withPathSuffix: components, former: false)) { return id }
        return unique(index.ids(withPathSuffix: components, former: true))
    }

    /// The file name without `.md`, or the content-relative path when that name isn't unique.
    func target(for id: UUID) -> String? {
        guard let entry = index.entry(id) else { return nil }
        if index.ids(withStem: entry.stem).count > 1 {
            return Self.withoutMarkdownExtension(entry.path)
        }
        return entry.stem
    }

    /// `parsed` with each block that links to a note under a name that is no longer its target swapped for a
    /// node nothing equals, so the writer writes that block anew with the current name.
    func withoutStaleLinks(_ parsed: ParsedMarkdown) -> ParsedMarkdown {
        guard case .doc(let blocks) = parsed.body.doc, blocks.count == parsed.sourceMap.blocks.count else { return parsed }
        var result = parsed
        var changed = false
        let kept: [DocNode] = zip(blocks, parsed.sourceMap.blocks).map { node, range in
            let ids = Self.noteLinkIDs(in: node)
            guard !ids.isEmpty else { return node }
            let source = parsed.source[range]
            for id in ids {
                if let name = target(for: id), !source.contains("[[" + name) {
                    changed = true
                    return .unknown(type: Self.staleType, json: Data())
                }
            }
            return node
        }
        guard changed else { return parsed }
        result.body.doc = .doc(kept)
        return result
    }

    static func noteLinkIDs(in node: DocNode) -> [UUID] {
        func inline(_ content: [Inline]) -> [UUID] {
            content.flatMap { item -> [UUID] in
                guard case .text(_, let marks) = item else { return [] }
                return marks.compactMap { mark in
                    guard case .link(let href) = mark, href.hasPrefix("noteit://note/") else { return nil }
                    let rest = href.dropFirst("noteit://note/".count)
                    return UUID(uuidString: String(rest.prefix { $0 != "?" }))
                }
            }
        }
        switch node {
        case .doc(let children), .blockquote(_, let children):
            return children.flatMap(noteLinkIDs)
        case .paragraph(_, _, let content), .heading(_, _, _, let content), .codeBlock(_, _, let content),
             .listItem(_, _, _, _, _, let content):
            return inline(content)
        case .table(_, let rows):
            return rows.flatMap { $0.flatMap { $0.content.flatMap(noteLinkIDs) } }
        case .horizontalRule, .unknown:
            return []
        }
    }

    private func unique(_ ids: [UUID]) -> UUID? {
        ids.count == 1 ? ids[0] : nil
    }

    static func withoutMarkdownExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" ? (path as NSString).deletingPathExtension : path
    }
}
