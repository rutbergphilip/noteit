import Foundation
import NoteItDoc

public enum MarkdownError: Error, Equatable {
    case invalidFrontMatter(line: Int)
    case notUTF8
}

/// The two flavours of program §6. `library`: lossless, with NoteIt comments and fallback blocks (Markdown
/// libraries, backups, plugins). `portable`: clean Markdown with no NoteIt comments and no `data-size`
/// (Local API and MCP reads by default, web clipper input). `parse` reads both.
public enum MarkdownProfile: Sendable { case library, portable }

/// Options for Markdown that comes from outside the library (web clipper, importers, Local API writes).
public struct MarkdownImportOptions: Sendable {
    public var baseURL: URL?
    public var resolveImage: @Sendable (URL) async -> Data?
    public var resolveNoteLink: @Sendable (String) -> UUID?

    public init(baseURL: URL? = nil,
                resolveImage: @escaping @Sendable (URL) async -> Data? = { _ in nil },
                resolveNoteLink: @escaping @Sendable (String) -> UUID? = { _ in nil }) {
        self.baseURL = baseURL
        self.resolveImage = resolveImage
        self.resolveNoteLink = resolveNoteLink
    }
}

public struct ImportedMarkdown: Sendable, Equatable {
    public var frontMatter: FrontMatter
    /// Images resolved into attachments, keyed by SHA-256.
    public var body: BodyContainer
    /// Images that `resolveImage` couldn't provide or that are over `AttachmentLimit`; dropped from the body.
    public var unresolvedImages: [AttachmentRef]

    public init(frontMatter: FrontMatter, body: BodyContainer, unresolvedImages: [AttachmentRef]) {
        self.frontMatter = frontMatter
        self.body = body
        self.unresolvedImages = unresolvedImages
    }
}

public struct ParsedMarkdown: Sendable, Equatable {
    public var frontMatter: FrontMatter
    /// Attachments empty; an image's or attachment's `sha` is its path as written, percent-decoded.
    public var body: BodyContainer
    /// In document order, without duplicates.
    public var attachmentRefs: [AttachmentRef]
    /// Top-level block index → range in `source`.
    public var sourceMap: SourceMap
    public var source: String

    public init(frontMatter: FrontMatter, body: BodyContainer, attachmentRefs: [AttachmentRef], sourceMap: SourceMap, source: String) {
        self.frontMatter = frontMatter
        self.body = body
        self.attachmentRefs = attachmentRefs
        self.sourceMap = sourceMap
        self.source = source
    }
}

public struct AttachmentRef: Sendable, Equatable, Hashable {
    /// As written, percent-decoded.
    public var path: String
    public var displayName: String
    /// `![name|480](…)`
    public var width: Int?

    public init(path: String, displayName: String, width: Int? = nil) {
        self.path = path
        self.displayName = displayName
        self.width = width
    }
}

public struct SourceMap: Sendable, Equatable {
    public var blocks: [Range<String.Index>]

    public init(blocks: [Range<String.Index>]) {
        self.blocks = blocks
    }
}

public enum MarkdownCodec {
    /// Reads Markdown in either profile. `resolveNoteLink` maps a wiki-link target to a note id; nil = unresolved.
    /// Throws only `MarkdownError.invalidFrontMatter`.
    public static func parse(_ text: String, resolveNoteLink: (String) -> UUID? = { _ in nil }) throws -> ParsedMarkdown {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let (frontMatter, bodyStart) = try FrontMatter.read(source)
        return withoutActuallyEscaping(resolveNoteLink) { resolve in
            var parser = BlockParser(resolveNoteLink: resolve)
            var lines = BlockParser.lines(of: source, from: bodyStart)
            if bodyStart != source.startIndex, lines.first?.isBlank == true { lines.removeFirst() }
            let blocks = parser.parseBlocks(lines)
            var seen = Set<AttachmentRef>()
            let refs = parser.inline.refs.filter { seen.insert($0).inserted }
            let body = BodyContainer(doc: .doc(blocks.map(\.0)), attachments: [:],
                                     frontMatter: frontMatter.extra.isEmpty ? nil : frontMatter.extra)
            return ParsedMarkdown(frontMatter: frontMatter, body: body, attachmentRefs: refs,
                                  sourceMap: SourceMap(blocks: blocks.map(\.1)), source: source)
        }
    }

    /// Writes `body` in `profile`. `attachmentPath` maps an attachment's SHA-256 to its path relative to the note;
    /// `noteLinkName` maps a linked note to its wiki-link target (nil: the link's text). With `previous`, the
    /// blocks that didn't change keep their source text. `library` output reads back as the same document.
    public static func serialize(_ body: BodyContainer, frontMatter: FrontMatter, profile: MarkdownProfile,
                                 attachmentPath: (String) -> String, noteLinkName: (UUID) -> String? = { _ in nil },
                                 previous: ParsedMarkdown?) -> String {
        write(body, frontMatter: frontMatter, profile: profile, attachmentPath: attachmentPath, noteLinkName: noteLinkName,
              previous: previous).text
    }

    static func write(_ body: BodyContainer, frontMatter: FrontMatter, profile: MarkdownProfile,
                      attachmentPath: (String) -> String, noteLinkName: (UUID) -> String? = { _ in nil },
                      previous: ParsedMarkdown?) -> MarkdownWriter.Output {
        var front: FrontMatter
        switch profile {
        case .library:
            front = frontMatter
            if front.extra.isEmpty, let extra = body.frontMatter { front.extra = extra }
        case .portable:
            front = FrontMatter(id: frontMatter.id)
        }
        let header = front.written()
        let blocks: [DocNode] = if case .doc(let content) = body.doc { content } else { [body.doc] }
        let readable = blocks.map { MarkdownWriter.readable($0, attachmentPath: attachmentPath, profile: profile) }
        return withoutActuallyEscaping(noteLinkName) { name in
            let writer = MarkdownWriter(profile: profile, noteLinkName: name, header: header)
            var output = writer.write(readable, previous: profile == .library ? previous : nil)
            output.text = header + output.text
            return output
        }
    }
}
