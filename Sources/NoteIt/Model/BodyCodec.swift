import AppKit
import Foundation
import NoteItDoc
import NoteItDocAppKit
import NoteItMarkdown

/// The one body codec type, with no registry. Owned by the foundations plan (Task 4.2; program §6).
/// `rtfd` is the editor's NSAttributedString as RTFD libraries store it (an `.rtfd` package); `noteItDoc` is a
/// self-contained `.noteitdoc` file. `markdown` is a standalone `.md` file in the library flavour, with its images and
/// attachments in `_attachments/` beside it (markdown-storage Task 2.4).
///
/// Sync's body encoding: a `noteit-doc` body is built with `noteItDoc(of: text, extras: bodyExtras[id] ?? .empty)`
/// before sealing, and an incoming one is applied with `attributedString(from:)`, writing with the returned extras
/// and storing them in `bodyExtras[id]` only after the body is installed (Task 4.1). Wave 0 sync still sends RTFD.
enum BodyCodec: String, CaseIterable, Sendable {
    case rtfd
    case noteItDoc
    case markdown

    var fileExtension: String {
        switch self {
        case .rtfd: "rtfd"
        case .noteItDoc: "noteitdoc"
        case .markdown: "md"
        }
    }

    /// `.rtfd` reads `extras` as `.empty`. `.markdown` reads either flavour, takes relative image and attachment
    /// paths from inside the file's folder, and returns the unknown front matter keys as `extras.frontMatter` and the
    /// known ones as `frontMatter`.
    func read(at url: URL) throws -> StoredBody {
        switch self {
        case .rtfd:
            return StoredBody(text: try RTFDBodyStorage.readBody(at: url))
        case .noteItDoc:
            return try Self.attributedString(from: BodyContainer.decode(Data(contentsOf: url)))
        case .markdown:
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw MarkdownError.notUTF8 }
            let folder = url.deletingLastPathComponent()
            let imported = MarkdownCodec.resolvingAttachments(try MarkdownCodec.parse(text)) { path in
                Self.fileInside(folder, path: path).flatMap { try? Data(contentsOf: $0) }
            }
            var stored = try Self.attributedString(from: imported.body)
            var known = imported.frontMatter
            known.extra = ""
            stored.frontMatter = known
            return stored
        }
    }

    /// Replaces `url` atomically. `.rtfd` ignores `extras`; `.noteItDoc` writes one file with the attachments and
    /// `extras` inside; `.markdown` writes the attachments to `_attachments/` beside the file and front matter with
    /// the keys NoteIt owns taken from `meta` (none without it) followed by `extras.frontMatter`. Only `.markdown`
    /// reads `meta`.
    func write(_ text: NSAttributedString, extras: ContainerExtras = .empty, meta: NoteMeta? = nil, to url: URL) throws {
        switch self {
        case .rtfd:
            let temp = try RTFDBodyStorage.writeTempBody(text, in: url.deletingLastPathComponent())
            try RTFDBodyStorage.installBody(temp, at: url)
        case .noteItDoc:
            try data(of: text, extras: extras).write(to: url, options: .atomic)
        case .markdown:
            let container = try Self.noteItDoc(of: text, extras: extras)
            let folder = url.deletingLastPathComponent().appendingPathComponent(AttachmentPaths.folder, isDirectory: true)
            for (sha, attachment) in container.attachments {
                let file = folder.appendingPathComponent(AttachmentPaths.fileName(sha256: sha, originalName: attachment.name))
                guard !FileManager.default.fileExists(atPath: file.path) else { continue }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try attachment.data.write(to: file, options: .atomic)
            }
            try Data(Self.markdown(of: container, frontMatter: Self.frontMatter(meta, extras: extras), profile: .library).utf8)
                .write(to: url, options: .atomic)
        }
    }

    /// The bytes `write(_:extras:meta:to:)` stores; for `.rtfd`, the package's flat-file serialization.
    func data(of text: NSAttributedString, extras: ContainerExtras = .empty, meta: NoteMeta? = nil) throws -> Data {
        switch self {
        case .rtfd:
            guard let data = text.rtfd(from: NSRange(location: 0, length: text.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        case .noteItDoc:
            return try Self.noteItDoc(of: text, extras: extras).encoded()
        case .markdown:
            return Data(Self.markdown(of: try Self.noteItDoc(of: text, extras: extras), frontMatter: Self.frontMatter(meta, extras: extras),
                                      profile: .library).utf8)
        }
    }

    // MARK: Format-independent

    /// Plain text with list markers as `- `, `1. `, `☐ ` and `☑ `, and tables as tab-separated rows.
    @MainActor
    static func plainText(of text: NSAttributedString) -> String {
        var lines: [String] = []
        for block in NoteBlocks.parse(text) {
            switch block {
            case .paragraph(_, _, let runs):
                lines.append(plainLine(runs))
            case .listItem(let marker, let level, _, let runs):
                let prefix: String
                switch marker {
                case .bullet: prefix = "- "
                case .numbered(let n): prefix = "\(n). "
                case .checkbox(let checked): prefix = (checked ? EditorStyle.checkedBox : EditorStyle.uncheckedBox) + " "
                }
                lines.append(String(repeating: "  ", count: level) + prefix + plainLine(runs))
            case .code(let code, _):
                lines.append(code)
            case .divider:
                lines.append("---")
            case .table(let rows):
                lines.append(rows.map { $0.map { plainLine($0).replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n"))
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private static func plainLine(_ runs: [InlineRun]) -> String {
        NoteBlocks.plainText(runs).replacingOccurrences(of: NoteBlocks.lineBreak, with: "\n")
            .trimmingCharacters(in: .whitespaces)
    }

    @MainActor
    static func html(of text: NSAttributedString, title: String) -> String {
        HTMLWriter.write(text, title: title)
    }

    // MARK: noteit-doc container

    /// The container's `extras` are `extras`.
    static func noteItDoc(of text: NSAttributedString, extras: ContainerExtras = .empty,
                          imagePolicy: ImagePolicy = .normalize) throws -> BodyContainer {
        var container = try DocConverter.export(text, styles: AppDocStyleProvider.shared, imagePolicy: imagePolicy)
        container.extras = extras
        return container
    }

    /// `extras` are the container's.
    static func attributedString(from container: BodyContainer) throws -> StoredBody {
        StoredBody(text: try DocConverter.importDocument(container, styles: AppDocStyleProvider.shared),
                   extras: container.extras)
    }

    /// True when both texts export to the same noteit-doc bytes.
    static func semanticallyEqual(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        guard let left = try? noteItDoc(of: a).encoded(), let right = try? noteItDoc(of: b).encoded() else { return false }
        return left == right
    }
}

// MARK: Markdown

extension BodyCodec {
    /// `text` as a standalone Markdown file; images and attachments point into `_attachments/`.
    static func markdown(of text: NSAttributedString, profile: MarkdownProfile) throws -> String {
        markdown(of: try noteItDoc(of: text), profile: profile)
    }

    /// Markdown from outside the library (automation, plugins, the web clipper).
    static func attributedString(fromMarkdown text: String, options: MarkdownImportOptions) async throws
        -> (NSAttributedString, unresolvedImages: [AttachmentRef]) {
        let imported = try await MarkdownCodec.importDocument(text, options: options)
        return (try DocConverter.importDocument(imported.body, styles: AppDocStyleProvider.shared), imported.unresolvedImages)
    }

    /// The keys NoteIt owns always come from the note itself (markdown-storage spec §3.3), never from what was read.
    static func frontMatter(_ meta: NoteMeta?, extras: ContainerExtras) -> FrontMatter {
        var frontMatter = FrontMatter(extra: extras.frontMatter ?? "")
        guard let meta else { return frontMatter }
        frontMatter.id = meta.id
        frontMatter.created = meta.createdAt
        frontMatter.updated = meta.updatedAt
        frontMatter.pinned = meta.isPinned
        frontMatter.deleted = meta.deletedAt
        frontMatter.conflictOf = meta.conflictOriginalID
        frontMatter.conflictSource = meta.conflictSource
        frontMatter.locked = meta.lock != nil
        return frontMatter
    }

    /// `path` (already percent-decoded) from a note in `folder`, or nil when it leaves the folder, also through a
    /// symbolic link.
    static func fileInside(_ folder: URL, path: String) -> URL? {
        guard let relative = AttachmentPaths.resolve(decoded: path, fromNoteAt: "note.md") else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let file = folder.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        return file.path.hasPrefix(root.path + "/") ? file : nil
    }

    fileprivate static func markdown(of container: BodyContainer, frontMatter: FrontMatter = .empty, profile: MarkdownProfile) -> String {
        MarkdownCodec.serialize(container, frontMatter: frontMatter, profile: profile, attachmentPath: { sha in
            let name = container.attachments[sha]?.name ?? ""
            return AttachmentPaths.folder + "/" + AttachmentPaths.fileName(sha256: sha, originalName: name)
        }, previous: nil)
    }
}
