import AppKit
import Foundation
import NoteItMarkdown

/// The on-disk format of a library's note bodies. Owned by the markdown-storage plan; built in foundations Task 4.1.
enum LibraryFormatKind: String, Codable, Sendable {
    case rtfd, markdown
}

/// A body as read from storage. `extras`: the container fields kept beside the text (`ContainerExtras`).
/// `RTFDBodyStorage` always reads `.empty` and ignores extras on write; on an RTFD store `NoteStore` keeps them in
/// the body-extras sidecar instead (NoteStore+BodyExtras.swift). Owned by the foundations plan (Task 4.1).
struct StoredBody {
    var text: NSAttributedString
    var readOnlyReason: String? = nil
    var extras: ContainerExtras = .empty
    /// A Markdown file's front matter keys that NoteIt owns (`id:`, `created:`…), as read; nil for other formats.
    /// Its `extra` is empty: unknown keys are in `extras.frontMatter`. Never written back (spec §3.3).
    var frontMatter: FrontMatter? = nil
}

extension StoredBody {
    /// readOnlyReason of an RTFD note whose body-extras sidecar exists but can't be read or decoded (Task 4.1).
    static let bodyExtrasUnreadable =
        "This note’s extra data (its body-extras file) couldn’t be read, so edits to it won’t be saved. The file was left as it is."
}

/// Where and how a library keeps its note bodies. Owned by the foundations plan (Task 4.1); markdown-storage adds
/// `MarkdownBodyStorage`, sync-security the sealed-file methods. The `notebook:` parameters are unused by RTFD
/// and are passed through for the Markdown storage.
protocol NoteBodyStorage: AnyObject, Sendable {
    var kind: LibraryFormatKind { get }
    /// RTFD: `<rootURL>/notes`.
    var contentRootURL: URL { get }
    func idsOnDisk() -> [UUID]
    /// Throws `CocoaError(.fileReadNoSuchFile)` when the note has no body.
    func read(_ id: UUID) throws -> StoredBody
    func write(_ text: NSAttributedString, extras: ContainerExtras, for note: NoteMeta, notebook: Notebook?) throws
    /// RTFD: no-op.
    func writeMetadataOnly(for note: NoteMeta, notebook: Notebook?) throws
    /// Safe off the main actor. `meta` is the note the body is for; Markdown writes the front matter keys NoteIt
    /// owns from it (spec §3.3).
    func prepareTemp(_ text: NSAttributedString, extras: ContainerExtras, meta: NoteMeta) throws -> URL
    func installTemp(_ temp: URL, for note: NoteMeta, notebook: Notebook?) throws
    /// RTFD: `<rootURL>/.trash/<id>-<timestamp>.rtfd`.
    func moveToTrash(_ id: UUID) throws
    /// The newest trashed copy, if any.
    func recover(_ id: UUID) throws -> StoredBody?
    func removePermanently(_ id: UUID) throws
    /// What `contentRevisions` hashes; RTFD: the `.rtfd` package.
    func revisionInputURL(for id: UUID) -> URL?
    func fileURL(for id: UUID) -> URL
    func recoveryCopy(_ text: NSAttributedString, for id: UUID, in directory: URL) throws -> URL
    /// RTFD: no-op.
    func renameNotebook(_ notebook: Notebook, from oldName: String) throws
    /// RTFD: no-op.
    func removeNotebook(_ notebook: Notebook) throws
}
