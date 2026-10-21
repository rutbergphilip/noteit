# NoteIt Markdown Storage Implementation Plan

**Goal:** Add an optional Markdown folder library format (plain `.md` files, front matter, `_attachments/`, external edits watched), a Settings › Your Data tab with Back Up Everything and automatic backups, restore drills for backups and for the sync storage, and importers for Evernote `.enex` and Notion exports. Sync, its remote format and its encryption stay as they are.

**Architecture:**
- A new pure library target, `NoteItMarkdown` (macOS and iOS, depends only on `NoteItDoc`, Foundation only), converts between Markdown text and the `noteit-doc` tree (`DocNode`, `BodyContainer`). It has no AppKit and no file I/O and is tested with golden fixtures and random documents from `NoteItDocTestSupport`. It is the only lossless Markdown path in NoteIt; the Local API, MCP, plugins, the web clipper and the phone use it (program §6). It writes two flavours (`MarkdownProfile`): `library` (lossless, for Markdown libraries, backups and plugins) and `portable` (clean, the default for Local API and MCP reads and for web clipper input); `parse` reads both. `MarkdownImportOptions.resolveImage` fetches images for the web clipper and the importers.
- Body I/O already goes through `NoteBodyStorage` and `BodyCodec`, which foundations adds (program §2 step 4) together with `RTFDBodyStorage`. This plan adds `MarkdownBodyStorage` (files, front matter, nested notebook folders, attachments, `.trash/`, path index) and `case markdown` of `BodyCodec`, written inside foundations' enum body with a branch added to each of its switches (there is no codec registry, program §6; Swift can't add a case in an extension). Task 2.4 adds the case, its branches and the library-free static helpers; Task 3.2 adds the library static helpers.
- `MarkdownFolderWatcher` (FSEvents) feeds external changes into `NoteStore` as local edits; a write ledger filters NoteIt's own writes; a mass-deletion guard holds large batches of deletions (program §11).
- `LibraryConverter` converts in both directions through a staging folder with verification and a single commit point (`library-location.json`).
- `BackupWriter`, `BackupReader` and `BackupScheduler` handle ZIPs; `RemoteRestoreDrill` in `NoteItSync` checks the remote store read-only.
- `EvernoteImporter` and `NotionImporter` plug into the existing import sheet and `ImportReport`.
- Two Local API routes, `markdown-storage.library` and `markdown-storage.backup`, are registered through `LocalAPIRouteRegistry`.
- Every derived and per-Mac file stays in `NoteStore.rootURL` (the data folder). The Markdown library's own folder is `contentRootURL` (program §7).
- Locked notes ship in wave 3 with sync-security's milestone M5 (program §1, §8), so there are none before then. Milestones 1–9 are wave 1: they have no lock handling beyond what foundations already has (`NoteMeta.lock` as data) and use none of sync-security's lock types. Milestone 10 (wave 3, after sync-security Task 5.1) adds locked notes: sealed files and placeholders in a Markdown library, sealed files in conversion, backups, restore and the restore drills.

**Tech Stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftPM, Foundation, AppKit, SwiftUI, CoreServices (FSEvents), CryptoKit (SHA-256), `XMLParser`. `ditto` for ZIPs, as the existing importer already does. No third-party dependencies.

**Spec:** `docs/specs/2026-10-19-markdown-storage-design.md`. Program contract: `docs/specs/2026-10-19-program-design.md`, which wins where they disagree.

**Prerequisite:** wave 0 (`docs/plans/2026-10-19-foundations.md`) is merged: the `NoteItDoc` / `NoteItDocAppKit` / `NoteItDocTestSupport` split with code block `language`, `ImagePolicy`, the `frontMatter` field and `.noteitdoc` naming (step 2); `StoreSession` and manifest features (step 3); `NoteBodyStorage`, `BodyCodec`, `NoteStore.editBody`, the `DerivedIndex` registry and `NoteMeta.lock` (step 4); `LocalAPIRouteRegistry` (step 5); the frozen Settings tab, menu and palette tables (step 6). None of these are planned here.

---

## Conventions for every task

- Test command (from the repository root): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite> 2>&1 | tail -20`. Expected: `Executed N tests, with 0 failures`.
- App build: `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3` must both end with `Build complete!` and 0 errors.
- Never touch real user data in `~/Library/Application Support/NoteIt` or a real Markdown folder. When running the app, set `NOTEIT_DATA_DIR=<project>/.selftest/<name>`; Markdown content folders used in manual checks go under `<project>/.selftest/<name>-md/`.
- Tests that need folders create them under `FileManager.default.temporaryDirectory` with a UUID name and remove them in `tearDown`, as `MarkdownRoundTripTests` does.
- Commit after each task with Conventional Commits, scope `storage`, `markdown`, `backup` or `import`, e.g. `feat(markdown): parse block attributes`. Never amend, rebase or force.
- No `#Preview`. Comments only where something is non-obvious.
- No file outside `NoteStore`, the `NoteBodyStorage` implementations, `LibraryConverter` and `Backup/` reads or writes note bodies.
- Code outside the editor changes note text only through `NoteStore.editBody` (program §6). Derived data is kept in step only through the `DerivedIndex` registry; this plan adds no hook to `NoteStore.swift` (program §7).
- Nothing derived or per-Mac is written into `contentRootURL`; it all goes into `NoteStore.rootURL`.
- References to existing code use symbol names, never line numbers.
- User-facing strings are copied exactly from the spec.

## File structure

New:

| Path | Responsibility |
|---|---|
| `Sources/NoteItMarkdown/MarkdownCodec.swift` | `parse` / `serialize` / `importDocument` entry points, flavours (`MarkdownProfile`), `MarkdownImportOptions` |
| `Sources/NoteItMarkdown/FrontMatter.swift` | Front matter model, reader and writer (YAML subset) |
| `Sources/NoteItMarkdown/BlockParser.swift` | CommonMark + GFM block structure with source ranges |
| `Sources/NoteItMarkdown/InlineParser.swift` | Emphasis, code, links, `==`, `<u>`, `<mark>`, `<span>` |
| `Sources/NoteItMarkdown/BlockWriter.swift` | Canonical block output, block attribute comments, rich-block fallback |
| `Sources/NoteItMarkdown/InlineWriter.swift` | Canonical mark nesting and minimal escaping |
| `Sources/NoteItMarkdown/SourcePreservation.swift` | Reuse of unchanged block bytes |
| `Sources/NoteItMarkdown/AttachmentPaths.swift` | `_attachments/` naming and relative path resolution |
| `Sources/NoteItMarkdown/WikiLinks.swift` | `[[File name|text]]` / `[[File name#Heading]]` syntax (`[[File name\|text]]` in table cells), read and write through resolver closures |
| `Tests/NoteItMarkdownTests/{CodecGoldenTests,CodecPropertyTests,FrontMatterTests,ForeignMarkdownTests,EscapingTests,SourcePreservationTests,WikiLinkSyntaxTests,CorpusTests,AttachmentPathsTests}.swift` | Tests |
| `Tests/NoteItMarkdownTests/Fixtures/*.md`, `*.json` | Golden pairs; `foreign/` from Obsidian, Bear, iA Writer |
| `Sources/NoteIt/Model/LibraryLocationFile.swift` | `library-location.json` read/write |
| `Sources/NoteIt/MarkdownLibrary/MarkdownBodyStorage.swift` | `NoteBodyStorage` for Markdown: files, front matter, notebook folders, `.trash/` |
| `Sources/NoteIt/MarkdownLibrary/MarkdownPathIndex.swift` | `markdown-files.json`, unique names, renames, `formerPaths`, path → id map |
| `Sources/NoteIt/MarkdownLibrary/NotebookFolders.swift` | Nested notebook folders up to depth 4, `.noteit-notebook.json` with unknown keys kept |
| `Sources/NoteIt/MarkdownLibrary/WikiLinkResolver.swift` | Path → id and id → name lookups passed to `MarkdownCodec` |
| `Sources/NoteIt/MarkdownLibrary/LockedNoteFiles.swift` | Milestone 10 (wave 3): `.noteit/locked/<uuid>.sealed`, placeholders, lock rebuilt from the sealed header |
| `Sources/NoteIt/MarkdownLibrary/AttachmentStore.swift` | `_attachments/`, reference counting, delayed cleanup |
| `Sources/NoteIt/MarkdownLibrary/MarkdownFolderWatcher.swift` | FSEvents stream, debounce, write ledger |
| `Sources/NoteIt/MarkdownLibrary/FolderScanner.swift` | Launch and rescan diffing |
| `Sources/NoteIt/MarkdownLibrary/MassDeletionGuard.swift` | Holds deletion batches over the program §11 threshold |
| `Sources/NoteIt/MarkdownLibrary/ExternalChangeHandler.swift` | Applies scan results to `NoteStore`, conflict copies |
| `Sources/NoteIt/MarkdownLibrary/NoteStore+Markdown.swift` | `NoteStore` entry points used by the watcher |
| `Sources/NoteIt/MarkdownLibrary/LibraryConverter.swift` | Conversion both ways, adoption, staging, verification, commit |
| `Sources/NoteIt/MarkdownLibrary/PreviousLibrary.swift` | Previous library row and the 30-day question |
| `Sources/NoteIt/MarkdownLibrary/ConvertLibrarySheet.swift` | Conversion sheet UI |
| `Sources/NoteIt/Backup/BackupWriter.swift` | Back Up Everything ZIP |
| `Sources/NoteIt/Backup/BackupManifest.swift` | `manifest.json` model |
| `Sources/NoteIt/Backup/BackupReader.swift` | Unzip, verify, parse; Check a Backup |
| `Sources/NoteIt/Backup/BackupRestorer.swift` | Restore Missing (and Changed) Notes |
| `Sources/NoteIt/Backup/BackupScheduler.swift` | Automatic backups, retention |
| `Sources/NoteIt/Backup/DataActions.swift` | Menu and palette actions, sheets |
| `Sources/NoteIt/Backup/DataAPIRoutes.swift` | Registers `markdown-storage.library` and `markdown-storage.backup` |
| `Sources/NoteIt/Settings/DataSettingsView.swift` | Your Data tab |
| `Sources/NoteIt/Import/EvernoteImporter.swift` | `.enex` streaming parser, ENML → HTML |
| `Sources/NoteIt/Import/NotionImporter.swift` | Notion Markdown & CSV export |
| `Sources/NoteItSync/Engine/RemoteRestoreDrill.swift` | Read-only remote check |
| `Tests/NoteItTests/{MarkdownBodyStorageTests,MarkdownPathIndexTests,NotebookFoldersTests,WikiLinkResolverTests,LockedMarkdownNoteTests,AttachmentStoreTests,FolderScannerTests,MassDeletionGuardTests,ExternalChangeTests,LibraryConverterTests,BackupTests,BackupSchedulerTests,DataAPIRoutesTests,EvernoteImporterTests,NotionImporterTests,MarkdownLibraryPerformanceTests}.swift` | App-level tests |
| `Tests/NoteItSyncTests/RemoteRestoreDrillTests.swift` | Drill against `InMemoryBackend` |
| `Tests/NoteItTests/Fixtures/{evernote,notion}/…` | Importer fixtures (created by the tests' builders where possible) |

Changed:

| Path | Change |
|---|---|
| `Package.swift` | `NoteItMarkdown` target (macOS and iOS, depends on `NoteItDoc` only), `NoteItMarkdownTests` (depends on `NoteItMarkdown`, `NoteItDocTestSupport`); `NoteIt` depends on `NoteItMarkdown` (mobile adds `NoteItMobileKit`'s dependency, program §1); `NoteItTests` gets `resources: [.copy("Fixtures")]`. `platforms` is not changed. |
| `BodyCodec` (foundations, same file) | `case markdown` in the enum body, a `.markdown` branch in `fileExtension`, `read(at:)`, `write(_:extras:to:)` and `data(of:extras:)` (`.md` ⇄ `StoredBody` through `MarkdownCodec` and `DocConverter`), and static Markdown helpers in an extension |
| `Tests/NoteItTests/BodyStorageContract.swift` (foundations) | Helper, also called for `MarkdownBodyStorage` |
| `Sources/NoteIt/Model/NoteStore.swift` | `libraryFormat`; metadata-only changes (pin, move, notebook rename or move) trigger file moves on `flush()` |
| `Sources/NoteIt/Model/VersionHistory.swift` | Reads and writes `.noteitdoc` as well as `.rtfd` |
| `Sources/NoteIt/App/LibraryLauncher.swift` | `LibraryLocation` gains `format`, `contentRootURL`; reads `library-location.json`; content-folder-missing handling |
| `Sources/NoteIt/App/ExportCommands.swift` | Back Up Everything…, Show Note File in Finder, in the File menu order of program §9 |
| `Sources/NoteIt/Palette/PaletteCommandRegistry.swift` | `backUpEverything`, `revealNoteFile`, `showYourData`, `checkBackup`, `checkSyncStorage` |
| `Sources/NoteIt/Settings/SettingsView.swift` | Fills in the frozen `data` tab (position 5) with `DataSettingsView` |
| `Sources/NoteIt/Settings/Preferences.swift` | New `PrefKey` cases |
| `Sources/NoteIt/Import/ImportSheet.swift` | `ImportSource.evernote`, `.notion` |
| `Sources/NoteIt/Model/NoteStore+Import.swift` | `ImportReport.rowsTruncated` counter |
| `Sources/NoteIt/Sync/SyncController.swift` | `checkSyncStorage()` using the current store session |
| `docs/architecture.md`, `docs/known-limitations.md`, `docs/roadmap.md`, `docs/development.md`, `README.md` | Storage section, limitations, self-test variable |

## Frozen interfaces

```swift
// Sources/NoteItMarkdown/MarkdownCodec.swift
import NoteItDoc

/// The two flavours of program §6. `library`: lossless, with NoteIt comments and fallback blocks (Markdown
/// libraries, backups, plugins). `portable`: clean Markdown with no NoteIt comments and no `data-size`
/// (Local API and MCP reads by default, web clipper input). `parse` reads both.
public enum MarkdownProfile: Sendable { case library, portable }

/// Options for Markdown that comes from outside the library (web clipper, importers, Local API writes).
public struct MarkdownImportOptions: Sendable {
    public var baseURL: URL?                                   // relative image paths resolve against it
    public var resolveImage: @Sendable (URL) async -> Data?    // nil = not available
    public var resolveNoteLink: @Sendable (String) -> UUID?
    public init(baseURL: URL? = nil,
                resolveImage: @escaping @Sendable (URL) async -> Data? = { _ in nil },
                resolveNoteLink: @escaping @Sendable (String) -> UUID? = { _ in nil })
}

public struct ImportedMarkdown: Sendable, Equatable {
    public var frontMatter: FrontMatter
    public var body: BodyContainer                // images resolved into attachments, keyed by SHA-256
    public var unresolvedImages: [AttachmentRef]  // nil from resolveImage or over AttachmentLimit; dropped from the body
}

public struct ParsedMarkdown: Sendable, Equatable {
    public var frontMatter: FrontMatter
    public var body: BodyContainer               // attachments empty; images reference `AttachmentRef`s
    public var attachmentRefs: [AttachmentRef]    // in document order
    public var sourceMap: SourceMap               // block index → byte range in the original text
    public var source: String
}

public struct AttachmentRef: Sendable, Equatable, Hashable {
    public var path: String                       // as written, percent-decoded
    public var displayName: String
    public var width: Int?                        // `![name|480](…)`
}

public struct SourceMap: Sendable, Equatable { public var blocks: [Range<String.Index>] }

public enum MarkdownCodec {
    public static func parse(_ text: String,
                             resolveNoteLink: (String) -> UUID? = { _ in nil })    // wiki-link target → note id; nil = unresolved
                             throws -> ParsedMarkdown                          // throws only MarkdownError.invalidFrontMatter
    public static func serialize(_ body: BodyContainer,
                                 frontMatter: FrontMatter,
                                 profile: MarkdownProfile,
                                 attachmentPath: (String) -> String,               // sha256 → relative path
                                 noteLinkName: (UUID) -> String? = { _ in nil },   // note id → wiki-link target; nil = title
                                 previous: ParsedMarkdown?) -> String
    public static func importDocument(_ text: String, options: MarkdownImportOptions)
                                      async throws -> ImportedMarkdown          // parse, then fetch each image once
    public static func resolvingAttachments(_ parsed: ParsedMarkdown, read: (String) -> Data?)
                                            -> ImportedMarkdown                 // the synchronous step, for BodyCodec.read
}

public enum MarkdownError: Error, Equatable { case invalidFrontMatter(line: Int), notUTF8 }

// Sources/NoteItMarkdown/FrontMatter.swift
public struct FrontMatter: Sendable, Equatable {
    public var id: UUID?
    public var created: Date?
    public var updated: Date?
    public var pinned: Bool
    public var deleted: Date?
    public var conflictOf: UUID?
    public var conflictSource: String?
    public var locked: Bool                         // written on placeholders only; ignored when reading (sealed file wins)
    public var tags: [String]                      // read only; never written by this sub-project
    public var extra: String                       // unknown keys, verbatim, original order
    public static let empty: FrontMatter
    public static func read(_ text: String) throws -> (FrontMatter, bodyStart: String.Index)
    public func written() -> String               // "" when nothing to write; ends with "---\n"
}

// Sources/NoteItMarkdown/AttachmentPaths.swift
public enum AttachmentPaths {
    public static let folder = "_attachments"
    public static func fileName(sha256: String, originalName: String) -> String   // "<12 hex>-<sanitized>"
    public static func relativePath(fromNoteAt notePath: String, fileName: String) -> String
    public static func resolve(_ reference: String, fromNoteAt notePath: String) -> String?  // content-relative or nil
}

// Sources/NoteItMarkdown/WikiLinks.swift
public struct WikiLink: Sendable, Equatable {
    public var target: String                      // file name or content-relative path, no ".md"
    public var heading: String?
    public var shownText: String?                  // nil when equal to target
    public func written(inTableCell: Bool = false) -> String   // "[[target#heading|shownText]]"; in a table cell the "|" is "\|"
}
```

```swift
// Defined by foundations (program §2 step 4). Shown for reference; foundations' definition wins.
// NoteBodyStorage: kind, contentRootURL, idsOnDisk, read, write, writeMetadataOnly, prepareTemp, installTemp,
// moveToTrash, recover, removePermanently, revisionInputURL, fileURL, recoveryCopy, renameNotebook, removeNotebook.
// write and prepareTemp take `extras: ContainerExtras`; read and recover return StoredBody.
// LibraryFormatKind { rtfd, markdown }, StoredBody { text, readOnlyReason, extras }, ContainerExtras, RTFDBodyStorage,
// NoteStore.bodyExtras, BodyCodec.
```

```swift
// BodyCodec (foundations' file, Model/BodyCodec.swift). Task 2.4 edits the enum body: Swift can't add a case
// in an extension, and the switches have no default branch, so each one gets a .markdown branch.
enum BodyCodec: String, CaseIterable, Sendable {
    case rtfd
    case noteItDoc
    case markdown                                   // added by this plan
    var fileExtension: String { get }               // .markdown: "md"
    func read(at url: URL) throws -> StoredBody                     // .markdown: MarkdownCodec.parse (either flavour),
                                                                    // then DocConverter.importDocument; relative image
                                                                    // paths are read only when they stay inside the file's
                                                                    // folder after resolving symlinks; extras.frontMatter
                                                                    // is the unknown front matter keys (FrontMatter.extra),
                                                                    // StoredBody.frontMatter the known ones (read only)
    func write(_ text: NSAttributedString, extras: ContainerExtras = .empty, meta: NoteMeta? = nil, to url: URL) throws
                                                                    // .markdown: library flavour, UTF-8, images written
                                                                    // to _attachments/ beside the file; the keys NoteIt
                                                                    // owns written from meta (spec §3.3), then
                                                                    // extras.frontMatter
    func data(of text: NSAttributedString, extras: ContainerExtras = .empty, meta: NoteMeta? = nil) throws -> Data
                                                                    // .markdown: the UTF-8 bytes of the .md file
                                                                    // write(_:extras:meta:to:) stores
    // foundations' static members unchanged
}

// Static Markdown helpers, in an extension in the same file
extension BodyCodec {
    // Task 2.4: library-free, for automation, plugins and the web clipper
    static func markdown(of text: NSAttributedString, profile: MarkdownProfile) throws -> String
    static func attributedString(fromMarkdown text: String, options: MarkdownImportOptions) async throws
        -> (NSAttributedString, unresolvedImages: [AttachmentRef])
    // Task 3.2: a Markdown library's files
    static func markdown(from text: NSAttributedString, frontMatter: FrontMatter, attachments: AttachmentStore,
                         links: WikiLinkResolver, previous: ParsedMarkdown?) throws -> String
    static func attributedString(from parsed: ParsedMarkdown, attachments: AttachmentStore) throws -> NSAttributedString
}

// Sources/NoteIt/MarkdownLibrary/MarkdownBodyStorage.swift
final class MarkdownBodyStorage: NoteBodyStorage, @unchecked Sendable {
    init(contentRoot: URL, dataDir: URL, styles: DocStyleProvider, ledger: WriteLedger,
         renameFilesOnTitleChange: Bool) throws
    var contentRootURL: URL { get }
    var skippedFiles: [URL] { get }               // over 10 MB
}

// Sources/NoteIt/MarkdownLibrary/NotebookFolders.swift
enum NotebookFolders {
    static let maxDepth = 4
    /// Reads `.noteit-notebook.json`, keeping every key except `name`, including unknown ones.
    static func read(_ folder: URL) throws -> (notebook: Notebook, raw: [String: Any])
    /// Patches only the keys NoteIt owns into `raw` and writes it atomically; never writes `name`.
    static func write(_ notebook: Notebook, raw: [String: Any], to folder: URL) throws
}

// Sources/NoteIt/MarkdownLibrary/WikiLinkResolver.swift
final class WikiLinkResolver: @unchecked Sendable {
    init(index: MarkdownPathIndex)
    func noteID(for target: String, fromNoteAt notePath: String) -> UUID?   // exact path, unique name, formerPaths
    func target(for id: UUID) -> String?                                    // file name, or path when not unique
}

// Sources/NoteIt/MarkdownLibrary/LockedNoteFiles.swift (Milestone 10, wave 3)
enum LockedNoteFiles {
    static let folder = ".noteit/locked"
    static func sealedURL(for id: UUID, contentRoot: URL) -> URL            // <uuid>.sealed
    static func lockFromHeader(_ sealed: URL) throws -> NoteLock            // keyID, sealedID from LockedBody.header(of:)
    static func placeholder(title: String, frontMatter: FrontMatter) -> String
}

// Sources/NoteIt/MarkdownLibrary/MarkdownFolderWatcher.swift
final class WriteLedger: @unchecked Sendable {
    func record(path: String, sha256: String)
    func isOwnWrite(path: String, sha256: String) -> Bool   // entries expire after 10 s
}
final class MarkdownFolderWatcher {
    init(contentRoot: URL, latency: TimeInterval = 0.3, debounce: TimeInterval = 0.5, onChange: @escaping @MainActor (Set<String>, _ rescan: Bool) -> Void)
    func start()
    func stop()
}

// Sources/NoteIt/MarkdownLibrary/FolderScanner.swift
struct FolderScanResult: Equatable {
    var changed: [UUID: String]        // id → path, content differs from markdown-files.json
    var added: [String]                // paths without a known id
    var moved: [UUID: String]          // id → new path
    var removed: Set<UUID>
    var duplicateIDs: [String]         // paths that must get a new id
    var notebookFolders: [String: NotebookFolderInfo]   // content-relative folder path → id and depth (≤ 4)
}
enum FolderScanner { static func scan(contentRoot: URL, index: MarkdownPathIndex) -> FolderScanResult }

// Sources/NoteIt/MarkdownLibrary/MassDeletionGuard.swift
struct MassDeletionGuard {
    static let maxFiles = 20                     // more than 20 files in one scan …
    static let minFraction = 0.10                // … or at least 10% of the files …
    static let minFilesForFraction = 5           // … when that is at least 5 files (program §11)
    static func mustHold(removed: Int, totalFiles: Int) -> Bool
}

// Sources/NoteIt/MarkdownLibrary/NoteStore+Markdown.swift
extension NoteStore {
    static let outsideNoteItSource = "Outside NoteIt"
    func applyExternalChanges(_ result: FolderScanResult)       // holds removals when MassDeletionGuard.mustHold
    var heldDeletions: Set<UUID> { get }                        // waiting for "Many notes disappeared from the folder"
    func confirmHeldDeletions()                                 // writes tombstones only now
    func hasUnsavedEdits(_ id: UUID) -> Bool
}

// Sources/NoteIt/Model/LibraryLocationFile.swift
struct LibraryLocationFile: Codable, Equatable {
    var version: Int                    // 1
    var format: LibraryFormatKind
    var path: String                    // with ~
    var bookmark: Data?
    var libraryID: UUID
    var renameFilesOnTitleChange: Bool  // true for a folder NoteIt created, false for an adopted folder
    static func load(dataDir: URL) -> LibraryLocationFile?     // nil → rtfd in dataDir
    func write(dataDir: URL) throws                              // atomic
}
// LibraryLauncher.swift
struct LibraryLocation: Equatable { var url: URL; var seedsFreshLibrary: Bool; var format: LibraryFormatKind = .rtfd; var contentRootURL: URL? = nil }   // url = NoteStore.rootURL (data folder)

// Sources/NoteIt/MarkdownLibrary/LibraryConverter.swift
struct ConversionPlan: Equatable { var target: LibraryFormatKind; var destination: URL?; var backupFirst: Bool; var adoptExisting: Bool }
enum ConversionProblem: Equatable { case notRoundTripping([UUID]), notEnoughSpace(needed: Int64), folderNotWritable, destinationOverlapsLibrary, cancelled }
@MainActor final class LibraryConverter: ObservableObject {
    @Published private(set) var progress: (done: Int, total: Int)
    init(store: NoteStore, dataDir: URL)
    func inspect(folder: URL) -> FolderInspection     // markdown count, cloud provider, existing libraryID, overlapsLibrary
    static func overlapsLibrary(_ folder: URL, dataDir: URL) -> Bool   // spec §3.6: equal to, inside or containing <data>/notes/,
                                                       // <data>/backups/, sync-meta-raw/, body-extras/, history/ or <data>
    func convert(_ plan: ConversionPlan) async -> Result<Void, ConversionProblem>   // relaunches on success
    static func finishInterrupted(dataDir: URL)        // called by LibraryLauncher before loading
}

// Sources/NoteIt/MarkdownLibrary/PreviousLibrary.swift
struct PreviousLibrary: Equatable {
    var url: URL; var createdAt: Date; var size: Int64
    static func find(dataDir: URL) -> [PreviousLibrary]
    static func shouldAsk(_ library: PreviousLibrary, now: Date, declined: Bool) -> Bool   // after 30 days, once; never trashes by itself
}
struct FolderInspection: Equatable { var markdownFiles: Int; var cloudProvider: String?; var existingLibraryID: UUID?; var overlapsLibrary: Bool }

// Sources/NoteIt/Backup/BackupManifest.swift
struct BackupManifest: Codable, Equatable {
    var format: String            // "noteit-backup"
    var version: Int              // 1
    var createdAt: Date
    var appVersion: String
    var libraryFormat: LibraryFormatKind
    var noteCount: Int
    var notebookCount: Int
    var lockedCount: Int          // sealed files under .noteit-backup/locked/; 0 until Milestone 10
    var files: [String: String]   // relative path → sha256; Milestone 10 adds sealed files and lock-keys.json
}

// Sources/NoteIt/Backup/BackupWriter.swift
struct BackupOptions: Equatable { var includeHistory: Bool }
struct BackupResult: Equatable { var file: URL; var noteCount: Int; var fallbackNotes: [UUID] }
@MainActor enum BackupWriter {
    static func write(store: NoteStore, to destination: URL, options: BackupOptions, progress: @escaping (Int, Int) -> Void) async throws -> BackupResult
    static func defaultFileName(at date: Date) -> String    // "NoteIt Backup 2026-10-19 0912.zip"
}

// Sources/NoteIt/Backup/BackupReader.swift
struct BackupCheck: Equatable {
    var noteCount: Int; var notebookCount: Int
    var damagedFiles: [String]
    var changedSinceBackup: [UUID]; var missingFromLibrary: [UUID]
    var lockedNotes: Int                          // "N locked notes (sealed, not opened)"; 0 until Milestone 10
    var isComplete: Bool { damagedFiles.isEmpty }
}
enum BackupReader {
    static func check(_ backup: URL, against store: NoteStore, workFolder: URL) async throws -> (BackupCheck, OpenedBackup)
}

// Sources/NoteIt/Backup/BackupRestorer.swift
enum RestoreScope { case missing, missingAndChanged }
@MainActor enum BackupRestorer { static func restore(_ backup: OpenedBackup, scope: RestoreScope, into store: NoteStore) throws -> RestoreResult }   // replacements via NoteStore.editBody(versioning: .recordCurrent), which records each current body once; the restorer records no version itself
struct RestoreResult: Equatable { var restored: Int; var replaced: Int; var lockedNotReplaced: [UUID]; var undo: RestoreUndo? }   // lockedNotReplaced: empty until Milestone 10

// Sources/NoteIt/Backup/BackupScheduler.swift
enum AutomaticBackupFrequency: String, CaseIterable { case off, daily, weekly }
@MainActor final class BackupScheduler {
    static let shared: BackupScheduler
    func start()                                 // launch + hourly timer
    func isDue(now: Date, last: Date?, frequency: AutomaticBackupFrequency) -> Bool
    static func filesToRemove(in folder: [URL], keep: Int) -> [URL]   // only "NoteIt Backup *.zip", oldest first
}

// Sources/NoteItSync/Engine/RemoteRestoreDrill.swift
public struct RemoteRestoreReport: Sendable, Equatable {
    public var notebooks: Int
    public var notes: Int
    public var unreadable: [UUID: String]          // id → reason
    public var missingRemotely: [UUID]             // local ids not on the remote
    public var olderRemotely: [UUID]               // remote revision differs from local
    public var lockedNotes: Int                    // "noteit-locked/1" bodies, checked by bodySHA256 only, never opened;
                                                   // counted from Milestone 10, 0 before
}
public struct RemoteRestoreDrill: Sendable {
    public init(backend: StorageBackend, cipher: SyncCipher, maxConcurrentDownloads: Int = 4)
    public func run(local: [UUID: UUID],                       // id → local revision
                    validateBody: @Sendable (Data) -> Bool,
                    progress: @Sendable (Int, Int) -> Void) async throws -> RemoteRestoreReport
}

// Sources/NoteIt/Import/EvernoteImporter.swift
@MainActor enum EvernoteImporter { static func importFiles(_ urls: [URL], into store: NoteStore) async -> ImportReport }
enum ENMLConverter { static func html(fromENML enml: String, resources: [String: EvernoteResource]) -> String }   // md5 hex → resource
struct EvernoteResource: Equatable { var data: Data; var mime: String; var fileName: String? }

// Sources/NoteIt/Import/NotionImporter.swift
@MainActor enum NotionImporter { static func importExport(_ url: URL, into store: NoteStore) async -> ImportReport }
enum NotionNames { static func stripID(_ name: String) -> (title: String, id: String?) }   // "Plan 1a2b…c3d4" → ("Plan", "1a2b…c3d4")

// Sources/NoteIt/Backup/DataAPIRoutes.swift
enum DataAPIRoutes {
    static let libraryRouteID = "markdown-storage.library"   // GET /v1/library, scope read
    static let backupRouteID = "markdown-storage.backup"     // POST /v1/backups, scope admin
    static func register(in registry: LocalAPIRouteRegistry = .shared)   // errors from APIErrorCode only
}
```

`PrefKey` additions: `automaticBackups`, `automaticBackupFolder`, `automaticBackupKeep`, `lastBackupAt`, `lastBackupFile`, `lastBackupError`, `lastRestoreCheckAt`.

---

## Milestone 1: Library location (ships alone, no behaviour change)

### Task 1.1: `NoteBodyStorage` and `RTFDBodyStorage`

Moved to foundations (docs/plans/2026-10-19-foundations.md), program §2 step 4. Summary of what foundations delivers and this plan relies on:
- the `NoteBodyStorage` protocol, `LibraryFormatKind`, `StoredBody` and `RTFDBodyStorage`, with the storage folder named `contentRootURL`;
- `NoteStore` reading and writing every body through `bodyStorage`: `NoteStore.bodyURL(for:)`, `readBody(at:)`, `bodyIDsOnDisk`, `writeBody`, `writeTempBody`, `installBody` and the file moves in `trashPendingBodies` live in `RTFDBodyStorage`, and `load()`, `rebuildFromBodies`, `flush()`, `writeRecoveryCopy`, `scheduleIndexRebuild`, `contentRevisions`, `prepareRemoteNote`, `applyPreparedRemoteNote` and `exportBodySource` go through the protocol;
- `BodyCodec` as the one body codec type (`.noteitdoc` files and semantic equality included);
- `BodyStorageContract`, a plain helper (not a test case) that this plan calls again for `MarkdownBodyStorage` in Task 3.2.

### Task 1.2: `library-location.json` and launcher

**Files:** `Sources/NoteIt/Model/LibraryLocationFile.swift`, `Sources/NoteIt/App/LibraryLauncher.swift`, `Tests/NoteItTests/LibraryLauncherTests.swift`

- [ ] Tests (extend `LibraryLauncherTests`): missing file → `.rtfd` at the data dir (today's decision unchanged); a valid Markdown file → `format == .markdown` and `contentRootURL` set; a bookmark that resolves to a moved folder updates `path`; a content folder that doesn't exist → decision `.contentRootMissing(URL)`; a corrupt file (not JSON, or a version-1 file that doesn't decode) → `.rtfd` at the data dir with `seedsFreshLibrary` false, plus a logged error, and the corrupt file is renamed `library-location.json.bad` (`.bad-2`, `.bad-3`… when that exists, so an earlier one is never replaced); a `version` other than 1, an unknown `format` or a read error (permissions, a cloud file not downloaded) → decision `.libraryLocationUnreadable(reason)`, the file left in place and nothing opened or seeded.
- [ ] `LibraryLocation.url` stays the data folder (`NoteStore.rootURL`); the Markdown folder is `contentRootURL`. `renameFilesOnTitleChange` defaults to `true` when missing.
- [ ] `LibraryLauncher.launch` handles `.contentRootMissing(URL)`: it shows "NoteIt can't find your library folder" with the path and a **Quit** button, then quits; it never creates or opens an empty library in its place. **Locate…** is added with the watcher in Task 4.2. A Markdown library is never seeded (`seedsFreshLibrary` is false). It handles `.libraryLocationUnreadable(reason)` the same way: "NoteIt can't read its library settings" with the reason and a **Quit** button, then quits.
- [ ] Implement; `LibraryLauncher` calls `LibraryConverter.finishInterrupted(dataDir:)` (stub returning immediately until Task 5.1).
- [ ] Verify: `swift test --filter LibraryLauncherTests` → 0 failures; `swift build` → `Build complete!`.

## Milestone 2: `NoteItMarkdown` codec (ships alone as a tested library)

### Task 2.1: Target, front matter

**Files:** `Package.swift`, `Sources/NoteItMarkdown/FrontMatter.swift`, `Tests/NoteItMarkdownTests/FrontMatterTests.swift`

- [ ] Add the target, a `NoteItMarkdown` library product (so the iOS build check has a scheme) and the test target (see File structure). `NoteItMarkdown` declares no platforms of its own, imports only Foundation, CryptoKit (SHA-256 attachment keys, as `NoteItDoc` does) and `NoteItDoc`, and passes the wave 0 `ImportHygieneTests` (no AppKit in an iOS-capable target), which also checks that import allow-list.
- [ ] Tests: the spec §3.3 example round-trips byte for byte; `pinned: false` is never written; `deleted`, `conflict-of`, `conflict-source` only when set; unknown keys (`aliases:` with a block list, `cssclasses:`) are kept verbatim and in order; `tags: [a, b]` and block-list tags are read; no front matter → `.empty` with `bodyStart` at 0; `---` not on line 1 is body text; an unterminated block throws `invalidFrontMatter(line:)`; CRLF input is read; dates without `Z` are read as UTC.
- [ ] Tests: `locked: true` is written only when set and ignored as a source of truth when read (`FrontMatter.locked` is informational).
- [ ] Verify: `swift test --filter FrontMatterTests` → 0 failures; `ImportHygieneTests` → 0 failures.

### Task 2.2: Block and inline parser

**Files:** `Sources/NoteItMarkdown/{BlockParser,InlineParser,WikiLinks,AttachmentPaths,MarkdownCodec}.swift`, `Tests/NoteItMarkdownTests/{CodecGoldenTests,ForeignMarkdownTests,AttachmentPathsTests}.swift`, `Tests/NoteItMarkdownTests/Support/MarkdownFixtures.swift`, `Tests/NoteItMarkdownTests/Fixtures/` (test target resources)

- [ ] Write the golden fixtures, one `.md`/`.json` pair per row of spec §3.2's table, plus: block attribute comments (each key), rich-block fallback (valid and stale payload), nested lists 0–8, checked items, tables with widths, images with and without width, non-image attachments, hard breaks, every highlight and text colour from `EditorStyle`, combined `span` colour + size, heading levels 4–6, literal footnotes, and wiki links (`[[Name]]`, `[[Name|text]]`, `[[Name#Heading]]`, `[[Work/Plan]]`, an unresolved name, `\[[` as literal text).
- [ ] Foreign fixtures in `Fixtures/foreign/`: an Obsidian note (wikilinks, `![[image.png]]` resolved from `_attachments/`, callouts kept as quotes), a Bear export, an iA Writer note, CRLF line endings, tabs for indentation.
- [ ] `CodecGoldenTests.testParse`: `parse(md).body == json` for every pair (fixtures named `read-…` are parse-only: headings 4–6, stale payload, footnotes, unknown keys, `\|` in a cell), with a fixed `resolveNoteLink` table for the wiki-link fixtures. A stale fallback payload is ignored and the visible block wins. Golden `noteit-doc` fixtures are loaded with `NoteItDocTestSupport`'s fixtures loader.
- [ ] Implement the CommonMark block structure (ATX headings, paragraphs, fenced code, lists, task items, quotes, thematic breaks, GFM tables, HTML comment lines) keeping a `SourceMap`, and inline parsing (delimiter runs per CommonMark, code spans, links and autolinks, `==`, `<u>`, `<mark style>`, `<span style data-size>`, wiki links through `resolveNoteLink` into `noteit://note/<UUID>` or `noteit://note?title=`; other HTML stays text).
- [ ] Verify: `swift test --filter CodecGoldenTests/testParse` and `ForeignMarkdownTests` → 0 failures.

### Task 2.3: Writer, escaping, source preservation

**Files:** `Sources/NoteItMarkdown/{MarkdownCodec,BlockWriter,InlineWriter,SourcePreservation}.swift`, `Tests/NoteItMarkdownTests/{CodecGoldenTests,CodecPropertyTests,EscapingTests,WikiLinkSyntaxTests,SourcePreservationTests,CorpusTests}.swift`

The writer writes one blank line after front matter, which the parser reads as the separator, not as an empty paragraph. An unknown block is written in `library` as a lone `<!-- noteit: doc=… -->` comment with its raw JSON, which the reader turns back into the same `.unknown` block; `portable` drops it. Images in headings are written as `![…](…)`, not as a fallback, because they read back unchanged.

- [ ] `CodecGoldenTests.testSerialize`: `serialize(json) == md` byte for byte for every canonical fixture.
- [ ] `CodecPropertyTests`: `parse(serialize(doc)) == doc` for 2,000 `RandomDocGenerator(seed:)` documents, both flavours where the flavour can hold the doc (the portable check needs more than 20 such documents); serializing a parsed file again gives the same text; failures print the seed.
- [ ] `EscapingTests`: text containing `*`, `_`, `==`, `<u>`, `#` and `1.` at line start, `|` in cells, backslashes, literal `[[`, and `<!-- noteit:` round-trips as text.
- [ ] `WikiLinkSyntaxTests`: a note link is written as raw `[[…]]` and never escaped, also when the shown text has `*` or `_`; outside tables `|` inside a wiki link is not escaped; in a table cell `[[Name|text]]` is written as `[[Name\|text]]`, the cell count of the row is unchanged, and it reads back as the same link (program §11); `noteLinkName` returning nil writes the title; the `portable` flavour writes the same wiki-link syntax.
- [ ] `SourcePreservationTests`: a foreign file with non-canonical style (`__bold__`, `+` bullets, setext headings) keeps those bytes when a different block changes; changed blocks are canonical; front matter extra is preserved; every block of the foreign fixtures is kept when nothing changes, and CRLF files are written with LF.
- [ ] Corpus check (`CorpusTests`): serialize 500 random docs; the test fails if more than 1% of the blocks plain Markdown can hold (all but code blocks with marks or atoms and tables that aren't GFM-shaped, which random docs produce often) need the rich-block fallback. The `SeedData` 1% check is in Task 2.4's `BodyCodecMarkdownTests`, because `SeedData` lives in the `NoteIt` target.
- [ ] Verify: `swift test --filter NoteItMarkdownTests` → 0 failures.

### Task 2.4: Import options and `case markdown` of `BodyCodec`

**Files:** `Sources/NoteItMarkdown/MarkdownCodec.swift`, foundations' `BodyCodec` file, `Tests/NoteItMarkdownTests/ImportOptionsTests.swift`, `Tests/NoteItTests/BodyCodecMarkdownTests.swift`

- [ ] `ImportOptionsTests`: `importDocument` calls `resolveImage` once per distinct image URL, relative paths resolved against `baseURL`; the returned bytes become an attachment keyed by SHA-256 and the image node points at it; nil, empty data and data over `AttachmentLimit.maxBytes` drop the image and list it in `unresolvedImages`; the same URL twice is fetched once; wiki links go through `resolveNoteLink`. Non-image attachment links are resolved the same way. `importDocument` is `parse`, the fetches, then the public `resolvingAttachments(_:read:)`, which `BodyCodec.read(at:)` calls with file reads (it can't await).
- [ ] `BodyCodecMarkdownTests`: `BodyCodec.markdown(of:profile:)` then `attributedString(fromMarkdown:options:)` is `semanticallyEqual` to the input for the seeded sample notes (`SeedData.welcomeBody()`, the one seeded note) with the `library` flavour, and at most 1% of their blocks need the rich-block fallback; the `portable` flavour has no `<!-- noteit` comments; the editor's Yellow highlight is written as `==…==`; images are written to `_attachments/` beside the file and read back. `NoteItTests` depends on `NoteItMarkdown`.
- [ ] `BodyCodecMarkdownTests`: `BodyCodec.markdown.fileExtension` is `md`; `data(of:extras:)` equals the bytes of the file `write(_:extras:to:)` stores; `testFrontMatterExtrasSurviveEdit`: a `.md` file with an unknown front matter key (`aliases:`) → `read(at:)` → change the text → `write(_:extras:to:)` with the read `extras` keeps the key verbatim, also when the edit empties the document; foundations' `allCases` round-trip loop in `BodyCodecTests` now covers `.markdown` and passes.
- [ ] Add `case markdown` inside the `BodyCodec` enum body in foundations' file (not in an extension: Swift can't add a case there) and a `.markdown` branch to each switch: `fileExtension`, `read(at:)`, `write(_:extras:to:)` and `data(of:extras:)`. The switches keep no `default:` branch. No registry and no second codec type (program §6).
- [ ] Add the two library-free static functions to an extension of `BodyCodec` in the same file. They and the `.markdown` branches use `DocConverter` and `MarkdownCodec` only. `read(at:)` reads relative paths only; a missing image file is dropped from the body, so a later write loses that reference (Markdown libraries use Task 3.2's `attributedString(from:attachments:)` instead).
- [ ] Verify: `swift test --filter "ImportOptionsTests|BodyCodecMarkdownTests|BodyCodecTests"` → 0 failures.

Task 2.1 must land first; 2.2, 2.3 and 2.4 are sequential. Milestone 2 can run in parallel with Milestone 1. Once 2.4 lands (early in wave 1), `NoteItMarkdown` and `BodyCodec.markdown` are usable by automation, plugins, the web clipper and mobile (program §6).

## Milestone 3: Markdown library format (ships behind `NOTEIT_MARKDOWN_ROOT`, no UI yet)

### Task 3.1: Path index, notebook folders and attachment store

**Files:** `Sources/NoteIt/MarkdownLibrary/{MarkdownPathIndex,NotebookFolders,AttachmentStore}.swift`, `Tests/NoteItTests/{MarkdownPathIndexTests,NotebookFoldersTests,AttachmentStoreTests}.swift`

- [ ] `MarkdownPathIndexTests`: names from titles use `ExportNaming.sanitized` and `ExportNaming.unique` case-insensitively (`Plan.md`, `plan 2.md`); stems are cut to 100 characters on a grapheme boundary; untitled → `Untitled.md`; notes in a notebook go under its folder path (`Work/Meetings/…`); folders starting with `.` or `_` are not notebooks; a rename keeps the old path in `formerPaths`; the index persists to `markdown-files.json` in the data folder atomically and reloads.
- [ ] `NotebookFoldersTests`: nested folders up to depth 4 map to nested notebooks with `parent` set from the folder; a depth-5 folder is not a notebook and its notes belong to the depth-4 notebook; NoteIt never creates a folder deeper than 4; `.noteit-notebook.json` round-trips every key except `name`, including `parent`, `defaultTemplateID` and an unknown key, in a file written by a newer app; `spaceID` is never written, even for a notebook that belongs to a shared space (that link lives only in sharing's `spaces.json`), `spaceID` is a forbidden key that is stripped on read and on write: rewriting a file that contains `spaceID` and an unknown key removes `spaceID` and keeps the unknown key; no board field is written (board layouts are `boards/` records, program §4 rule 14); a `parent` that disagrees with the folder is rewritten to match the folder. Nested notebooks need organise's notebook `parent` field; if this task lands first, nested folders map to their top-level notebook (spec §3.4) and the nesting cases are enabled in the task that follows organise's field.
- [ ] `AttachmentStoreTests`: identical bytes are stored once; names are `<12 hex>-<name>`; relative paths from the content folder and from notebook folders at depth 1 and 4; references counted across notes; an unreferenced file moves to the Trash only after 24 h (injected clock) and only if it was seen referenced; files over `AttachmentLimit.maxBytes` are refused.
- [ ] Verify: `swift test --filter "MarkdownPathIndexTests|NotebookFoldersTests|AttachmentStoreTests"` → 0 failures.

### Task 3.2: `MarkdownBodyStorage` and the library helpers of `BodyCodec`

**Files:** `Sources/NoteIt/MarkdownLibrary/MarkdownBodyStorage.swift`, foundations' `BodyCodec` file, `Tests/NoteItTests/MarkdownBodyStorageTests.swift`

- [ ] Add `testBodyStorageContract()` to `MarkdownBodyStorageTests`, calling `BodyStorageContract.runAll(make:)` with a `MarkdownBodyStorage` factory.
- [ ] `MarkdownBodyStorageTests`:
  - written files are UTF-8, no BOM, LF, final newline; written through `.<name>.noteit-tmp` + rename; the ledger has the hash;
  - front matter fields match the `NoteMeta` (spec §3.3);
  - `read` returns the unknown front matter keys verbatim as `StoredBody.extras.frontMatter`; `write` with `extras.frontMatter` set writes those keys back (a sync apply that brings a container's `frontMatter` lands in the file); `extras.extra` is not written to the file, and `read` returns it empty;
  - `writeMetadataOnly` for pin rewrites only the front matter; for a notebook change moves the file; for a title change renames when called by the idle rename;
  - a file changed on disk since indexing makes `write` throw `.externallyChanged` without writing;
  - `moveToTrash` → `.trash/<name>.md` with `deleted:`; `recover` moves it back; `removePermanently` calls the injected trash function (macOS Trash) instead of deleting;
  - invalid UTF-8 → `StoredBody.readOnlyReason` set and later writes refused;
  - `renameNotebook` renames the folder and updates every indexed path; moving a notebook moves its folder; `.noteit-notebook.json` is written through `NotebookFolders.write`, keeping unknown keys;
  - with `renameFilesOnTitleChange == false`, a title change never renames the file;
  - nothing is written into the content folder except note files, `.noteit-notebook.json`, `_attachments/`, `.trash/` and `.noteit/` (`library.json`, `staging/`; Milestone 10 adds `locked/`); a test lists the folder after a full write cycle.
- [ ] Add the two library static functions to the `BodyCodec` extension in foundations' file (`case markdown` itself is already in the enum body from Task 2.4; no new case and no second codec type). They use `DocConverter.export(_:styles:imagePolicy: .keepOriginal)` and `MarkdownCodec`, passing `previous` from the last read so unchanged blocks keep their bytes.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MarkdownBodyStorageTests` → 0 failures.

### Task 3.3: `NoteStore` on a Markdown library

**Files:** `Sources/NoteIt/Model/NoteStore.swift`, `Sources/NoteIt/MarkdownLibrary/NoteStore+Markdown.swift`, `Sources/NoteIt/Model/VersionHistory.swift`, `Sources/NoteIt/App/LibraryLauncher.swift`, `Tests/NoteItTests/{MarkdownBodyStorageTests,VersionHistoryTests}.swift`

- [ ] Tests:
  - a `NoteStore` on a Markdown library loads nested notebooks from folders, notes with titles, previews, tags and pinned state from files, and rebuilds `library.json` when it is missing;
  - pin, move to notebook, rename notebook, delete notebook rewrite or move files on `flush()`;
  - idle rename after 5 s or on deselect (injected clock);
  - `VersionHistoryTests`: `.noteitdoc` versions are written for Markdown libraries; `load` lists `.rtfd` and `.noteitdoc` versions of the same note in date order; restoring either works; limits unchanged;
  - recovery copies are `.md`;
  - a body changed on disk reaches organise's search index v2 and other registered indexers only through the `DerivedIndex` registry (`noteChanged`, `noteRemoved`, and `metadataChanged` for a file moved to another folder); `search-index.json` stays in the data folder with `"version" : 2`.
- [ ] `LibraryLauncher` honours `NOTEIT_MARKDOWN_ROOT=<path>` (debug only, documented in `docs/development.md`) to open a Markdown library at that content folder without conversion.
- [ ] Verify: `swift test --filter NoteItTests` → 0 failures. Manual: `NOTEIT_DATA_DIR=.selftest/md NOTEIT_MARKDOWN_ROOT=.selftest/md-root swift run NoteIt`, create notes with every toolbar format, quit, check the `.md` files in a text editor against the spec table, relaunch: notes look the same.

### Task 3.4: Sync with a Markdown library

**Files:** `Sources/NoteIt/Model/NoteStore+Sync.swift`, `Sources/NoteIt/Model/SyncSelfTest.swift`, `Tests/NoteItTests/MarkdownBodyStorageTests.swift`

- [ ] Tests: body encoding depends only on whether the manifest `features` contains `noteit-doc`, never on `formatVersion` (program §4.1); `exportBodySource` for Markdown returns `.text` with the parsed body; `completeExport` → flattened RTFD that deserializes to a semantically equal body; `prepareRemoteNote` writes a temp `.md` under `.noteit/staging/`; `applyPreparedRemoteNote` installs it at the note's path and records the ledger hash; revisions don't change on apply; a remote notebook or note with unknown keys keeps them through `RawMetaOverlay` and in `.noteit-notebook.json`.
- [ ] Extend the sync self-test: with `NOTEIT_SYNC_SELFTEST_MARKDOWN=1` one of the two simulated devices uses a Markdown library. Every existing `SYNCTEST` scenario must pass.
- [ ] Verify: `NOTEIT_DATA_DIR=.selftest/sync-md NOTEIT_SYNC_SELFTEST=1 NOTEIT_SYNC_SELFTEST_MARKDOWN=1 swift run NoteIt` exits 0 and every `SYNCTEST` line says `ok`.

### Task 3.5: Wiki links on disk

**Files:** `Sources/NoteIt/MarkdownLibrary/WikiLinkResolver.swift`, `Sources/NoteIt/MarkdownLibrary/MarkdownBodyStorage.swift`, `Tests/NoteItTests/WikiLinkResolverTests.swift`

- [ ] Tests (spec §3.4, linking's resolution rules):
  - a note link written and read back points at the same UUID;
  - a non-unique file name is written as the content-relative path without `.md`;
  - after NoteIt renames a file, `[[Old name]]` in a file not yet rewritten still resolves through `formerPaths`, and the referring file gets the new name the next time NoteIt writes it, with no new revision;
  - after a rename outside NoteIt (scan matched by id), links in other files still resolve;
  - an unknown name becomes `noteit://note?title=`; `![[Note]]` for a note is a link, `![[photo.png]]` in `_attachments/` is an image;
  - files are never rewritten only to update link names.
- [ ] `MarkdownBodyStorage` passes `WikiLinkResolver` to `BodyCodec` for reads and writes.
- [ ] Verify: `swift test --filter WikiLinkResolverTests` → 0 failures.

### Task 3.6: Locked notes in a Markdown library

Moved to Task 10.1 (wave 3). Until then there are no locked notes, and Milestone 3 has no lock handling.

Task 3.1 can run in parallel with Milestone 2 (it doesn't need the codec). 3.2 → 3.3 → 3.4 are sequential. 3.5 needs 3.2 and can run in parallel with 3.3 and 3.4.

## Milestone 4: Watching external edits

### Task 4.1: Scanner

**Files:** `Sources/NoteIt/MarkdownLibrary/FolderScanner.swift`, `Tests/NoteItTests/FolderScannerTests.swift`, `Tests/NoteItTests/MarkdownLibraryPerformanceTests.swift`

- [ ] `FolderScannerTests`: unchanged folder → empty result; content change with same size (different hash) detected; `touch` without content change → not changed (hash equal) and the index's mtime updated; new file; rename and cross-folder move matched by id (old path into `formerPaths`); nested folders up to depth 4 in `notebookFolders`; folder moved into another notebook folder; deletion; copied file with duplicate id → `duplicateIDs`; skipped: hidden, `.trash/`, `_attachments/`, `node_modules`, `.icloud`, over 10 MB; a folder over the large-library threshold (injected, so the test uses a small folder; 50,000 in the app) still scans and sets the flag behind the Your Data line "This folder has more than 50,000 Markdown files. NoteIt may be slow." (spec §3.5).
- [ ] `MarkdownLibraryPerformanceTests`: generate 10,000 small files; a no-change scan finishes in under 1 s in release (`swift test -c release --filter MarkdownLibraryPerformanceTests`).
- [ ] Verify: both suites → 0 failures.

### Task 4.2: Watcher and change handling

**Files:** `Sources/NoteIt/MarkdownLibrary/{MarkdownFolderWatcher,ExternalChangeHandler,NoteStore+Markdown}.swift`, `Tests/NoteItTests/ExternalChangeTests.swift`

- [ ] `ExternalChangeTests` (drive `applyExternalChanges` directly with scan results; one test runs the real watcher with a 5 s timeout):
  - changed file, note clean → body reloaded through `NoteStore.editBody` with the default `.recordCurrent`, so history holds the previous body exactly once (the watcher records no version itself), new revision, `updatedAt` = file mtime, applied through `NoteStore.editBody` so `.noteItLocalChange` and `localNoteChange` with `kind: edited` are posted (an edit outside NoteIt is a local edit, program §7), `externallyUpdatedNoteID` set when open;
  - changed file while `hasUnsavedEdits` → NoteIt's body written, a conflict copy "<title> (Outside NoteIt)" with `conflictSource == "Outside NoteIt"` and `conflictOriginalID`;
  - new file without front matter gets an id after 2 s of stability, not before;
  - deletion → Recently Deleted and `.trash/<name>.md` holds the last content;
  - folder renamed → notebook renamed; folder moved → notebook moved (parent follows the folder); folder deleted → notes in Recently Deleted;
  - own writes (ledger) produce no change;
  - unreadable file → read-only banner state, never rewritten.
- [ ] Implement the watcher with `FSEventStreamCreate` (`kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`), 0.3 s latency, 0.5 s per-path debounce, rescan on `MustScanSubDirs`/`UserDropped`/`KernelDropped`. Content folder missing → the "Your Markdown folder can't be found" window with **Locate…** and **Quit**; writes stop.
- [ ] Verify: `swift test --filter ExternalChangeTests` → 0 failures. Manual: edit a note's file in TextEdit while the note is open; it reloads within 1 s.

### Task 4.3: Mass-deletion guard

**Files:** `Sources/NoteIt/MarkdownLibrary/{MassDeletionGuard,ExternalChangeHandler,NoteStore+Markdown}.swift`, `Tests/NoteItTests/MassDeletionGuardTests.swift`

- [ ] Tests (program §11, spec §3.5):
  - `mustHold(removed:totalFiles:)`: 21 of 1,000 → true; 20 of 201 → false; 5 of 50 → true; 4 of 10 → false (10% but fewer than 5); 0 → false;
  - a held batch changes nothing: the notes stay in the library, no tombstone is written to `tombstones.json` and none is pushed by a sync run while the batch is held (`SyncPlanner` has no delete actions);
  - a held note opens read-only with "This note's file is missing from the folder.";
  - the files coming back clears the batch with no user action;
  - **Move to Recently Deleted** applies the batch as normal deletions, and only then are tombstones written;
  - **Not Now** keeps the batch and asks again at the next launch;
  - a deleted notebook folder counts its notes toward the threshold.
- [ ] The prompt "Many notes disappeared from the folder" with the count, **Move to Recently Deleted** and **Not Now**, strings from spec §3.5.
- [ ] Verify: `swift test --filter "MassDeletionGuardTests|ExternalChangeTests"` → 0 failures.

Milestone 4 needs Milestone 3. Task 4.1 and the watcher part of 4.2 can run in parallel. 4.3 needs 4.2.

## Milestone 5: Conversion both ways

### Task 5.1: `LibraryConverter`

**Files:** `Sources/NoteIt/MarkdownLibrary/LibraryConverter.swift`, `Tests/NoteItTests/LibraryConverterTests.swift`

- [ ] Tests (scratch data dir with the seeded library plus notes covering every format):
  - RTFD → Markdown: every note's body is semantically equal after relaunch (new `NoteStore` on the new location); ids, revisions, dates, pinned, notebooks, Recently Deleted and history preserved; `library-location.json` written; `notes/` moved to `Previous Library <date>/`;
  - Markdown → RTFD: the Markdown folder is unchanged except `.noteit/` removed;
  - derived and per-Mac files (`search-index.json`, `link-index.json`, `smart-folders.json`, `library-settings.json`, `lock-keys.json` and the rest of program §7) stay in the data folder and none appears in the content folder;
  - an adopted folder keeps every file name, `renameFilesOnTitleChange` is `false`, and a later title change doesn't rename the file;
  - `PreviousLibrary.shouldAsk` is false before 30 days, true once after, false after **Keep**; nothing moves the previous library to the Trash without the user choosing **Move to Trash** or **Remove**;
  - a note forced not to round-trip → `.notRoundTripping([id])` and nothing outside staging changed;
  - an interruption injected after each step: `finishInterrupted` leaves the old library usable before step 6 and completes step 7 after it;
  - adopting a folder with 3 foreign files: they get front matter, other bytes unchanged; existing `libraryID` and cloud-provider detection (`~/Library/CloudStorage`, `Mobile Documents`, a `Dropbox` ancestor with `.dropbox`) reported by `inspect`;
  - not enough space → `.notEnoughSpace`;
  - **overlapping destination** (spec §3.6): `convert` with a destination equal to `<data>`, `<data>/notes/`, `<data>/backups/`, `<data>/backups/staging-x/`, `<data>/sync-meta-raw/`, `<data>/body-extras/` or `<data>/history/`, a folder inside any of them (`<data>/notes/sub/`), a folder that contains `<data>` (its parent), and a symlink that resolves to `<data>/notes/` each returns `.destinationOverlapsLibrary`; the data folder and the destination are byte-identical before and after, no staging folder exists, sync was never paused and `NoteStore.flush()` was never called; `inspect` reports `overlapsLibrary == true` for the same folders; a sibling such as `<data>-notes/` or `~/Documents/NoteIt` is accepted;
  - no revision changes, so a following sync uploads nothing (`SyncPlanner` actions are all no-ops against a store snapshot taken before).
- [ ] Implement the seven steps of spec §3.6, without the sealed-file parts, which Task 10.1 adds. Before step 1, `convert` returns `.destinationOverlapsLibrary` when `overlapsLibrary(destination, dataDir:)` is true (symlinks resolved, paths standardised, compared by path components). Sync is paused through `SyncController` and the editor shows "Converting your library…".
- [ ] `PreviousLibrary`: the Your Data row and the 30-day question at launch, strings from spec §3.6.
- [ ] Verify: `swift test --filter LibraryConverterTests` → 0 failures.

### Task 5.2: Conversion sheet

**Files:** `Sources/NoteIt/MarkdownLibrary/ConvertLibrarySheet.swift`

- [ ] Sheet with folder choice, adoption text (including "File names stay as they are."), **Back up my library first**, **Make a backup ZIP of this folder first**, cloud warning with **Use Both Anyway** / **Choose Another Folder**, progress "Converting 412 of 1,284 notes…", and the not-round-tripping result with **Show Notes** / **Cancel**. A folder whose `inspect` reports `overlapsLibrary` shows "This folder holds NoteIt's own library files. Choose a folder outside them." under the picker and keeps **Switch** disabled. Strings exactly as in spec §3.6.
- [ ] Verify: `swift build` → `Build complete!`. Manual, with `NOTEIT_DATA_DIR=.selftest/convert`: convert to Markdown and back; the library looks the same both times.

5.1 needs Milestone 3; 5.2 needs 5.1 and Task 6.1's tab (it is opened from Your Data). Milestone 4 and Task 5.1 can run in parallel.

## Milestone 6: Your Data and backups

### Task 6.1: Your Data tab, menus, palette

**Files:** `Sources/NoteIt/Settings/{DataSettingsView,SettingsView,Preferences}.swift`, `Sources/NoteIt/Backup/DataActions.swift`, `Sources/NoteIt/App/ExportCommands.swift`, `Sources/NoteIt/Palette/PaletteCommandRegistry.swift`, `Tests/NoteItTests/PaletteCommandRegistryTests.swift`

- [ ] Fill in the frozen `SettingsView.Tab.data` (wave 0 constant: raw value `data`, title "Your Data", symbol `externaldrive`, position 5 after Sync) with `DataSettingsView`. `noteit://settings?tab=data` already routes there through `SettingsTabRouter`; this task doesn't add or move tabs.
- [ ] Sections and strings from spec "What the user gets", including **Rename files when titles change** for a Markdown folder and the previous library row; counts and sizes computed off the main actor; the Sync section reads `SyncController.lastSync` and the store name. No control in onboarding or elsewhere switches to Markdown storage.
- [ ] Commands: File › Back Up Everything… and File › Show Note File in Finder, after the Share submenu, in the order of program §9; palette ids `backUpEverything`, `revealNoteFile`, `showYourData`, `checkBackup`, `checkSyncStorage` with the availability rules from the spec.
- [ ] Tests in `PaletteCommandRegistryTests`: the five commands exist with camelCase ids and the right `available` values for an RTFD library, a Markdown library, sync off and on; none has a shortcut. A menu test checks the File menu order against program §9.
- [ ] Verify: `swift test --filter PaletteCommandRegistryTests` → 0 failures; `swift build` → `Build complete!`.

### Task 6.2: `BackupWriter`

**Files:** `Sources/NoteIt/Backup/{BackupWriter,BackupManifest}.swift`, `Tests/NoteItTests/BackupTests.swift`

- [ ] Tests: ZIP layout as spec §3.8 for an RTFD and a Markdown library; manifest checksums match the files; `README.txt` present; history only when requested; a note forced not to round-trip produces `fallback/<id>.noteitdoc` and appears in `fallbackNotes`; output name `NoteIt Backup 2026-10-19 0912.zip`; the `.partial` file is removed on cancel and on error; free-space check fails cleanly.
- [ ] Verify: `swift test --filter BackupTests` → 0 failures; `unzip -l` on a test output lists the expected entries.

### Task 6.3: Automatic backups

**Files:** `Sources/NoteIt/Backup/BackupScheduler.swift`, `Sources/NoteIt/App/AppDelegate.swift`, `Tests/NoteItTests/BackupSchedulerTests.swift`

- [ ] Tests: `isDue` for off/daily/weekly at the boundaries; `filesToRemove` keeps the newest N, ignores files not matching `NoteIt Backup *.zip`; missing folder sets `lastBackupError` and doesn't throw; no backup while a conversion or restore is running.
- [ ] Start the scheduler from `AppDelegate` after the store loads.
- [ ] Verify: `swift test --filter BackupSchedulerTests` → 0 failures.

### Task 6.4: Local API routes

**Files:** `Sources/NoteIt/Backup/DataAPIRoutes.swift`, `Sources/NoteIt/App/AppDelegate.swift`, `Tests/NoteItTests/DataAPIRoutesTests.swift`

- [ ] Tests (through automation's in-process router, no socket):
  - both routes are registered through `LocalAPIRouteRegistry` with ids `markdown-storage.library` and `markdown-storage.backup`; no route is added any other way;
  - `GET /v1/library` with a read token returns the format, note count and locked count for an RTFD and a Markdown library and contains no file paths;
  - `POST /v1/backups` needs admin scope (a read or write token gets automation's scope error); it starts the same `BackupWriter` run as the menu command;
  - while the library loads or a conversion or restore runs, `POST /v1/backups` returns `503` with `not_ready`;
  - every error uses an existing `APIErrorCode`.
- [ ] `DataAPIRoutes.register()` is called from `AppDelegate` after the store loads.
- [ ] Verify: `swift test --filter DataAPIRoutesTests` → 0 failures.

6.1, 6.2 and 6.3 can run in parallel after Milestone 1 (backups of an RTFD library don't need Milestones 3–5; the Markdown-library backup tests are added when Milestone 3 is in). 6.4 needs 6.2 and automation's `LocalAPIRouteRegistry`.

## Milestone 7: Restore drills

### Task 7.1: Check a Backup and Restore from Backup

**Files:** `Sources/NoteIt/Backup/{BackupReader,BackupRestorer,DataActions}.swift`, `Tests/NoteItTests/BackupTests.swift`

- [ ] Tests: a fresh backup checks complete; a flipped byte in one note → `damagedFiles` with that path; zip-slip entries (`../x`, absolute paths) are refused with the existing `MarkdownImporter` checks; changed and missing notes counted by id; Restore Missing adds only missing notes; Restore Missing and Changed replaces bodies through `NoteStore.editBody` (an open note updates in place) with the default `.recordCurrent`, so history holds each replaced body exactly once and the restorer records no version itself, then offers Undo, which puts every replaced body back (program §6); restored notes get new revisions; notebooks recreated by id with unknown keys kept; nothing deleted; `restore-drill/` removed afterwards.
- [ ] Result sheets with the spec §3.9 wording; sets `lastRestoreCheckAt`.
- [ ] Verify: `swift test --filter BackupTests` → 0 failures.

### Task 7.2: Check Sync Storage

**Files:** `Sources/NoteItSync/Engine/RemoteRestoreDrill.swift`, `Sources/NoteIt/Sync/SyncController.swift`, `Sources/NoteIt/Backup/DataActions.swift`, `Tests/NoteItSyncTests/RemoteRestoreDrillTests.swift`

- [ ] Tests against `InMemoryBackend` populated by a real `SyncEngine` pass: all readable → counts match; a corrupted body → `unreadable[id] == "damaged body"`; a body whose `bodySHA256` mismatches → unreadable; a local note not pushed → `missingRemotely`; different revision → `olderRemotely`; an unknown `bodyFormat` prefix is checked by hash and not decoded; the backend records zero `put`/`delete` calls; at most 4 concurrent `get`s.
- [ ] Implement with `RemoteLayout`, `RemoteEnvelope`, `SyncCipher.open` and `SyncEngine.context(_:)` / `sha256Hex`. `SyncController.checkSyncStorage()` uses foundations' `StoreSession`, pauses automatic sync while running, and validates bodies by `bodyFormat`: `DocValidation.validate` when the manifest `features` contains `noteit-doc`, otherwise `NoteStore.deserializeBody`.
- [ ] Verify: `swift test --filter RemoteRestoreDrillTests` → 0 failures; manual run against a folder store under `.selftest/` shows "All N notes and M notebooks in “…” can be restored on a new Mac."

7.1 needs 6.2; 7.2 needs only Milestone 1 and can run in parallel with everything from Milestone 2 on.

## Milestone 8: Evernote and Notion importers (independent of Milestones 3–7)

### Task 8.1: Evernote `.enex`

**Files:** `Sources/NoteIt/Import/{EvernoteImporter,ImportSheet}.swift`, `Sources/NoteIt/App/ImportCommands.swift`, `Tests/NoteItTests/EvernoteImporterTests.swift`

- [x] Tests (ENEX built in the test from strings): title, dates, tags as a hashtag line; `en-todo` checked and unchecked → checklist items; `en-media` image matched by MD5 → inline image; non-image resource → file attachment; `en-crypt` → note imported without it and `lockedSkipped` incremented; resource over 25 MB → `attachmentsSkipped`; malformed XML in one note skips that note and continues; a 200 MB generated file imports with memory growth under 100 MB (streaming).
- [x] `ImportSource.evernote`: title "Evernote", description from the spec, symbol `square.and.arrow.down.on.square`, colour `Tokens.Color.notebookGreen`. Notebook per file via `notebookForImport(named:)`.
- [x] Verify: `swift test --filter EvernoteImporterTests` → 0 failures.

As built (8.1): plan-vs-code differences. `EvernoteImporter.importFiles(_:into:progress:)` / `importItems` take a progress callback like the other importers, and the sheet accepts several `.enex` files or a folder of them, whose subfolders (Evernote stacks) become parent notebooks. Per §3.11 an import never adds to a notebook that was already in the library: `ImportNotebooks` (one per run) makes "Work 2", "Work 3"… beside a taken name, and the same path within one run goes to the same new notebook, so a stack's files share one new parent. The Notion importer follows the same rule (see 8.2). `ENEXReader` splits the file into `<note>` elements in 1 MB blocks and each note is parsed by its own `XMLParser`, so broken XML skips one note; ENML is then rewritten to HTML with patterns rather than parsed (malformed ENML still imports) and goes through `AppleNotesImporter.convert`. Resources are not inlined as data URLs: `en-media` leaves a placeholder that becomes an `NSTextAttachment` with the resource's own file name, and resources no `en-media` points at are added at the end. `en-crypt` counts in a new `ImportReport.encryptedSectionsSkipped` ("N notes had encrypted sections that were skipped.") instead of `lockedSkipped`, whose wording is about locked notes. Tags are made valid for the tag grammar (`ImportTags`, one per run): `+ # & @` are spelled out (`C++` → `#c-plus-plus`, `C#` → `#c-sharp`), two names that would still give the same tag get `-2`, `-3`… and names with nothing usable left count in a new `ImportReport.tagsSkipped` ("N tags with no letters or numbers"); a reminder becomes an `@remind(…)` token. Links to Evernote notes (`evernote:///view/…`, `evernote.com/shard/…/nl/…`) become title links and are pointed at the imported note with that title when the import ends, so a cancel leaves none to notes not created. Unsaved bodies are flushed every 8 MB, which keeps a 200 MB export at about 85 MB of growth; reads run inside autorelease pools because `FileHandle` blocks are autoreleased. `ImportCommands` needed no change (Import… already opens the sheet); the palette's Import… gained the keywords "evernote", "enex" and "notion". The sheet's "nothing to import" check also counts unreadable files.

### Task 8.2: Notion Markdown & CSV

**Files:** `Sources/NoteIt/Import/{NotionImporter,ImportSheet}.swift`, `Sources/NoteIt/Model/NoteStore+Import.swift`, `Tests/NoteItTests/NotionImporterTests.swift`

- [x] Tests (export tree built in the test, zipped with `ditto`): nested ZIP opened one level; ids stripped from titles and notebook names; top-level page with subpages → notebook with all descendants; lone top-level pages → "Notion" notebook; percent-encoded image paths resolved through `MarkdownCodec.importDocument` with a `resolveImage` that reads files inside the export (no `MarkdownReader`); a missing image is reported; `<aside>` → quote; page links → plain titles; CSV → table note, truncated at 1,000 rows with `rowsTruncated`; an HTML export refused with the spec message.
- [x] `ImportSource.notion`: title "Notion", description from the spec, symbol `doc.on.doc`, colour `Tokens.Color.notebookGray`.
- [x] Verify: `swift test --filter NotionImporterTests` → 0 failures.

As built (8.2): `NotionImporter.importExport(_:into:progress:)` is `async throws` (an HTML export, an empty folder or an archive that won't open fail the sheet with `ImportError.notionHTMLExport`, `.nothingToImport` or the new `.unreadableArchive`) and takes a progress callback. It accepts the `.zip` or the unzipped folder; part ZIPs at the top level are unzipped one level and merged by path (a part that won't open is named in the summary through the new `ImportReport.archivesSkipped`, and fails the import with `.unreadableArchive` when no pages were found otherwise; the outer archive and its parts together may hold at most 200,000 entries and 8 GB unpacked, as stated by the archive's directory (`zipinfo -s`) before anything is unpacked, the outer archive charged in full (hidden files and files that aren't valid ZIPs included) and a part's listed size given back only once that part has been opened and charged at its unpacked size (`ZipLimits`, also applied to `.textpack` files), or the import fails with the new `.archiveTooLarge`), and a folder every page sits in is not part of the tree. Each top-level page with subpages gets a new notebook through `newNotebookForImport` ("Projects 2" when "Projects" exists, per §3.11); pages under the same top-level folder share it, even across parts, and two top pages with the same title get their own notebooks. Page links are not flattened to plain titles: linking has shipped, so ids are assigned up front and links between pages (and to databases' `.csv`) become note links, with the same cancel guarantee as `MarkdownImporter` (`NoteStore.unresolveLinksToSkipped`, now shared); links outside the export stay title links named by the page title without its id. When both `X.csv` and `X_all.csv` exist the full `_all` file is used. A page without its title as the first line gets one. `rowsTruncated` is computed from the new `ImportReport.truncatedTables`, whose names the summary shows ("Only the first 1,000 rows of “X” were imported."). Images are limited to 25 MB and to files inside the export; images on the web are kept as links to their address (named by the alt text, or the address) rather than downloaded, as NoteIt has no downloader to reuse; every text rewrite of a page (`<aside>` callouts, `.csv` links, web images) goes through `NotionImporter.outsideCode`/`CodeFence`, so fenced code blocks (closed CommonMark-style: same character, at least as long, at most three spaces' indent, same quote depth) and code spans keep their text exactly (the id suffix is only stripped from link targets and titles, never from text); unreadable pages count as unreadable files.

8.1 and 8.2 can run in parallel with each other and with any other milestone.

## Milestone 9: Documentation

### Task 9.1: Docs

**Files:** `docs/architecture.md`, `docs/known-limitations.md`, `docs/roadmap.md`, `docs/development.md`, `README.md`

- [ ] `architecture.md` storage section: the two formats, `NoteBodyStorage` (foundations), the data folder (`NoteStore.rootURL`) versus the content folder (`contentRootURL`) and why derived and per-Mac files never go in the content folder, nested notebook folders, wiki links on disk, the watcher and the mass-deletion guard, conversion commit point, backup layout. Folder table gains `Sources/NoteItMarkdown`, `MarkdownLibrary/`, `Backup/`.
- [ ] `known-limitations.md`: folders deeper than 4 levels map to the notebook at level 4; font families other than the body font are not kept in Markdown; backups are not encrypted; a Markdown folder in a cloud drive alongside NoteIt Sync can create duplicates.
- [ ] `development.md`: `NOTEIT_MARKDOWN_ROOT`, `NOTEIT_SYNC_SELFTEST_MARKDOWN`.
- [ ] `README.md`: one line under features: "Keep your notes as plain Markdown files, if you like."
- [ ] Verify: `grep -rn '/Users/' docs README.md` prints nothing.

## Milestone 10 (wave 3): Locked notes

Locked notes ship with sync-security's milestone M5 in wave 3 (program §1, §8). This milestone starts after sync-security Task 5.1 (`LockedBody`, `SealedNoteHeader`, `NoteLockKeyring`) and needs Milestones 3, 5, 6 and 7. It is the only part of this plan that uses those types.

### Task 10.1: Locked notes in a Markdown library

**Files:** `Sources/NoteIt/MarkdownLibrary/{LockedNoteFiles,MarkdownBodyStorage,ExternalChangeHandler,LibraryConverter}.swift`, `Tests/NoteItTests/{LockedMarkdownNoteTests,ExternalChangeTests,LibraryConverterTests}.swift`

- [ ] `MarkdownBodyStorage` implements the sealed-file methods that sync-security Task 5.2 adds to `NoteBodyStorage`, for `.noteit/locked/<uuid>.sealed` and the placeholder. It lands together with Task 5.2. Sealed files are built with `LockedBody.seal` and checked with `LockedBody.header(of:)`; `LockedNoteFiles.lockFromHeader` builds the `NoteLock` from the `SealedNoteHeader`.
- [ ] `LockedMarkdownNoteTests` (sealed files built with `LockedBody`):
  - a locked note is `.noteit/locked/<uuid>.sealed` plus a placeholder `.md` with `locked: true`, the title and "This note is locked. Open it in NoteIt to read it."; no body text appears anywhere in the content folder;
  - `NoteMeta.lock` lost from `library.json` is rebuilt from the sealed header; a placeholder without `locked: true` is still locked when its sealed file exists; `locked: true` without a sealed file doesn't lock anything;
  - text added to a placeholder outside NoteIt becomes an "(Outside NoteIt)" note and the placeholder is rewritten;
  - deleting the placeholder moves the note to Recently Deleted and keeps the sealed file; Recover writes the placeholder again and the note is still locked;
  - the sealed file is deleted on every permanent path, one test each: Delete Now, Empty Recently Deleted, and the 30-day purge (injected clock);
  - Remove Lock writes the plain body to the `.md` file and deletes the sealed file;
  - a scan and a conversion never delete a sealed file;
  - locked notes are never passed to `DerivedIndex` indexers with body text.
- [ ] `ExternalChangeTests`: a deleted locked-note placeholder → Recently Deleted, sealed file kept.
- [ ] `LibraryConverter` copies sealed files as they are in step 3 of spec §3.6 and compares them by SHA-256 in step 4. `LibraryConverterTests`: `notes/<uuid>.locked` becomes `.noteit/locked/<uuid>.sealed` byte for byte and back, verified by SHA-256, never opened; the lock survives both ways; Markdown → RTFD removes `.noteit/` only after the sealed files moved out.
- [ ] Verify: `swift test --filter "LockedMarkdownNoteTests|ExternalChangeTests|LibraryConverterTests"` → 0 failures.

### Task 10.2: Locked notes in backups and restore drills

This task is the only owner of locked notes in backups: writing, checking and restoring them. Sync-security Task 5.5 covers export only and doesn't touch `BackupWriter`, `BackupReader` or `BackupRestorer`.

**Files:** `Sources/NoteIt/Backup/{BackupWriter,BackupReader,BackupRestorer,DataActions}.swift`, `Sources/NoteItSync/Engine/RemoteRestoreDrill.swift`, `Tests/NoteItTests/BackupTests.swift`, `Tests/NoteItSyncTests/RemoteRestoreDrillTests.swift`, `docs/architecture.md`

- [ ] `BackupTests` (writer): sealed files under `.noteit-backup/locked/<uuid>.sealed` and `lock-keys.json` under `.noteit-backup/locked/` byte for byte, in `files` with their hashes, `lockedCount` set, placeholder `.md` in the tree, never opened. `testRTFDBackupIncludesSealedFilesAndLockKeys` (an RTFD library's `notes/<uuid>.locked` files and `lock-keys.json` go in byte for byte); `testBackupNeverContainsPlaintext` (no ZIP entry, the manifest included, contains the locked note's body text, from either library format).
- [ ] `BackupTests` (check and restore): a flipped byte in a sealed file or `lock-keys.json` → `damagedFiles`; `lockedNotes` counts sealed files and the sheet shows "2 locked notes (sealed, not opened)"; no sealed file is opened; a missing locked note is restored as its sealed file and the backup's `lock-keys.json` is merged with `NoteLockKeyring.merged(with:)`; a changed locked note is listed in `lockedNotReplaced` and left alone; `testRestoredLockedNoteOpensWithSamePassword` (delete a locked note, restore it from the backup, unlock it with the original notes password and get the original text).
- [ ] `RemoteRestoreDrillTests`: a `noteit-locked/1` body is checked by `bodySHA256` only and counted in `lockedNotes`, a mismatching one is unreadable; locked notes without `noteit/v1/keys/locked-notes.json` on the remote → reported. The result sheet adds "N locked notes (sealed, not opened)".
- [ ] `architecture.md` storage section: locked notes (`.noteit/locked/<uuid>.sealed` and placeholders) and their place in backups.
- [ ] Verify: `swift test --filter "BackupTests|RemoteRestoreDrillTests"` → 0 failures.

10.1 and 10.2 can run in parallel.

---

## Self-review

- **Spec coverage:** dialect, flavours and golden tests (2.2, 2.3), import options and `case markdown` of `BodyCodec` (2.4), front matter (2.1, 3.2), folders, nested notebooks and attachments (3.1, 3.2), wiki links (2.3, 3.5), locked notes on disk, in conversion, backups and drills (10.1, 10.2, wave 3), watching, conflicts and the mass-deletion guard (4.1–4.3), conversion both ways, adoption and the previous library (5.1, 5.2), history, trash, search, recovery (3.3), sync (3.4), Your Data (6.1), backup ZIP and automatic backups (6.2, 6.3), Local API routes (6.4), restore drills (7.1, 7.2), Evernote and Notion (8.1, 8.2), docs (9.1). Sealing, keys and Lock/Remove Lock themselves belong to sync-security.
- **Contract compliance (program design):** `NoteItDoc` split, `NoteBodyStorage` and `BodyCodec` come from foundations and are not re-planned (§2); `NoteItMarkdown` depends only on `NoteItDoc`, is the one lossless Markdown path, has the `library` and `portable` flavours and `MarkdownImportOptions.resolveImage`, and `case markdown` is added inside the `BodyCodec` enum body in wave 1, with a branch in each switch (§6); nothing derived or per-Mac is written to `contentRootURL` (§7, asserted in 3.2 and 5.1); locked-note layout, backup and checks follow §8 (Milestone 10, wave 3, as §1 and §8 schedule locked notes); tab, palette ids and menu order follow §9; programmatic body changes go through `NoteStore.editBody` and indexes through `DerivedIndex`; Local API routes are registered through `LocalAPIRouteRegistry` with `markdown-storage.<name>` ids; the §11 safety rules are tested in 4.3 and 5.1; §12 notebook folders, `.noteit-notebook.json` (no board fields) and wiki-link syntax, including `\|` in table cells, are tested in 2.3, 3.1 and 3.5.
- **No behaviour change before it is wanted:** Milestone 1 only adds the library location file, checked by the existing tests and self-tests; the Markdown format has no UI until Milestone 5, and Markdown storage is offered only from Your Data.
- **Data safety:** every write is atomic; every conversion is staged, verified and committed by one file; sealed files are moved, never opened; many missing files at once are held until the user confirms; adopted folders keep their file names; the previous library is never trashed without asking; removals go to the macOS Trash; restore never deletes and can be undone; drills are read-only (asserted by tests on the backend and the library).
- **Sync unchanged:** no new remote objects, no change to `noteit/v1/`; 3.4 runs the existing sync self-test with one Markdown device; 5.1 asserts a conversion causes no uploads.
- **Type consistency:** `LibraryFormatKind`, `MarkdownCodec`, `MarkdownImportOptions`, `FrontMatter`, `NotebookFolders`, `WikiLinkResolver`, `LockedNoteFiles`, `MassDeletionGuard`, `BackupManifest`, `RemoteRestoreDrill` are used with the signatures in Frozen interfaces throughout; `NoteBodyStorage` and `BodyCodec` with foundations' signatures.
- **Dependencies:** everything waits for wave 0 foundations. Nested notebooks need organise's `parent` field; wiki-link resolution follows linking's rules; Milestone 10 is wave 3 and waits for sync-security Task 5.1; Milestones 1–9 use no lock types. Milestones 1, 6 (RTFD cases), 7.2 and 8 don't need the codec.
- **Risks:** Markdown parsing fidelity (mitigated by property tests over random docs and the 1% fallback ceiling); FSEvents edge cases on network volumes (mitigated by launch rescans and the pre-write check); large libraries (benchmark in 4.1).
