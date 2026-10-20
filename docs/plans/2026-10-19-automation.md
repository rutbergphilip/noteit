# NoteIt Automation Implementation Plan

**Goal:** Ship the `noteit://` URL scheme with x-callback-url and Copy Note Link, Shortcuts actions (App Intents), Spotlight indexing, the Mac Share extension, the `noteit` command line tool, and the Local API (localhost HTTP+JSON, off by default, paired per-client tokens with scopes) that every other integration uses.

**Architecture:**
- Targets follow the program's target graph (program design §1). `NoteItAPI` (macOS; depends on `NoteItCore` and `NoteItSync`; Foundation, Network, CryptoKit, Security; no AppKit) is created in foundations (program design §2, step 5; formerly T1, T5 and T17 here):
  - 5.1: the v1 wire types, `HTTPMessage`, the `NoteItAPITests` target and the `NoteItCLI` stub with `CLIExit`;
  - 5.2: `RouteMatch`, `OriginDecision`, `LocalAPIContext`, `ClientRecord` and `LocalAPIRouteRegistry`;
  - 5.3: `NoteLink`, `URLCommand` and `AppendPosition` in `NoteItCore`;
  - 5.4: `URLRouteRegistry`, an app-target `@MainActor` class at `Sources/NoteIt/Automation/URLScheme/URLRouteRegistry.swift`;
  - 5.5: the embeds table in `scripts/build_app.sh`.

  This plan fills `NoteItAPI` in:
  - the server core: incremental HTTP/1.1 parser, router, request policy (Host, Origin/CORS, origin binding), rate limiter, pairing broker, client registry, change hub, and an `NWListener` transport, all in `Sources/NoteItAPI/Server/`;
  - the client: `NoteItAPIClient` and `AppLocator` (discovery, launching the app), shared by the CLI and by `noteit mcp` (`private-ai`).
- `NoteItCore` holds the pure `URLCommand` parser (built in foundations 5.3), so the phone uses it too. Link grammar comes from `NoteItCore.NoteLink` (shape owned by `linking`, built in foundations 5.3).
- The app target adds one facade, `AutomationService`, over `NoteStore`. It reads through `NoteStore` and `NoteBodyStorage`, changes text only through `NoteStore.editBody`, and converts Markdown only through `NoteItMarkdown`. Five surfaces plug into it: URL scheme, Local API handlers, App Intents, Spotlight, the Share extension inbox. `LibraryChangeFeed` turns store changes into `LibraryChange` values for the event feed. Spotlight registers as a `DerivedIndex` and gets every change, metadata-only ones included, through its hooks (`noteChanged`, `noteRemoved`, `metadataChanged`, `rebuild`, `flush`).
- `NoteItCLI` (macOS executable; depends on `NoteItAPI` only) ships as `NoteIt.app/Contents/Helpers/noteit`. This plan builds it out in wave 1 without the `mcp` subtree; `private-ai` adds the `NoteItMCP` dependency and `noteit mcp` in wave 2.
- `NoteItShareExtension` is built by a script with `xcrun swiftc` into `Contents/PlugIns/NoteItShare.appex`, like the Safari extension; `Package.swift` lists it only so it type-checks.

**Tech stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftPM, Network.framework (`NWListener`/`NWConnection`), CryptoKit (SHA-256), Security (Keychain, `SecRandomCopyBytes`), CoreSpotlight, AppIntents, SwiftUI/AppKit, NSExtension (share services). No new third-party dependencies. Tests use XCTest via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

**Spec:** `docs/specs/2026-10-19-automation-design.md`. Program contract: `docs/specs/2026-10-19-program-design.md` (it wins where they differ). Foundations: `docs/plans/2026-10-19-foundations.md`.

---

## Conventions for every task

- Test command (from the repository root): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite> 2>&1 | tail -20`. Expected: `Executed <n> tests, with 0 failures`.
- App build: `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3` must both end with `Build complete!` and 0 errors.
- Never touch real user data. Running the app from the repository root: `NOTEIT_DATA_DIR="$PWD/.selftest/<name>" swift run NoteIt` (`<name>` is any folder name) (`.selftest` is gitignored). The discovery file then lives in that folder too.
- Tests that need a store use `NoteStore(location: LibraryLocation(url: <temp>/lib, seedsFreshLibrary: false))` and a throwaway `UserDefaults(suiteName:)`, as `Tests/NoteItTests/CaptureControllerTests.swift` does.
- Tests never bind a fixed port. Server tests bind port 0 and read the assigned port.
- Tests never write the login Keychain. Keychain access is behind `SecretStore` (`Sources/NoteItSync/Migration/SecretMigration.swift`); tests inject an in-memory store.
- Everything in `NoteItAPI` the app or CLI needs is `public` and `Sendable`-correct.
- Commit after each task with Conventional Commits, e.g. `feat(automation): add url scheme parser`. Never amend, rebase or force.
- No `#Preview`. Comments only where something is non-obvious.
- User-facing strings are copied exactly from the spec.
- Body changes go through `NoteStore.editBody` only; Markdown goes through `NoteItMarkdown` only; no task edits `NoteStore.swift` to add a hook.
- Registered routes use a route id `<slug>.<name>`, an explicit scope and `APIErrorCode` errors only.

## File structure

```
Package.swift                                         (modify: NoteItCLITests, NoteItShareExtension (type-check only); the NoteItAPI, NoteItCLI and NoteItAPITests targets come from foundations 5.1)
Sources/NoteItCore/URLCommand.swift                   (from foundations 5.3) pure noteit:// parser and AppendPosition, shared with the phone
Sources/NoteItCore/ShareInboxItem.swift               (new) share inbox item model, also compiled into the appex
Sources/NoteItAPI/                                    (target and Wire/ from foundations; this plan adds)
  Wire/*                                              (modify: additions in Frozen interfaces)
  Server/HTTPMessage.swift                            (from foundations 5.1) HTTPRequest, HTTPResponse, HTTPHeaders
  Server/HTTPParser.swift                             incremental request parser with limits
  Server/RouteMatch.swift, OriginDecision.swift, LocalAPIContext.swift   (from foundations 5.2)
  Server/Router.swift                                 pattern matching with {params}
  Server/RequestPolicy.swift                          Host check, Origin/CORS, content type, origin binding (Safari by scheme + bundle id)
  Server/RateLimiter.swift                            token buckets, injectable clock
  Server/ClientRegistry.swift                         (modify; from foundations 5.2 with ClientRecord only) ClientStore protocol, InMemoryClientStore, verification
  Server/PairingBroker.swift                          pairing state machine
  Server/ChangeHub.swift                              ring buffer, cursors, subscribers (SSE)
  Server/LocalHTTPServer.swift                        NWListener/NWConnection transport, keep-alive, SSE streaming
  Server/LocalAPIRouteRegistry.swift                  (modify; from foundations 5.2) wired into the server; adds extendTags and NotebookDTOExtending
  Server/OpenAPIDocument.swift                        builds openapi.json from APIRoutes and registered routes
  Client/NoteItAPIClient.swift                        URLSession client
  Client/AppLocator.swift                             discovery → launch fallback → ping
Sources/NoteItCLI/                                    (target from foundations 5.1; bundled as Contents/Helpers/noteit)
  main.swift                                          (modify; stub and CLIExit from foundations 5.1) entry; maps errors to exit codes
  CLIArguments.swift                                  hand-written parser
  CLICommands.swift                                   command implementations
  CLIOutput.swift                                     human and --json output
  CLIKeychain.swift                                   token storage, profile names
  CLIEditor.swift                                     $VISUAL/$EDITOR round trip
Sources/NoteItShareExtension/                         (new; built by script into Contents/PlugIns/NoteItShare.appex)
  ShareViewController.swift                           NSViewController for the share sheet
  ShareItemWriter.swift                               writes images then item.json into the inbox, opens noteit://new?inbox=
Sources/NoteIt/Automation/                            (new)
  AutomationService.swift                             facade used by every surface
  AutomationClients.swift                             in-process issue/list/revoke (AutomationService.clients)
  AutomationError.swift                               error enum + codes
  AutomationService+Body.swift                        body reads and writes: NoteItMarkdown, DocConverter, HTMLWriter, editBody
  StagedUploads.swift                                 staged attachment files (1 h, 100 MB)
  LibraryChangeFeed.swift                             LibraryDiff (pure) + store subscription
  URLScheme/URLRouteRegistry.swift                    (from foundations 5.4)
  URLScheme/URLSchemeHandler.swift                    Apple Event handler, URLRouteRegistry dispatch, confirmation, x-callback, notices
  URLScheme/CopyNoteLink.swift                        the one Copy Note Link command
  LocalAPI/LocalAPIController.swift                   lifecycle, prefs, discovery, port choice
  LocalAPI/LocalAPIHandlers.swift                     route handlers → AutomationService
  LocalAPI/KeychainClientStore.swift                  ClientStore over SecItemStore
  LocalAPI/PairingWindow.swift                        pairing UI
  LocalAPI/CLIInstaller.swift                         /usr/local/bin symlink
  Spotlight/SpotlightItemBuilder.swift                pure item building + shouldIndex
  Spotlight/SpotlightIndexer.swift                    DerivedIndex conformance, CSSearchableIndex batches, rebuilds
  Intents/NoteEntity.swift                            NoteEntity, NotebookEntity, queries
  Intents/NoteIntents.swift                           the six intents
  Intents/NoteItShortcuts.swift                       AppShortcutsProvider
  Share/ShareInboxImporter.swift                      imports inbox items through AutomationService
Sources/NoteIt/Settings/IntegrationsSettingsView.swift   (new)
Resources/NoteItShareExtension.entitlements           (new) App Sandbox + app group
Resources/NoteIt.entitlements                         (modify) app group
scripts/build_share_extension.sh                      (new) compiles and assembles NoteItShare.appex
(modify)
  Sources/NoteIt/App/AppDelegate.swift                URL handler, continue user activity, start controllers, share inbox import
  Sources/NoteIt/App/MenuShortcuts.swift              MenuShortcutCommand.copyNoteLink (⌃⌘L)
  Sources/NoteIt/App/PlannedMenuShortcuts.swift       remove the copyNoteLink row
  Sources/NoteIt/App/ExportCommands.swift             Edit › Copy Note Link
  Sources/NoteIt/Palette/PaletteCommandRegistry.swift four commands
  Sources/NoteIt/Settings/SettingsView.swift          fill in the .integrations tab from the frozen table; isAvailable true
  Sources/NoteIt/Settings/Preferences.swift           PrefKey entries
  Sources/NoteIt/Sync/Keychain.swift                  SecItemStore label parameter
  scripts/build_app.sh                                CFBundleURLTypes, embeds rows (Contents/Helpers/noteit, Contents/PlugIns/NoteItShare.appex), App Intents metadata
  docs/architecture.md, docs/development.md, docs/keyboard-shortcuts.md, docs/known-limitations.md, docs/roadmap.md, README.md
  docs/local-api.md                                   (new) Local API reference for integrators
Tests/NoteItAPITests/                                 (target from foundations 5.1) HTTPParserTests, RouterTests, RequestPolicyTests, RateLimiterTests,
                                                      PairingBrokerTests, ClientRegistryTests, ChangeHubTests, LocalHTTPServerTests, LocalAPIRouteRegistryTests (modify; from 5.2),
                                                      AppLocatorTests, NoteItAPIClientTests, OpenAPIDocumentTests, Support/InMemorySecretStore.swift
Tests/NoteItCoreTests/                                ShareInboxItemTests (URLCommandTests come from foundations 5.3)
Tests/NoteItCLITests/                                 CLIArgumentsTests, CLIOutputTests
Tests/NoteItTests/                                    AutomationServiceTests, AutomationErrorTests, LibraryDiffTests, URLSchemeHandlerTests,
                                                      LocalAPIHandlersTests, SpotlightItemBuilderTests, CLIInstallerTests, ShareInboxImporterTests
```

## Frozen interfaces

Foundations implements the `AppIdentity` constants, the `NoteItAPI` wire types, `APIRoutes`, `RouteSpec`, `HTTPMessage`, `RouteMatch`, `OriginDecision`, `ClientRecord`, `LocalAPIContext`, `LocalAPIRouteRegistry`, `URLCommand` and `URLRouteRegistry` exactly as written here (marked "built in foundations"); this plan owns their shape and fills in behaviour. `extendTags`, `NotebookDTOExtending` and everything not marked are built by this plan.

```swift
// NoteItSync/Migration/AppIdentity.swift (additions)
public static let urlScheme = "noteit"
public static let localAPIKeychainService = bundleID + ".local-api"
public static let cliKeychainService = bundleID + ".cli"

// NoteItAPI/Wire/APIScope.swift
public enum APIScope: String, Codable, Sendable, CaseIterable, Comparable {
    case read, write, admin
    public func allows(_ required: APIScope) -> Bool          // admin ⊇ write ⊇ read
    public static func normalized(_ scopes: [APIScope]) -> [APIScope]   // dedupe + sort
}

// NoteItAPI/Wire/APIModels.swift (all Codable, Sendable, Equatable)
public enum BodyFormatDTO: String, Codable, Sendable { case markdown, text, html, noteitDoc = "noteit-doc" }
public enum ClientKind: String, Codable, Sendable { case cli, `extension`, mcp, script }        // no plugin kind: plugins never hold tokens
public struct NoteSummaryDTO { public var id: UUID; public var title: String; public var notebookID: UUID?; public var notebookName: String?
    public var tags: [String]; public var pinned: Bool; public var createdAt: Date; public var updatedAt: Date; public var revision: UUID?
    public var deletedAt: Date?; public var preview: String; public var conflict: Bool; public var locked: Bool
    public var url: String }                                     // url = noteit://note/<UUID>; locked notes have preview ""
public struct NoteDTO { public var summary: NoteSummaryDTO; public var format: BodyFormatDTO; public var body: String }   // encodes flat
public struct NotebookDTO { public var id: UUID; public var name: String; public var symbol: String; public var color: String; public var sortIndex: Int; public var noteCount: Int
    public var parentID: UUID?; public var path: [String]? }    // parentID and path are organise's; nil until it ships nested notebooks
public struct TagDTO { public var name: String; public var noteCount: Int }
public struct TagNodeDTO { public var name: String; public var path: String; public var noteCount: Int; public var totalCount: Int; public var children: [TagNodeDTO] }   // GET /v1/tags?tree=1; built by organise's provider (extendTags)
public enum ChangeKind: String, Codable, Sendable { case note, notebook }
public enum ChangeOp: String, Codable, Sendable { case created, updated, deleted, restored, purged }
public struct ChangeDTO { public var cursor: String; public var kind: ChangeKind; public var id: UUID; public var op: ChangeOp; public var at: Date }
public struct ChangesPage { public var changes: [ChangeDTO]; public var cursor: String; public var hasMore: Bool }
public struct Page<T: Codable & Sendable & Equatable> { public var items: [T]; public var nextCursor: String? }
public struct ClientDTO { public var id: UUID; public var name: String; public var kind: ClientKind; public var scopes: [APIScope]
    public var origin: String?; public var tokenHint: String; public var createdAt: Date; public var lastUsedAt: Date? }
public struct PingDTO { public var name: String; public var apiVersion: Int; public var appVersion: String; public var capabilities: [String] }   // not `features`
public struct CreateNoteRequest { public var title: String?; public var body: String; public var format: BodyFormatDTO?
    public var notebookID: UUID?; public var notebook: String?; public var tags: [String]?; public var pinned: Bool? }
public struct PatchNoteRequest { public var title: String?; public var body: String?; public var format: BodyFormatDTO?; public var notebookID: UUID?; public var pinned: Bool? }
public typealias AppendPosition = NoteItCore.AppendPosition       // declared in NoteItCore (foundations 5.3), enum { end, start }
public struct AppendRequest { public var text: String; public var format: BodyFormatDTO?; public var position: AppendPosition?; public var timestamp: Bool?; public var ifRevision: UUID? }
public enum DailyFormat: String, Codable, Sendable { case plain, markdown }
public struct DailyAppendRequest { public var text: String; public var timestamp: Bool?; public var date: String?; public var format: DailyFormat? }   // format default plain
public struct NotebookRequest { public var name: String?; public var symbol: String?; public var color: String? }
public enum HighlightField: String, Codable, Sendable { case title, body }
public struct HighlightDTO { public var field: HighlightField; public var ranges: [[Int]] }   // [start, length] pairs, UTF-16; into the title for .title, into snippet for .body
public struct SearchResultDTO { public var note: NoteSummaryDTO; public var snippet: String; public var score: Double?
    public var highlights: [HighlightDTO]?; public var matchedBy: [String]? }   // optional; organise fills score/highlights, private-ai matchedBy
public struct SearchResponseDTO { public var mode: String; public var results: [SearchResultDTO] }
public struct NotebooksResponseDTO { public var notebooks: [NotebookDTO]; public var defaultNotebookID: UUID? }
public struct AttachmentDTO { public var name: String; public var contentType: String; public var size: Int }
public struct StagedUploadDTO { public var id: String; public var expiresAt: Date }
public struct PairStartRequest { public var clientName: String; public var kind: ClientKind; public var scopes: [APIScope] }
public struct PairStartResponse { public var pairingID: UUID; public var expiresAt: Date }
public struct PairCompleteRequest { public var pairingID: UUID; public var code: String }
public struct PairCompleteResponse { public var token: String; public var clientID: UUID; public var scopes: [APIScope] }

// NoteItAPI/Wire/APIError.swift
public enum APIErrorCode: String, Codable, Sendable, Error {
    case badRequest = "bad_request", unauthorized, tokenRevoked = "token_revoked", forbiddenScope = "forbidden_scope",
         originNotAllowed = "origin_not_allowed", pairingDenied = "pairing_denied", pairingFailed = "pairing_failed",
         notFound = "not_found", noteDeleted = "note_deleted", noteUnreadable = "note_unreadable",
         pairingInProgress = "pairing_in_progress", cursorExpired = "cursor_expired", lengthRequired = "length_required",
         revisionMismatch = "revision_mismatch", tooLarge = "too_large", unsupportedMediaType = "unsupported_media_type",
         misdirected, rateLimited = "rate_limited", internal, apiDisabled = "api_disabled",
         notImplemented = "not_implemented",         // 501, not built into this version yet (daily notes while DailyNotes.isAvailable is false, tag tree without a provider)
         notAvailable = "not_available",             // 501, built but turned off (a search mode)
         readOnly = "read_only",                     // 403, a note in a shared notebook the user can only read (sharing)
         noteLocked = "note_locked",                 // 423
         editorRequired = "editor_required",         // 409, plugins only
         notReady = "not_ready"                      // 503, library still loading
    public var httpStatus: Int                       // revision_mismatch stays 412
}
public struct APIErrorBody: Codable, Sendable, Equatable { public struct Inner: Codable, Sendable, Equatable { public var code: APIErrorCode; public var message: String }; public var error: Inner }

// NoteItAPI/Wire/APIJSON.swift
public enum APIJSON { public static func encoder() -> JSONEncoder; public static func decoder() -> JSONDecoder }

// NoteItAPI/Wire/DiscoveryFile.swift
public struct DiscoveryFile: Codable, Sendable, Equatable {
    public var version: Int; public var pid: Int32; public var appVersion: String; public var apiEnabled: Bool
    public var port: UInt16?; public var baseURL: URL?; public var startedAt: Date
    public static let fileName = "local-api.json"
    /// NOTEIT_DATA_DIR (via AppEnvironment) or ~/Library/Application Support/<AppIdentity.dataFolderName>.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    public static func read(from directory: URL, isProcessAlive: (Int32) -> Bool = DiscoveryFile.processIsAlive) -> DiscoveryFile?   // nil if missing, corrupt or stale
    public func write(to directory: URL) throws                    // atomic, 0600
    public static func remove(from directory: URL)
    public static func processIsAlive(_ pid: Int32) -> Bool        // kill(pid, 0) == 0 || errno == EPERM
}

// NoteItAPI/Wire/APIToken.swift
public enum APIToken {
    public static let prefix = "nit_"
    public static func generate() -> String                        // prefix + base64url(32 random bytes), 47 chars
    public static func hash(_ token: String) -> String             // SHA-256 lowercase hex
    public static func hint(_ token: String) -> String             // first 8 characters
    public static func matches(_ token: String, hash: String) -> Bool   // constant-time
    public static func pairingCode() -> String                     // 6 digits, uniform, SecRandomCopyBytes
}

// NoteItAPI/Wire/APIRoutes.swift
public enum HTTPMethod: String, Sendable { case GET, POST, PATCH, DELETE, OPTIONS }
public enum RouteID: String, Sendable, CaseIterable {
    case ping, openapi, pairStart, pairComplete, me, meDelete, notesList, noteCreate, noteGet, notePatch, noteDelete, noteRestore,
         noteAppend, noteOpen, attachmentsList, attachmentGet, attachmentAdd, stagedUpload, trashEmpty, search, notebooksList, notebookCreate,
         notebookPatch, notebookDelete, tags, daily, dailyAppend, changes, events, clientsList, clientDelete
}
public enum RouteBody: Sendable { case none, json, binary }
public enum RouteBucket: Sendable { case unauthenticated, general, write, upload }   // general = every authenticated request
public struct RouteSpec: Sendable { public let id: String          // RouteID.rawValue for built-in routes; "<slug>.<name>" for registered ones
    // registered routes must give an explicit scope (nil only for built-in public routes)
    public let method: HTTPMethod; public let pattern: String; public let scope: APIScope?; public let body: RouteBody
    public let bucket: RouteBucket; public let maxBodyBytes: Int?; public let summary: String   // maxBodyBytes nil = 2 MB JSON / 25 MB binary; cap 60 MB
    // public so other modules (NoteIt app, sub-projects) can build specs; no defaults, every field is given
    public init(id: String, method: HTTPMethod, pattern: String, scope: APIScope?, body: RouteBody,
                bucket: RouteBucket, maxBodyBytes: Int?, summary: String) }
public enum APIRoutes { public static let all: [RouteSpec]; public static let basePath = "/v1" }

// NoteItAPI/Server/HTTPMessage.swift (built in foundations 5.1)
public struct HTTPHeaders: Sendable, Equatable { public subscript(_ name: String) -> String? { get set }  // case-insensitive
    public var pairs: [(String, String)] }
public struct HTTPRequest: Sendable { public var method: String; public var path: String; public var query: [String: String]; public var headers: HTTPHeaders; public var body: Data }
public struct HTTPResponse: Sendable {
    public var status: Int; public var headers: HTTPHeaders; public var body: Data
    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse
    public static func error(_ code: APIErrorCode, _ message: String) -> HTTPResponse
    public func serialized(keepAlive: Bool) -> Data
}

// NoteItAPI/Server/HTTPParser.swift
public struct HTTPParserLimits: Sendable { public var maxHeaderBytes = 16_384; public var maxJSONBody = 2_000_000; public var maxBinaryBody = 25_000_000 }
public enum HTTPParseResult: Equatable { case needMore, request(HTTPRequest, consumed: Int), failure(status: Int, APIErrorCode) }
public enum HTTPHeadResult: Equatable { case needMore, head(HTTPRequest, bodyStart: Int, contentLength: Int), failure(status: Int, APIErrorCode) }
public struct HTTPParser { public init(limits: HTTPParserLimits = .init()); public func parse(_ buffer: Data) -> HTTPParseResult
                           public func parseHead(_ buffer: Data) -> HTTPHeadResult }                                // head only, no body limit

// NoteItAPI/Server/RouteMatch.swift (built in foundations 5.2)
public struct RouteMatch: Sendable { public let spec: RouteSpec; public let params: [String: String] }
// NoteItAPI/Server/Router.swift
public struct Router: Sendable { public init(routes: [RouteSpec] = APIRoutes.all)
    public func match(method: String, path: String) -> Result<RouteMatch, APIErrorCode> }   // .notFound or 405 as .badRequest

// NoteItAPI/Server/OriginDecision.swift (built in foundations 5.2)
public enum OriginDecision: Equatable, Sendable { case native, extensionOrigin(String), rejected }
// NoteItAPI/Server/RequestPolicy.swift
public struct RequestPolicy: Sendable {
    public static let extensionBundleHeader = "X-NoteIt-Extension-Bundle"   // sent by Safari extensions on every request
    public init(port: UInt16)
    public func checkHost(_ request: HTTPRequest) -> Bool
    public func classifyOrigin(_ request: HTTPRequest) -> OriginDecision
    public func preflight(_ request: HTTPRequest) -> HTTPResponse?            // 204 for allowed OPTIONS, nil otherwise
    public func corsHeaders(for decision: OriginDecision) -> HTTPHeaders
    public func checkContentType(_ request: HTTPRequest, route: RouteSpec) -> APIErrorCode?
    /// The origin stored on a new client: nil for .native, the full origin for Chrome and Firefox,
    /// "safari-web-extension:<bundle id>" for Safari (nil bundle → .badRequest).
    public static func storedOrigin(for decision: OriginDecision, extensionBundle: String?) -> Result<String?, APIErrorCode>
    public static func originBindingAllows(record: ClientRecord, decision: OriginDecision, extensionBundle: String?) -> Bool
}

// NoteItAPI/Server/RateLimiter.swift
public final class RateLimiter: @unchecked Sendable {
    public struct Rule: Sendable { public var perSecond: Double; public var burst: Double }
    public static let defaults: [RouteBucket: Rule]   // general 10/s b60, write 2/s b20, upload 0.5/s b10, unauthenticated 0.5/s b10
    public init(rules: [RouteBucket: Rule] = defaults, now: @escaping @Sendable () -> Date = Date.init)
    /// nil = allowed; otherwise seconds to wait. Write and upload requests also consume from the client's .general bucket.
    public func consume(client: String, bucket: RouteBucket) -> Int?
}

// NoteItAPI/Server/ClientRegistry.swift (ClientRecord built in foundations 5.2; the rest is this plan's)
public struct ClientRecord: Codable, Sendable, Equatable { public var id: UUID; public var name: String; public var kind: ClientKind
    public var scopes: [APIScope]; public var origin: String?; public var tokenHash: String; public var tokenHint: String; public var createdAt: Date }   // origin: "safari-web-extension:<bundle id>" for Safari
public protocol ClientStore: Sendable { func load() -> [ClientRecord]; func save(_ records: [ClientRecord]) throws }
public final class InMemoryClientStore: ClientStore, @unchecked Sendable { public init(_ records: [ClientRecord] = []) }
public final class ClientRegistry: @unchecked Sendable {
    public init(store: ClientStore)
    public var clients: [ClientRecord] { get }
    public func authenticate(bearer: String?) -> ClientRecord?
    public func issue(name: String, kind: ClientKind, scopes: [APIScope], origin: String?, now: Date = Date()) throws -> (ClientRecord, token: String)
    public func revoke(_ id: UUID) throws
    public func revokeAll() throws
    public var onRevoke: (@Sendable (UUID) -> Void)?
}

// NoteItAPI/Server/PairingBroker.swift
public struct PairingRequest: Sendable, Equatable { public var id: UUID; public var clientName: String; public var kind: ClientKind
    public var requestedScopes: [APIScope]; public var origin: String?; public var code: String; public var expiresAt: Date }
public enum PairingEvent: Sendable, Equatable { case started(PairingRequest), finished(UUID, success: Bool), cancelled(UUID, reason: String) }
public final class PairingBroker: @unchecked Sendable {
    public static let lifetime: TimeInterval = 120; public static let maxAttempts = 5
    public init(registry: ClientRegistry, now: @escaping @Sendable () -> Date = Date.init, code: @escaping @Sendable () -> String = APIToken.pairingCode)
    public var onEvent: (@Sendable (PairingEvent) -> Void)?
    public func start(_ request: PairStartRequest, origin: String?) -> Result<PairStartResponse, APIErrorCode>   // caps extension scopes at write
    public func setGrantedScopes(_ scopes: [APIScope], for id: UUID)    // user unticked scopes in the window
    public func deny(_ id: UUID)
    public func complete(_ request: PairCompleteRequest, origin: String?) -> Result<PairCompleteResponse, APIErrorCode>
}

// NoteItAPI/Server/ChangeHub.swift
public final class ChangeHub: @unchecked Sendable {
    public static let capacity = 5_000
    public init(bootID: String = UUID().uuidString.prefix(8).description)
    public var currentCursor: String { get }
    public func publish(kind: ChangeKind, id: UUID, op: ChangeOp, at: Date)
    public func changes(since cursor: String?, limit: Int) -> Result<ChangesPage, APIErrorCode>   // .cursorExpired on unknown boot or overflow
    public func subscribe(client: UUID, after cursor: String?, _ send: @escaping @Sendable (ChangeDTO) -> Void) -> Result<UUID, APIErrorCode>  // max 4/client, 16 total
    public func unsubscribe(_ subscription: UUID)
    public func closeAll(client: UUID)
}

// NoteItAPI/Server/LocalAPIContext.swift (built in foundations 5.2)
public struct LocalAPIContext: Sendable { public let request: HTTPRequest; public let route: RouteMatch; public let client: ClientRecord?; public let origin: OriginDecision }
// NoteItAPI/Server/LocalHTTPServer.swift
public protocol LocalAPIResponder: Sendable { func respond(_ context: LocalAPIContext) async -> HTTPResponse }
// NoteItAPI/Server/LocalAPIRouteRegistry.swift (built in foundations 5.2; T10 adds the tag and notebook extensions).
// Routes, search modes and capabilities added by other sub-projects; the server routes over APIRoutes.all + registered specs.
public typealias SearchModeHandler = @Sendable (_ query: SearchQuery, _ context: LocalAPIContext) async -> Result<[SearchResultDTO], APIErrorCode>
public struct SearchQuery: Sendable { public var q: String; public var notebook: String?; public var tag: String?; public var limit: Int }
public final class LocalAPIRouteRegistry: @unchecked Sendable {
    public static let shared: LocalAPIRouteRegistry
    public func register(_ spec: RouteSpec, handler: @escaping @Sendable (LocalAPIContext) async -> HTTPResponse)   // precondition: no conflict, id "<slug>.<name>", scope set
    public func registerSearchMode(_ name: String, handler: @escaping SearchModeHandler)                            // precondition: not "keyword", not taken
    public func addCapability(_ name: String)                                                                        // kebab-case; merged into PingDTO.capabilities
    public func removeCapability(_ name: String)                                                                     // idempotent; ping lists current capabilities only
    public var routes: [RouteSpec] { get }
    public var capabilities: [String] { get }
    public func handler(for id: String) -> (@Sendable (LocalAPIContext) async -> HTTPResponse)?
    public func searchMode(_ name: String) -> SearchModeHandler?
    public func validate() -> [String]                                                                               // conflicts, for tests
    // Added by T10 (stored under the same lock):
    public func extendTags(treeProvider: @escaping TagTreeProvider)                                                  // precondition: only one provider
    public var tagTreeProvider: TagTreeProvider? { get }                                                             // nil → GET /v1/tags?tree=1 is 501 not_implemented
    public func extendNotebooks(with extender: NotebookDTOExtending)
    public var notebookExtenders: [NotebookDTOExtending] { get }                                                     // run in registration order
}
public typealias TagTreeProvider = @MainActor @Sendable () -> [TagNodeDTO]                                           // organise's tag tree
public protocol NotebookDTOExtending: AnyObject, Sendable {                                                          // organise: parentID, path
    @MainActor func extend(_ dto: inout NotebookDTO, notebookID: UUID)
}
public final class LocalHTTPServer: @unchecked Sendable {
    public init(registry: ClientRegistry, pairing: PairingBroker, changes: ChangeHub, limiter: RateLimiter, responder: LocalAPIResponder,
                ping: @escaping @Sendable () -> PingDTO, limits: HTTPParserLimits = .init(),
                routeRegistry: LocalAPIRouteRegistry = .shared)                                                      // T10: injectable so tests never touch .shared
    /// Tries each port in order and returns the bound one. Port 0 = ephemeral (tests).
    public func start(ports: [UInt16]) async throws -> UInt16                                                         // .alreadyRunning while running or another start is pending
    public func stop()                                                                                               // also cancels a pending start, which throws .stopped
}

// NoteItAPI/Client/NoteItAPIClient.swift
public struct NoteItAPIClient: Sendable {
    public init(baseURL: URL, token: String?, session: URLSession = .shared)
    public func send<T: Decodable>(_ method: HTTPMethod, _ path: String, query: [String: String] = [:], json: (any Encodable)? = nil,
                                   headers: [String: String] = [:], as: T.Type) async throws -> T
    public func sendRaw(_ method: HTTPMethod, _ path: String, query: [String: String] = [:], body: Data?, headers: [String: String] = [:]) async throws -> (Int, Data)
    public func events(since cursor: String?) -> AsyncThrowingStream<ChangeDTO, Error>
}
public struct NoteItAPIError: Error, Sendable, Equatable { public var status: Int; public var code: APIErrorCode?; public var message: String }

// NoteItAPI/Client/AppLocator.swift
public enum LocatorResult: Sendable, Equatable { case ready(URL), apiDisabled, notRunning }
public struct AppLocator: Sendable {
    public var environment: [String: String]
    public var readDiscovery: @Sendable () -> DiscoveryFile?
    public var launchApp: @Sendable () throws -> Void            // /usr/bin/open -g -b <bundleID>
    public var ping: @Sendable (URL) async -> Bool
    public var sleep: @Sendable (Duration) async -> Void
    public static func live() -> AppLocator
    public func locate(launch: Bool, timeout: Duration = .seconds(10)) async -> LocatorResult
}

// App target: Automation/AutomationError.swift
enum AutomationError: Error, Equatable {
    case notFound, noteDeleted, noteUnreadable, noteLocked, notReady, notebookNotFound, invalidInput(String), revisionMismatch(current: UUID?),
         formatUnavailable(String), tooLarge, dailyNotesUnavailable, cancelled, versionNotSaved   // formatUnavailable and dailyNotesUnavailable → .notImplemented; versionNotSaved → internal 500
    var apiCode: APIErrorCode
    var callbackCode: String             // x-callback errorCode
    var message: String                  // user-facing, from the spec
}

// App target: Automation/AutomationService+Body.swift. No codec of its own:
// markdown = NoteItMarkdown.MarkdownCodec (profile .portable) + DocConverter; noteit-doc = DocConverter; html = HTMLWriter; text = plainText(for:).
// Every change goes through NoteStore.editBody(_:actionName:versioning:extras:_:) (organise, built in foundations). Version History is
// recorded only by editBody (versioning: .recordCurrent); automation never records a version itself.
extension AutomationService {
    func attributedBody(from text: String, format: BodyFormatDTO, sameNote: UUID? = nil) throws(AutomationError) -> NSAttributedString   // staged images resolved; sameNote's own noteit-attachment:<id>/<name> refs resolved; other paths dropped; html in → formatUnavailable
    func bodyString(of id: UUID, format: BodyFormatDTO) throws(AutomationError) -> String
    func edit(_ id: UUID, actionName: String, versioning: EditBodyVersioning, _ change: (NSMutableAttributedString) throws -> Void) throws(AutomationError)
}

// App target: Automation/AutomationService.swift
@MainActor
final class AutomationService {
    static let shared: AutomationService
    init(store: NoteStore, defaults: UserDefaults = .standard, staged: StagedUploads, now: @escaping () -> Date = Date.init,
         dailyNotesAvailable: @escaping () -> Bool = { DailyNotes.isAvailable },   // injected so tests cover both sides of the gate
         isLoading: (() -> Bool)? = nil)                         // nil reads NoteStore.isLoading; injected so tests cover .notReady
    var clients: AutomationClients                               // in-process issue/list/revoke; added by T12 (needs T9's ClientRegistry)
    func create(title: String?, body: String, format: BodyFormatDTO, notebook: NotebookRef?, tags: [String], pinned: Bool) throws(AutomationError) -> NoteMeta
    func note(_ id: UUID) throws(AutomationError) -> NoteMeta
    func body(_ id: UUID, format: BodyFormatDTO) throws(AutomationError) -> String
    func patch(_ id: UUID, title: String?, body: (String, BodyFormatDTO)?, notebookID: UUID??, pinned: Bool?, ifRevision: UUID?) throws(AutomationError) -> NoteMeta
    func append(_ id: UUID, text: String, format: BodyFormatDTO, position: AppendPosition, timestamp: Bool, ifRevision: UUID?) throws(AutomationError) -> NoteMeta
    func open(_ id: UUID) throws(AutomationError)                // WindowRouter.showMainWindow + reveal
    func moveToRecentlyDeleted(_ id: UUID) throws(AutomationError)
    func deletePermanently(_ id: UUID) throws(AutomationError)   // only notes already in Recently Deleted
    func restore(_ id: UUID) throws(AutomationError) -> NoteMeta
    func emptyRecentlyDeleted()
    func list(notebook: NotebookRef?, tag: String?, query: String?, updatedSince: Date?, deleted: DeletedFilter, sort: ListSort, limit: Int, cursor: String?) throws(AutomationError) -> (notes: [NoteMeta], nextCursor: String?)
    func search(_ query: String, notebook: NotebookRef?, tag: String?, limit: Int) throws(AutomationError) -> [(NoteMeta, snippet: String)]
    func findByTitle(_ title: String) -> NoteMeta?
    func notebooks() -> [(Notebook, noteCount: Int)]
    func createNotebook(name: String, symbol: String?, color: String?) throws(AutomationError) -> Notebook
    func updateNotebook(_ id: UUID, name: String?, symbol: String?, color: String?) throws(AutomationError) -> Notebook
    func deleteNotebook(_ id: UUID) throws(AutomationError)
    func tags() -> [(name: String, count: Int)]
    func attachments(of id: UUID) throws(AutomationError) -> [AttachmentDTO]
    func attachment(of id: UUID, named name: String) throws(AutomationError) -> (contentType: String, data: Data)
    func addAttachment(to id: UUID, data: Data, filename: String, contentType: String) throws(AutomationError) -> NoteMeta
    func daily(date: Date, create: Bool) throws(AutomationError) -> NoteMeta?                         // NoteStore.dailyNote(for:createIfMissing:)
    func appendToDaily(text: String, format: DailyFormat, timestamp: Bool, date: Date) throws(AutomationError) -> NoteMeta   // DailyLogAppender.append(_:timestamp:to:in:now:): .plain, or Markdown parsed to .attributed
    func createFromShare(_ item: ShareInboxItem, files: URL) throws(AutomationError) -> NoteMeta    // added by T24 with ShareInboxItem
    static func link(for id: UUID) -> URL      // NoteLink.note(id).url → noteit://note/<UUID>
}
@MainActor final class AutomationClients {
    init(registry: ClientRegistry)
    func issue(name: String, kind: ClientKind, scopes: [APIScope], origin: String?) throws(AutomationError) -> (ClientDTO, token: String)
    func list() -> [ClientDTO]
    func revoke(_ id: UUID) throws(AutomationError)
}
enum NotebookRef: Equatable { case id(UUID), name(String) }
enum DeletedFilter { case exclude, include, only }
enum ListSort { case list, updated }
/// Daily notes: NoteStore.dailyNote(for:createIfMissing:) and DailyLogAppender (linking; seams from foundations step 4).
/// While DailyNotes.isAvailable (program §5) is false, daily calls throw .dailyNotesUnavailable. Linking sets it to true. There is no fallback provider.

// App target: Automation/LibraryChangeFeed.swift
struct LibraryChange: Equatable { var kind: ChangeKind; var id: UUID; var op: ChangeOp; var at: Date }
enum LibraryDiff {
    static func changes(oldNotes: [UUID: NoteMeta], newNotes: [UUID: NoteMeta], oldNotebooks: [UUID: Notebook], newNotebooks: [UUID: Notebook], at: Date) -> [LibraryChange]
}
@MainActor final class LibraryChangeFeed {
    init(store: NoteStore, debounce: Duration = .milliseconds(250))
    func subscribe(_ handler: @escaping @MainActor ([LibraryChange]) -> Void) -> AnyCancellable
}

// NoteItCore/URLCommand.swift (built in foundations 5.3; public, Foundation only; used by the Mac and the phone)
public struct XCallback: Equatable, Sendable { public var success: URL?; public var error: URL?; public var cancel: URL?
    public static func mayReceiveNoteDetails(_ url: URL) -> Bool }        // false for http and https
public enum URLCommandError: Error, Equatable, Sendable { case unknownHost(String), invalid(String), tooLarge }
public enum URLCommand: Equatable, Sendable {
    case note(id: UUID, heading: String?)                         // noteit://note/<UUID>[?heading=]
    case noteTitle(title: String, heading: String?)               // noteit://note?title=[&heading=]
    case new(title: String?, text: String, notebook: String?, tags: [String], open: Bool)
    case shareInbox(UUID)                                         // noteit://new?inbox=<UUID>
    case append(target: AppendTarget, text: String, position: AppendPosition, timestamp: Bool)
    case open(OpenTarget), search(String), daily, settings(tab: String)
    case registered(host: String, url: URL)                       // any non-reserved host; dispatched through URLRouteRegistry
    public enum AppendTarget: Equatable, Sendable { case id(UUID), title(String), daily }
    public enum OpenTarget: Equatable, Sendable { case id(UUID), title(String) }
    public static let reservedHosts: Set<String> = ["new", "append", "open", "note", "search", "daily", "settings", "x-callback-url"]
    public static let settingsTabs: [String] = ["general", "shortcuts", "editor", "sync", "data", "sharing", "smart", "integrations", "plugins", "about"]
    public static let maxTextBytes = 100_000
    public var changesNotes: Bool                                 // true for new and append (id, title, daily); false for shareInbox and links that only open or show
    /// Returns the command and its callbacks (callback URLs with javascript/file/data/noteit schemes are dropped). Note links use NoteLink(url:).
    public static func parse(_ url: URL) -> Result<(URLCommand, XCallback), URLCommandError>
    public static func callbackURL(_ base: URL, adding items: [URLQueryItem]) -> URL
}

// App target: Automation/URLScheme/URLRouteRegistry.swift (built in foundations 5.4): a @MainActor class. register(host:handler:) for non-reserved hosts
// traps on a reserved host, a duplicate, or characters outside [a-z0-9-]; canRegister(host:) mirrors the checks. The handler gets the whole URL, fragment included.

// NoteItCore/ShareInboxItem.swift (also compiled into the appex)
public struct ShareInboxItem: Codable, Equatable, Sendable {
    public var version: Int                                       // 1
    public var id: UUID; public var createdAt: Date; public var title: String?; public var text: String?
    public var url: URL?; public var urlTitle: String?; public var images: [String]          // file names next to item.json
    public static let folderName = "share-inbox"; public static let maxImages = 10; public static let maxImageBytes = 26_214_400
}

// App target: Automation/Spotlight/SpotlightItemBuilder.swift
enum SpotlightItemBuilder {
    static let domainNone = "none"; static let textLimit = 20_000; static let indexVersion = 1
    static func shouldIndex(_ meta: NoteMeta) -> Bool                // false for Recently Deleted and NoteMeta.isLocked
    static func item(for meta: NoteMeta, notebookName: String?, text: String?) -> CSSearchableItem
}
// App target: Automation/Spotlight/SpotlightIndexer.swift
@MainActor final class SpotlightIndexer: DerivedIndex {              // organise's registry: noteChanged, noteRemoved, metadataChanged, rebuild, flush
    init(store: NoteStore, defaults: UserDefaults = .standard)       // no LibraryChangeFeed: metadata-only changes arrive through metadataChanged
}

// App target: Automation/LocalAPI/CLIInstaller.swift
enum CLIInstallState: Equatable { case notInstalled, installed(URL), pointsElsewhere(URL), bundledToolMissing }
struct CLIInstaller {
    var linkURL = URL(fileURLWithPath: "/usr/local/bin/noteit")
    var bundledTool: URL?                          // Bundle.main.bundleURL/Contents/Helpers/noteit
    var fileManager: FileManager = .default
    var runPrivileged: (String) throws -> Void     // NSAppleScript "do shell script … with administrator privileges"
    func state() -> CLIInstallState
    func install() throws
    func uninstall() throws
}

// CLI: Sources/NoteItCLI/main.swift (built in foundations 5.1)
enum CLIExit: Int32 { case ok = 0, error = 1, usage = 2, unreachable = 3, unauthorized = 4, notFound = 5, conflict = 6 }
// CLI: Sources/NoteItCLI/CLIArguments.swift
struct CLIInvocation: Equatable { var command: String; var positionals: [String]; var options: [String: [String]]; var flags: Set<String> }
enum CLIArguments { static func parse(_ argv: [String]) -> Result<CLIInvocation, CLIUsageError> }
```

---

## Milestones and tasks

Dependency graph:
- Before anything: foundations (program design §2), including step 5 (formerly T1, T5 and T17 here), `NoteStore.editBody`, the `DerivedIndex` registry, `NoteMeta.isLocked`, the daily-note seams with the `DailyNotes.isAvailable` gate (step 4) and the frozen tables.
- M1: T3 → T2; T4 in parallel with both. T2's Markdown paths need `markdown-storage` Tasks 2.1–2.3 (`MarkdownCodec`).
- M2 (links) needs T2 and foundations 5.3 (`NoteLink`, `URLCommand`) and 5.4 (`URLRouteRegistry`): T6.
- M3 (Local API) needs T2, T4: {T7, T8, T9} in parallel → T10 → T11 → T12 → T13. T14 any time after T7.
- M4 (CLI) needs M3: T15 → T16 → T23.
- M5 (Spotlight) needs T4 only: T18. Can run in parallel with M2–M4.
- M6 (Shortcuts) needs T2: T19 (spike) → T20. Can run in parallel with M3–M5.
- M7 (daily notes) needs only the foundations daily-note seams (`NoteStore.dailyNote(for:createIfMissing:)`, `DailyLogAppender`, step 4): T21. Everything it adds stays behind `DailyNotes.isAvailable` and becomes visible when `linking` sets the gate to true; it doesn't wait for linking.
- M8 (Share extension) needs T2 and T6: T24 → T25. Can run in parallel with M3–M7.
- T22 (docs) closes each milestone for its own section; the final pass runs last.

Each milestone ships on its own: M1 has no user-visible change; M2 adds links and Copy Note Link; M3 adds the Local API; M4 the CLI; M5 Spotlight; M6 Shortcuts; M7 daily-note routes (visible once linking flips the gate); M8 Share → NoteIt.

### M1 — Foundations

#### Task 1: Package targets and wire types — Moved to foundations (tasks 5.1, 5.2, 5.4)

Summary: foundations step 5 creates the `NoteItAPI` target (macOS; depends on `NoteItCore`, `NoteItSync`) and the `NoteItAPITests` target, the `NoteItCLI` executable stub (`noteit <version>` and the frozen `CLIExit` enum in `main.swift`), the three `AppIdentity` constants, the v1 wire types and `APIRoutes` from this plan's Frozen interfaces (with the public `RouteSpec.init(id:method:pattern:scope:body:bucket:maxBodyBytes:summary:)`; including the program's additions: `capabilities`, `locked`, `score`/`highlights` as `{field, ranges}`, `parentID`/`path`, `TagNodeDTO`, `DailyAppendRequest.format`, the new `APIErrorCode` cases, no `ClientKind.plugin`), `HTTPMessage` (5.1); `RouteMatch`, `OriginDecision`, `LocalAPIContext`, `ClientRecord` and `LocalAPIRouteRegistry` with its trap checks in `Sources/NoteItAPI/Server/` (5.2); and `URLRouteRegistry` with the reserved hosts (5.4), with their tests. This plan starts from there.

#### Task 2: AutomationService over editBody and NoteItMarkdown
Needs T3, foundations, and `markdown-storage` Tasks 2.1–2.3.
**Files:**
- Create: `Sources/NoteIt/Automation/AutomationService.swift`, `AutomationService+Body.swift`, `StagedUploads.swift`; `Tests/NoteItTests/AutomationServiceTests.swift`.
- Modify: `Sources/NoteIt/Model/NoteStore.swift` (`isLoading` becomes `private(set)`, the one store edit), `Sources/NoteIt/App/AppDelegate.swift` (staged purge at launch, removal at quit).

Steps:
- [ ] `AutomationService+Body.swift`, with no converter of its own:
  - markdown in: `MarkdownCodec.parse` → `MarkdownCodec.resolvingAttachments` → `DocConverter.importDocument`. `AttachmentRef`s with `noteit-attachment:<id>` resolve to staged files, and `noteit-attachment:<noteID>/<name>` to that note's own current attachments when the text replaces or extends that same unlocked note (so a Markdown read and written back keeps its images); any other path is dropped (no file system access from API input). Plain and Markdown text over 1,000,000 UTF-8 bytes → `.tooLarge`. html in → `.formatUnavailable`.
  - text in: the body run of `NoteStore.capturedText(title: "", body:)`.
  - markdown out: `DocConverter.export` → `MarkdownCodec.serialize(profile: .portable, attachmentPath:)` with images written as `noteit-attachment:<noteID>/<name>`.
  - `noteit-doc` in and out: `DocConverter`. html out: `HTMLWriter`. text out: `plainText(for:)`.
  - `edit(_:actionName:versioning:_:)`: refuse `deletedAt != nil` (`.noteDeleted`), `isBodyWriteBlocked` (`.noteUnreadable`), `isLocked` (`.noteLocked`); then `store.editBody(id, actionName:, versioning:)`, passing `versioning` straight through, and map `BodyEditError` to `AutomationError` (`versionNotSaved` → `.versionNotSaved`, sent as `internal` 500 with the message "Couldn't save a version of the note, so it wasn't changed."; nothing was written). Automation never records a Version History entry itself before calling `editBody`; with `.recordCurrent`, `editBody` records the current body exactly once (closed note or open editor). Any restore of an earlier body also goes through `editBody` (`restoreVersion` does). No direct `handOverPendingEdits`/`updateBody` calls.
- [ ] Replace, append (end, or after the first paragraph's newline for `.start`), set title (first paragraph's characters, keeping the attributes of its first character) and add attachment (`"\n"` + an `NSTextAttachment` with a sanitized `preferredFilename`: strip `/`, `:`, control characters; max 120 characters; de-duplicate with ` 2`, ` 3`) are closures passed to `edit`. Replace passes `versioning: .recordCurrent`; the others pass `.none` and rely on the editor's undo and Version History's normal snapshots. Append timestamps are 24-hour `HH:mm`, `en_US_POSIX`, using the injected clock.
- [ ] `StagedUploads`: files in `<DiscoveryFile.directory>/staged/` named `att_<22 base64url chars>`; max 20 files, 100 MB total, 1 h lifetime; `purgeExpired(now:)` on every stage call and at launch; `removeAll()` at quit.
- [ ] `AutomationService`: implement every frozen method over `NoteStore`. While `NoteStore` is loading (`NoteStore.isLoading`, made `private(set)` for this), every call throws `.notReady`. `create` resolves the notebook (`.id` must exist; `.name` case-insensitive, first in `sortedNotebooks` order; missing → `.notebookNotFound`; nil → `defaultNotebookIDForNewNotes`), appends tags as a final line `#a #b` (lowercased, `#` stripped from input), and applies `pinned` with `togglePin`. `note`/`list`/`search` return locked notes with an empty preview, and `search` matches their title only; `body` on a locked note throws `.noteLocked`. `list` uses `notes(for:search:)` with `.allNotes`, `.notebook`, `.tag` or `.recentlyDeleted`; results are ordered pinned first (`.list` only), then `updatedAt` descending, then UUID, so pages are stable; the cursor is base64url of `"<updatedAt ms>|<UUID>"` for the last returned item. `search` snippet: fold the query with `NoteStore.fold`, find the first term in `plainText(for:)` (case- and diacritic-insensitive, so positions stay in the original text), cut 60 characters before and 100 after on word boundaries, add `…` at cut ends. `patch` with `ifRevision` compares to `meta.revision` (call `assignMissingRevisions()` once at service init). `daily` and `appendToDaily` throw `.dailyNotesUnavailable` until T21, which wires them behind the injected `dailyNotesAvailable` gate. `link(for:)` builds `noteit://note/<UUID>` with `NoteLink`.
- [ ] Tests (`AutomationServiceTests`, scratch store): `testCreateUsesDefaultNotebookAndBoldTitle`, `testCreateByNotebookNameIsCaseInsensitive`, `testCreateUnknownNotebookThrows`, `testCreateAppendsTagsLineAndParsesTags`, `testAppendEndAndStart`, `testAppendTimestampIs24HourPOSIX` (injected clock at 21:05 with a 12-hour user locale → `21:05`), `testReplaceRecordsVersionHistory` (exactly one new version, for a closed note and for a note open in an editor), `testAppendRecordsNoVersion`, `testEditsGoThroughEditBody` (open editor registered; undo restores the text), `testPatchRevisionMismatch`, `testWritesToRecentlyDeletedNoteThrow`, `testLockedNoteBodyThrowsAndPreviewIsEmpty`, `testNotReadyWhileLoading`, `testSetTitleKeepsAttributes`, `testDeletePermanentlyOnlyFromRecentlyDeleted`, `testListPaginationIsStable` (120 notes, pages of 50, no duplicates or gaps), `testListUpdatedSince`, `testSearchSnippetAroundMatch`, `testTagsWithCounts`, `testDailyBeforeLinkingThrowsUnavailable`, `testTextLimitIsEnforced` (1 MB + 1 → `.tooLarge`), `testMarkdownRoundTripThroughNoteItMarkdown`, `testStagedImageResolves`, `testUnknownImagePathIsNotRead`, `testLinkIsNoteForm`. (`AutomationClients` and `testClientsIssueListRevoke` move to T12: `ClientRegistry` arrives with T9. `createFromShare` comes with T24's `ShareInboxItem`.)
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AutomationServiceTests` → `Executed <n> tests, with 0 failures`; `swift build 2>&1 | tail -3` → `Build complete!`.
- [ ] Commit `feat(automation): add AutomationService over NoteStore`.

#### Task 3: AutomationError and user messages
Runs before T2 (T2 throws these errors).
**Files:** `Sources/NoteIt/Automation/AutomationError.swift`, `Tests/NoteItTests/AutomationErrorTests.swift`.
- [ ] `apiCode`: notFound and notebookNotFound → `.notFound`; noteDeleted → `.noteDeleted`; noteUnreadable → `.noteUnreadable`; noteLocked → `.noteLocked` (423); notReady → `.notReady` (503); invalidInput → `.badRequest`; revisionMismatch → `.revisionMismatch` (412); formatUnavailable and dailyNotesUnavailable → `.notImplemented` (501); tooLarge → `.tooLarge`; cancelled → `.badRequest` (never sent by the API; links call `x-cancel` instead).
- [ ] Add `var callbackCode: String`: the `apiCode` raw value, except `cancelled` for `.cancelled`.
- [ ] `message`, exactly: "No note with that id.", "That note is in Recently Deleted.", "That note couldn't be read, so it can't be changed.", "That note is locked.", "NoteIt is still opening your notes. Try again in a moment.", "No notebook with that name.", "Daily notes aren't available in this version.", "That's too large.", "That note was changed since you read it.", "That format isn't available in this version.", "Cancelled.", and the `invalidInput` text as given.
- [ ] Test `testEveryErrorHasCodeAndMessage`, `testLockedAndNotReadyStatuses`, `testUnavailableFeaturesAreNotImplemented`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AutomationErrorTests` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(automation): add automation errors`.

#### Task 4: LibraryChangeFeed
**Files:** `Sources/NoteIt/Automation/LibraryChangeFeed.swift`, `Tests/NoteItTests/LibraryDiffTests.swift`.
- [ ] `LibraryDiff.changes`: new id → created; missing id → purged (note) / deleted (notebook); `deletedAt` nil → set → deleted; set → nil → restored; any other field difference → updated. Output sorted notebooks first, then notes, by id, for deterministic tests.
- [ ] `LibraryChangeFeed` keeps the last snapshot, subscribes to `store.$notes` and `store.$notebooks` via Combine, debounces on the main run loop, diffs, and calls subscribers with non-empty batches.
- [ ] Tests: `testCreatedUpdatedPurged`, `testDeleteAndRestore`, `testPinOnlyIsUpdated`, `testNotebookRenameIsUpdated`, `testNoChangeNoOutput`, `testFeedCoalescesBurst` (scratch store, 10 edits within 50 ms → one batch, using `XCTestExpectation`).
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LibraryDiffTests` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(automation): add library change feed`.

### M2 — Links

#### Task 5: URLCommand parser — Moved to foundations (task 5.3)

Foundations 5.3 builds `URLCommand` (with `AppendPosition`) and `URLCommandTests` in `NoteItCore` from the rules and cases below; T6 consumes it. This plan keeps them as the reference and owns the shape.
- Parse host as the action (`note`, `new`, `append`, `open`, `search`, `daily`, `settings`), or host `x-callback-url` with the action as the first path component. Host `note` goes through `NoteLink(url:)` and becomes `.note(id:heading:)` or `.noteTitle(title:heading:)`. `new?inbox=<UUID>` becomes `.shareInbox`. Any other host becomes `.registered(host:url:)` with the whole URL, fragment included. Booleans accept `1`, `true`, `yes`. `tags` splits on commas. `text` over `maxTextBytes` → `.tooLarge`. `settings?tab=` accepts every value in `settingsTabs`. Callback URLs with schemes `javascript`, `file`, `data`, `noteit` are dropped. `changesNotes` is true for `new` and `append` (daily append included) and false for everything else, `shareInbox` included (the share-inbox link is exempt from confirmation). Foundation only, no AppKit (checked by `ImportHygieneTests`).
- Tests: `testNoteById`, `testNoteByIdWithHeading`, `testNoteByTitle`, `testOpenIdStaysAnAction`, `testNewAllParameters`, `testShareInbox`, `testAppendById`, `testAppendByTitle`, `testAppendDaily`, `testChangesNotesForNewAndAppendOnly`, `testOpenByIdAndTitle`, `testSearch`, `testSettingsTabAcceptsEveryFrozenRawValue`, `testRegisteredHostKeepsFragment`, `testXCallbackForm`, `testDangerousCallbacksDropped`, `testHTTPCallbacksMayNotReceiveNoteDetails`, `testOversizedTextRejected`, `testPercentEncodedPlusAndUnicode`, `testCallbackURLAppendsItemsKeepingExistingQuery`.

#### Task 6: URL handler, Info.plist, Copy Note Link, palette
**Files:**
- Create: `Sources/NoteIt/Automation/URLScheme/URLSchemeHandler.swift`, `URLScheme/CopyNoteLink.swift`, `Tests/NoteItTests/URLSchemeHandlerTests.swift`.
- Modify: `Sources/NoteIt/App/AppDelegate.swift`, `scripts/build_app.sh`, `Sources/NoteIt/App/MenuShortcuts.swift`, `Sources/NoteIt/App/PlannedMenuShortcuts.swift`, `Sources/NoteIt/App/ExportCommands.swift`, `Sources/NoteIt/Palette/PaletteCommandRegistry.swift`, `Sources/NoteIt/Settings/Preferences.swift`, `Sources/NoteIt/Settings/SettingsView.swift` (fill in the `integrations` case added by the frozen Settings table: position 8, symbol `point.3.connected.trianglepath.dotted`; set its `isAvailable` to true), `docs/keyboard-shortcuts.md`, `CHANGELOG.md`, `Sources/NoteIt/Automation/AutomationService.swift` (`findByTitle` picks the most recently edited match), `Tests/NoteItTests/MenuShortcutStoreTests.swift`, `Tests/NoteItTests/MenuShortcutDefaultsTests.swift` (the new case and 21 planned rows), `Tests/NoteItTests/SettingsTabTests.swift` (integrations is available), `Tests/NoteItTests/PaletteCommandRegistryTests.swift`. `MenuShortcutRules` needs no change: its conflict check reads every `MenuShortcutCommand` from the store, and ⌃⌘L isn't reserved.
- Create: `Sources/NoteIt/Settings/IntegrationsSettingsView.swift` with only the Links section for now (T13, T18, T23 and T25 add the other sections).

Steps:
- [ ] In `applicationWillFinishLaunching`, register `NSAppleEventManager.shared().setEventHandler(_:andSelector:forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))` pointing at `URLSchemeHandler`. Register default `urlSchemeChangesWithoutAsking: false`.
- [ ] `URLSchemeHandler.handle(_ url:)` parses with `URLCommand.parse` and runs the command through `AutomationService`. Its UI (`confirm`, `notify`, callback opening, showing a note, the saved notice, search, settings) and the daily gate are an injected `Environment`; tests pass their own.
  - `note`, `noteTitle`, `open`: `WindowRouter.showMainWindow()` + `store.reveal(id)` (a note in Recently Deleted selects Recently Deleted instead). With a heading, the caret goes to the first title, heading or subheading paragraph with that text (case-insensitive): directly in an open editor, else through `RichTextEditor.pendingCaret`; a locked note ignores the heading. `linking`'s `NoteStore.followLink` replaces this when it lands. Unknown title → `store.searchText = title`, `WindowRouter.focusSearch()` for both `open` and `noteTitle`; `noteTitle` switches to `linking`'s missing-target rules (`createNoteForLink`) when linking builds them.
  - Commands with `changesNotes` (`new`, `append`, daily append included; never `shareInbox`): `append` first resolves its target and refuses a note that is deleted, locked or unreadable without asking. Then, unless `urlSchemeChangesWithoutAsking` is on, show an alert with **Allow** and **Don't Allow**: **A link wants to create a note in “<notebook>”.** for `new`, **A link wants to add text to “<title>”.** for `append`. **Don't Allow** calls `x-cancel`.
  - `new`: after Allow, without `open`, show `CaptureToast` with **Saved to <notebook>** (reuse the capture notice API in `Sources/NoteIt/Capture/CaptureToast.swift`). With `open=1`, show and reveal.
  - `shareInbox`: never asks (the user pressed **Save** in the Share sheet, and it imports only app-group items); handled in T24. Until then it shows **NoteIt doesn't know this link.**
  - `append` with target `daily` and `daily`: while `DailyNotes.isAvailable` is false, show **Daily notes aren't available in this version.** and call `x-error` with `not_implemented`. T21 wires the daily calls.
  - `search`: same as unknown title. `settings`: `SettingsTabRouter.show(tab)`; a tab this build doesn't have opens General.
  - `registered(host:url:)`: `URLRouteRegistry` handler for the host; none → notice **NoteIt doesn't know this link.**
  - Callbacks: `NSWorkspace.shared.open(URLCommand.callbackURL(…))`. `x-success` gets `id`, `title` and `url` (`noteit://note/<UUID>`) only when `XCallback.mayReceiveNoteDetails` is true; `http` and `https` callbacks get no added parameters. `x-error` gets `errorCode` always and `errorMessage` only for non-`http(s)` callbacks. With no `x-error`, an error shows its `AutomationError.message` as a notice, so a link never fails silently. A link that doesn't parse (unknown or invalid) shows **NoteIt doesn't know this link.** (`bad_request`; `too_large` for oversized text); its callbacks are read back by parsing only its `x-` parameters.
- [ ] `scripts/build_app.sh`: after `NSServices`, add
  `plutil -replace CFBundleURLTypes -json '[{"CFBundleURLName":"'"$BUNDLE_ID"'","CFBundleURLSchemes":["noteit"]}]' "$PLIST"`.
- [ ] Copy Note Link: `MenuShortcutCommand.copyNoteLink` ("Copy Note Link", default `MenuShortcut("l", [.command, .control])`) and `MenuShortcuts.copyNoteLink`, in `MenuShortcutRules` and `docs/keyboard-shortcuts.md`. Remove the `copyNoteLink` row from `PlannedMenuShortcuts` now that it is a real case. `CopyNoteLink.perform(noteID:)` writes both `.string` (`noteit://note/<UUID>` from `NoteLink`) and `.rtf` (the link with the note title) to the pasteboard; it is the one entry point that `linking`'s context menu and palette entry call. In `ExportCommands`, add `CopyNoteLinkMenuItem` after `CopyAsMarkdownMenuItem` in `CommandGroup(after: .pasteboard)`.
- [ ] Palette: `copyNoteLink` (available with a live note), `integrationsSettings` ("Integrations Settings…", `SettingsTabRouter.show(.integrations)`). The other two commands come in T13 and T23.
- [ ] Tests: `testCopyNoteLinkDefaultShortcutHasNoConflict` (in `MenuShortcutStoreTests`, using the existing conflict rules in `MenuShortcutRules`), `testCopyNoteLinkWritesNoteForm` (in `URLSchemeHandlerTests`, on a private pasteboard), `testHTTPErrorCallbackHasNoMessage`, `testLockedNoteRefusesAppendWithoutAsking`, `testHeadingLocationFindsHeadingParagraphs`, `testPaletteHasCopyNoteLinkOnlyWithNote`, `testAppendAsksUnlessSettingOn` (injected confirmer), `testNewAsksUnlessSettingOn`, `testShareInboxNeverAsks`, `testOpenAndSearchNeverAsk`, `testDontAllowCallsXCancel`, `testDailyHostsUnavailableWhileGateOff` (injected availability), `testHTTPSuccessCallbackHasNoIdOrTitle`, `testRegisteredHostDispatches`, `testUnknownHostShowsNotice`.
- [ ] Manual (needs the app running and clicking; not part of automated verification): `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh`, then `open .selftest/app/NoteIt.app`, then `open 'noteit://new?title=Hi&text=There'` → the confirmation, then after **Allow** the notice **Saved to Inbox**; `open 'noteit://append?title=Hi&text=More'` → the confirmation; `open 'noteit://x-callback-url/new?text=x&x-success=https://example.com/ok'` → after **Allow**, the browser opens `https://example.com/ok` with no added parameters; ⌃⌘L on a note, paste in TextEdit → `noteit://note/<UUID>`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "URLSchemeHandlerTests|MenuShortcutStoreTests|PaletteCommandRegistryTests"` → `Executed <n> tests, with 0 failures`; `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` succeeds (exit 0) and `plutil -p .selftest/app/NoteIt.app/Contents/Info.plist | grep -A3 CFBundleURLSchemes` shows `noteit`.
- [ ] Commit `feat(automation): handle noteit:// links and add Copy Note Link`.

### M3 — Local API

T7, T8 and T9 can run in parallel.

#### Task 7: HTTP parser, response and router
**Files:** `Sources/NoteItAPI/Server/HTTPParser.swift`, `Router.swift`; `Tests/NoteItAPITests/HTTPParserTests.swift`, `RouterTests.swift`. `HTTPMessage.swift` and `RouteMatch` come from foundations (5.1, 5.2).
- [ ] Parser: request line, headers (CRLF; reject bare LF with 400), `Content-Length` (missing on POST/PATCH with body → 411; `Transfer-Encoding: chunked` → 411), percent-decoded path and query, limits per route body kind (the parser takes the larger binary limit; the server re-checks JSON routes against `maxJSONBody`; before reading a body the server runs the head-only pipeline steps — Host, Origin, route, Content-Type, the route's limit against the declared `Content-Length`, rate limit, auth — and answers a refusal at once with `Connection: close`). Pipelined requests return `consumed` so the caller keeps the rest.
- [ ] Check that `HTTPResponse.serialized` (foundations' `HTTPMessage.swift`) writes `HTTP/1.1 <status> <reason>`, `Content-Length`, `Content-Type`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Connection: keep-alive|close`; fix it there if it doesn't.
- [ ] Router: literal segments beat params; `/v1/notes/{id}` must not match `/v1/notes/{id}/append`; wrong method on a known path → 405 (`bad_request` body, `Allow` header).
- [ ] Tests: `testParsesSimpleGet`, `testNeedsMoreForPartialHeaders`, `testNeedsMoreForPartialBody`, `testPipelinedRequests`, `testHeaderLimit`, `testBodyLimit`, `testChunkedRejected`, `testBareLFRejected`, `testQueryDecoding`, `testResponseSerialization`, `testFuzzNeverCrashes` (10,000 random byte buffers and random truncations of valid requests; only asserts no crash and a result), `testRouterParams`, `testRouterLiteralBeatsParam`, `testRouter405`, `testRouter404`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "HTTPParserTests|RouterTests"` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(local-api): add http parser and router`.

#### Task 8: Request policy and rate limiter
**Files:** `Sources/NoteItAPI/Server/RequestPolicy.swift`, `RateLimiter.swift`; tests `RequestPolicyTests.swift`, `RateLimiterTests.swift`.
- [ ] Policy exactly as spec §6.6. `classifyOrigin`: no header → `.native`; `chrome-extension://`, `moz-extension://`, `safari-web-extension://` with a non-empty host → `.extensionOrigin`; else `.rejected` (`null` included). `storedOrigin(for:extensionBundle:)`: `.native` → nil; Chrome and Firefox → the full origin; Safari → `safari-web-extension:<bundle id>` from `X-NoteIt-Extension-Bundle` (reverse-DNS, at most 255 characters), `.badRequest` when it is missing or malformed. `originBindingAllows`: a record whose `origin` starts with `safari-web-extension:` accepts a `safari-web-extension://` origin with any host (Safari changes the host between launches) only when `extensionBundle` equals the stored bundle id; every other bound record needs the exact origin and ignores the header. Add `X-NoteIt-Extension-Bundle` to `Access-Control-Allow-Headers`.
- [ ] Rate limiter: classic token bucket with injectable clock; `Retry-After` rounds up to whole seconds, minimum 1.
- [ ] Tests: `testHostAcceptsLoopbackForms`, `testHostRejectsOthers` (`evil.com:47600`, `127.0.0.1:1`, missing), `testOriginClassification` (table of 10 origins), `testPreflightEchoesOriginAndVary`, `testPreflightRejectedForWebOrigin`, `testJSONRouteNeedsJSONContentType`, `testOriginBinding` (bound token + same origin ok; other origin no; native token + any origin no), `testSafariBindingIsSchemePlusBundleID` (new Safari host with the same bundle id ok; another bundle id or no header no; a `chrome-extension` origin with a Safari token no), `testStoredOriginForSafariNeedsBundle`, `testBucketBurstThenRefill`, `testRetryAfterRoundsUp`, `testBucketsAreIndependentPerClient`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "RequestPolicyTests|RateLimiterTests"` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(local-api): add request policy and rate limits`.

#### Task 9: Client registry, pairing and change hub
**Files:** `Sources/NoteItAPI/Server/ClientRegistry.swift` (modify; `ClientRecord` from foundations 5.2), `PairingBroker.swift`, `ChangeHub.swift`; tests `ClientRegistryTests.swift`, `PairingBrokerTests.swift`, `ChangeHubTests.swift`.
- [ ] Registry: adds `ClientStore`, `InMemoryClientStore` and `ClientRegistry` next to foundations' `ClientRecord`; holds records under an `NSLock`; `authenticate` strips `Bearer `, hashes, compares against every record in constant time (no early return).
- [ ] Pairing: one open pairing; lifetime 120 s; 5 wrong codes → cancelled; extension origin caps scopes at `write`; `clientName` trimmed to 64 characters with control characters removed; `complete` issues the token via the registry with the granted scopes and the origin the server computed with `RequestPolicy.storedOrigin(for:extensionBundle:)` (`safari-web-extension:<bundle id>` for Safari); `start` and `complete` must carry the same origin. The server answers a Safari `pair/start` or `pair/complete` without the bundle header with `400 bad_request` before calling the broker. `kind` accepts `cli`, `extension`, `mcp`, `script` only.
- [ ] ChangeHub: ring buffer of `capacity`; cursor `<bootID>:<seq>`; subscribers per client capped at 4 and 16 total (`.rateLimited`); `closeAll(client:)` used by revoke.
- [ ] Tests: `testIssueAuthenticateRevoke`, `testRevokeAllClearsStore`, `testRegistryPersistsThroughStore`, `testPairingHappyPath`, `testPairingSecondStartConflicts`, `testPairingExpires` (injected clock), `testPairingFiveWrongCodesCancel`, `testPairingDeny`, `testExtensionCannotGetAdmin`, `testSafariPairingStoresBundleID`, `testGrantedScopesNarrowing`, `testPairingNameSanitized`, `testChangesSinceCursor`, `testCursorFromOtherBootExpires`, `testCursorOlderThanBufferExpires`, `testNoSinceReturnsCurrentCursorOnly`, `testSubscriberLimits`, `testCloseAllRemovesClientSubscribers`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ClientRegistryTests|PairingBrokerTests|ChangeHubTests"` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(local-api): add client registry, pairing and change hub`.

#### Task 10: LocalHTTPServer transport
**Files:** `Sources/NoteItAPI/Server/LocalHTTPServer.swift`, `Sources/NoteItAPI/Server/LocalAPIRouteRegistry.swift` (modify; created in foundations), `Tests/NoteItAPITests/LocalHTTPServerTests.swift`, `LocalAPIRouteRegistryTests.swift`.
- [ ] `NWListener(using: .tcp)` with `parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: …)` and `allowLocalEndpointReuse = false`. `start(ports:)` tries each port and returns the first that reaches `.ready`.
- [ ] Per connection: read into a buffer, `HTTPParser.parse`, then the pipeline: Host check (421) → origin classification (403) → preflight → route match → content type → rate limit (unauthenticated bucket by `"anon"`, else by client id) → auth (`401 unauthorized` / `token_revoked` when the hash was revoked during this launch) → origin binding (passing `X-NoteIt-Extension-Bundle`) → scope → built-in routes (`ping`, `openapi`, `pair/*`, `me`, `changes`, `events`, `clients`) → `responder.respond`. Add CORS headers for extension origins.
- [ ] SSE for `events`: headers `Content-Type: text/event-stream`, `Cache-Control: no-store`, no `Content-Length`; send backlog after `Last-Event-ID` or `since`; heartbeat `: ping\n\n` every 15 s; on revoke send `event: revoked\ndata: {}\n\n` and close.
- [ ] Route over `APIRoutes.all` plus `LocalAPIRouteRegistry.shared.routes`; registered routes call their handler instead of `responder`. Enforce `maxBodyBytes` per route after matching (`413`).
- [ ] Registry: the trap checks (`register`, `registerSearchMode`, `addCapability`, `validate()`) and `removeCapability` are already in foundations 5.2. This task wires the registry into the server and adds `extendTags(treeProvider:)` (traps on a second provider; `validate()` reports it), `tagTreeProvider`, `extendNotebooks(with:)` and `notebookExtenders`, stored under the registry's lock. `ping` returns the built-in capabilities plus `registry.capabilities`, read at request time so a removed capability is gone from the next answer, in a field named `capabilities`.
- [ ] Idle timeout 30 s (not for SSE); max 32 connections (extra ones get `503` and close).
- [ ] Wrap each request in `ProcessInfo.processInfo.performActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Local API request")`.
- [ ] Log with `Logger(subsystem: AppIdentity.bundleID, category: "LocalAPI")`: method, route pattern, status, milliseconds.
- [ ] Tests (port 0, `URLSession` with an ephemeral configuration, fake responder): `testPingWithoutToken`, `testUnauthorizedWithoutToken`, `testScopeEnforced`, `testWebOriginRejected`, `testExtensionPreflightAndCORS`, `testHostHeaderRebindingRejected` (raw `NWConnection` with `Host: evil.example`), `testRateLimited429WithRetryAfter`, `testKeepAliveTwoRequestsOneConnection`, `testPairingEndToEnd`, `testEventsStreamDeliversAndRevokes`, `testStopClosesConnections`, `testPortFallbackSkipsBusyPort` (bind a dummy listener first), `testBindsOnlyLoopback` (connecting to the Mac's non-loopback address fails; skip if the Mac has none), `testRegisteredRouteUsesPipelineAndBodyLimit` (the spec is built with the public `RouteSpec.init` from a test target that imports `NoteItAPI` without `@testable`), `testRegisteringConflictingRouteTraps` (checked with `validate()`), `testRouteIdMustBeSlugDotName`, `testRegisteredSearchModeAndCapability`, `testPingHasCapabilitiesNotFeatures`, `testSafariWithoutBundleHeaderIs400OnPairing`; in `LocalAPIRouteRegistryTests`: `testSecondTagTreeProviderIsReported`, `testNotebookExtendersKeepOrder`.
- Note (T10 as built): `init` also takes `routeRegistry:` (default `.shared`), because `LocalAPIRouteRegistryTests.testSharedStartsEmpty` forbids tests from registering into `.shared`. The parser's body cap is raised to the largest registered `maxBodyBytes` (at most 60 MB) and each route's limit is re-checked after matching. Handlers are awaited asynchronously, so the activity uses `beginActivity`/`endActivity` around the request rather than the synchronous `performActivity`. Extra connections get `503` with a `rate_limited` body and `Retry-After: 1`. `onAuthenticated` and `lastUsed` hooks are there for T12's `lastUsedAt`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "LocalHTTPServerTests|LocalAPIRouteRegistryTests"` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(local-api): add loopback http server`.

#### Task 11: App handlers
**Files:** `Sources/NoteIt/Automation/LocalAPI/LocalAPIHandlers.swift`, `Tests/NoteItTests/LocalAPIHandlersTests.swift`.
- [ ] `LocalAPIHandlers: LocalAPIResponder` switches on `RouteID`, decodes bodies with `APIJSON`, hops to `@MainActor` to call `AutomationService`, and maps results to DTOs (`NoteSummaryDTO.url = AutomationService.link(for:)`, the `noteit://note/<UUID>` form; `locked` from `NoteMeta.isLocked`, with an empty preview). Body reads and writes of a locked note return `423 note_locked`; a library still loading returns `503 not_ready`. `GET /v1/search`: `mode` absent or `keyword` runs keyword search; another mode calls `LocalAPIRouteRegistry.searchMode(_:)`; unknown → `400 bad_request`; the handler's `not_available` (mode turned off) → `501 not_available`. `score` and `highlights` (`{field, ranges}`) are filled once `organise`'s ranker is present, else left out. `GET /v1/tags?tree=1` returns `LocalAPIRouteRegistry.shared.tagTreeProvider` on the main actor, or `501 not_implemented` when no provider is registered. Each `NotebookDTO` is passed through every `notebookExtenders` entry before it is sent (organise fills `parentID` and `path`). `GET /v1/daily` reads `format` (`plain`, `markdown`); daily routes return `501 not_implemented` until T21, and after it while `DailyNotes.isAvailable` is false. `PATCH` reads `If-Match` (quotes stripped). `DELETE ?permanent=true` requires `admin` (check `context.client.scopes`). Uploads read `X-NoteIt-Filename` (default `attachment`) and `Content-Type`.
- [ ] Tests call `respond` directly with a scratch store and fake contexts (no sockets): one test per `RouteID` handled here (`testNotesList`, `testNoteCreate201`, `testNoteGetFormats`, `testNotePatchIfMatch412IncludesCurrent`, `testNoteDeleteAndRestore`, `testPermanentDeleteNeedsAdmin`, `testAppend`, `testAppendIfRevision412`, `testNoteOpen204`, `testListSortUpdated`, `testNotebooksIncludeDefault`, `testUnknownSearchModeIs400`, `testRegisteredSearchModeOffIs501`, `testLockedNoteBodyIs423`, `testLockedNoteListedWithLockedTrue`, `testNotReadyIs503`, `testUrlIsNoteForm`, `testTagsTreeWithoutProviderIs501`, `testTagsTreeUsesProvider`, `testNotebookExtenderFillsParentAndPath`, `testHighlightsShape`, `testAttachmentsAddListGet`, `testStagedUploadInMarkdown`, `testTrashEmptyNeedsAdmin`, `testSearch`, `testNotebooksCRUD`, `testTags`, `testDailyNotImplementedWhileGateOff`), plus `testUnknownIdIs404`, `testMalformedJSONIs400`.
- Note (T11 as built): `LocalAPIHandlers` takes the route registry (default `.shared`) and an `openNote` closure, so tests use their own registry and never bring a window forward. The `412` body is the usual error plus `current`, the note's `NoteSummary` (it carries the current `revision` and works for locked notes). A pin, move or restore of a locked note answers with its `NoteSummary`, since its body can't be read. `PATCH` with a `body` and no `format` reads Markdown; `append` defaults to `timestamp: false`. `AutomationService.defaultNotebookID` is internal so `GET /v1/notebooks` reports the New Notes notebook.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LocalAPIHandlersTests` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(local-api): add note, notebook, tag and attachment handlers`.

#### Task 12: LocalAPIController, Keychain client store, pairing window
**Files:**
- Create: `Sources/NoteIt/Automation/LocalAPI/LocalAPIController.swift`, `KeychainClientStore.swift`, `PairingWindow.swift`; `Sources/NoteIt/Automation/AutomationClients.swift`.
- Modify: `Sources/NoteIt/Sync/Keychain.swift` (`SecItemStore.write(_:service:account:label:)` with default `"NoteIt Sync"`; existing callers unchanged), `Sources/NoteIt/App/AppDelegate.swift`, `Sources/NoteIt/Settings/Preferences.swift`.
- Test: `Tests/NoteItTests/LocalAPIHandlersTests.swift` (controller cases).

Steps:
- [ ] Create `Sources/NoteIt/Automation/AutomationClients.swift`: `AutomationClients` wraps `ClientRegistry` (`issue`, `list`, `revoke`) for in-process callers, and `AutomationService.clients` uses the controller's `ClientRegistry`, so revoking in-process closes event streams the same way as `DELETE /v1/clients/{id}`. Test `testClientsIssueListRevoke` in `AutomationServiceTests`.
- [ ] `KeychainClientStore` reads/writes JSON `[ClientRecord]` at service `AppIdentity.localAPIKeychainService`, account `clients`, label "NoteIt Local API", through an injected `SecretStore`.
- [ ] `LocalAPIController` (`@MainActor`, `ObservableObject`, `static let shared`): `@Published status` (`.off`, `.on(port)`, `.portInUse(UInt16)`, `.failed(String)`); observes `localAPIEnabled` and `localAPIPort`; ports `[pinned]` or `47600...47609`; writes the discovery file at launch and on every status change, removes it in `applicationWillTerminate`; wires `LibraryChangeFeed` → `ChangeHub.publish`; awaits `AutomationService.assignMissingRevisionsForLocalAPI()` each time the server starts, before it serves requests (it has no caller until then, so notes from before sync may list with `revision: nil`); `lastUsedAt` debounced into `localAPIClientLastUsed`; `PairingBroker.onEvent` → `PairingWindow`.
- [ ] `PairingWindow`: an `NSPanel` (not the main window) that activates NoteIt, shows the client name, kind, origin for extensions (for Safari, the scheme and the bundle id), the code as `482 913` in a large monospaced font, the scopes as plain sentences ("read your notes", "change your notes", "manage connected apps"), **Deny**, and a disclosure with scope checkboxes. Closes on finish/cancel; shows **Paired with “<name>”** for 3 s, or **Pairing cancelled after too many wrong codes**.
- [ ] `AppDelegate.applicationDidFinishLaunching`: `_ = LocalAPIController.shared`. Debug builds only: `NOTEIT_LOCAL_API_DEBUG=1` together with `NOTEIT_DATA_DIR` turns the API on and prints one all-scope token to stderr (documented in `docs/development.md`).
- [ ] Tests: `testControllerWritesDiscoveryWhenOff`, `testControllerStartsAndStopsOnPrefChange`, `testPinnedPortInUseReportsStatus`, `testChangesFlowFromStoreToHub`, `testKeychainClientStoreRoundTrip` (in-memory `SecretStore`).
- [ ] Manual: run with `NOTEIT_DATA_DIR=.selftest/api NOTEIT_LOCAL_API_DEBUG=1 swift run NoteIt`, then `curl -s 127.0.0.1:47600/v1/ping`, `curl -s -H "Authorization: Bearer $T" 127.0.0.1:47600/v1/notes | head`, `curl -i -H "Origin: https://example.com" 127.0.0.1:47600/v1/ping` → 403.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LocalAPIHandlersTests` → `Executed <n> tests, with 0 failures`; `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` succeeds (exit 0).
- Note (T12 as built): `SecretStore` (NoteItSync) keeps its 3-argument `write`; the label overload lives on a new app-target protocol `LabeledSecretStore: SecretStore`, which `SecItemStore` adopts (the 3-argument path writes "NoteIt Sync") and `KeychainClientStore` takes. `KeychainClientStore` uses plain `JSONEncoder` so `createdAt` keeps full precision. `LocalAPIController` takes its service, defaults, client store, discovery folder, automatic ports and route registry, so tests run it on port 0 with an in-memory store; `settle()` waits for a pending start or stop. `AutomationService.clients` is a `lazy var` that defaults to the shared controller's `clients`; `AutomationClients` also has `revokeAll()` for Settings. Turning the API off denies an open pairing. The debug path keeps clients in an `InMemoryClientStore`.
- [ ] Commit `feat(local-api): run the local api from the app with pairing`.

#### Task 13: Settings › Integrations
**Files:** `Sources/NoteIt/Settings/IntegrationsSettingsView.swift`, `Sources/NoteIt/Settings/SettingsView.swift`, `Sources/NoteIt/Palette/PaletteCommandRegistry.swift`, `Tests/NoteItTests/PaletteCommandRegistryTests.swift`.
- [ ] Add the Local API and Connected apps sections above Links, with the wording from spec §8. Connected apps lists `AutomationService.clients.list()` (CLI, MCP clients, the web clipper, scripts) and revokes through it. **New Token…** opens a sheet that asks for a name and scopes, then shows the token once with **Copy** and "You won't see this token again." The Command line tool, Spotlight and Share sections come with T23, T18 and T25.
- [ ] Palette: **Turn Local API On** / **Turn Local API Off**.
- [ ] Test: `testLocalAPIToggleCommandFollowsSetting` in `PaletteCommandRegistryTests` (only the command that matches the current `localAPIEnabled` value is listed).
- [ ] Manual: `swift run NoteIt --debug-open-settings --debug-settings-tab integrations` with `NOTEIT_DATA_DIR`; pair with `curl` (start, read the code from the window, complete); the client appears; **Revoke** makes the next `curl` return `401 token_revoked`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaletteCommandRegistryTests` → `Executed <n> tests, with 0 failures`; `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` succeeds (exit 0).
- [ ] Commit `feat(local-api): add Integrations settings`.

#### Task 14: OpenAPI document
Can run any time after T7.
**Files:** `Sources/NoteItAPI/Server/OpenAPIDocument.swift`, `Tests/NoteItAPITests/OpenAPIDocumentTests.swift`.
- [ ] Build an OpenAPI 3.1 JSON from `APIRoutes.all` and `LocalAPIRouteRegistry.shared.routes` plus hand-written schemas for each DTO; bearer security scheme; per-route `x-noteit-scope` and `x-noteit-route-id`; the `mode` enum of `/v1/search` lists `keyword` and every registered search mode.
- [ ] Tests: `testEveryRouteIsDocumented`, `testRegisteredRoutesAndModesAreDocumented`, `testDocumentIsValidJSONWithVersion`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OpenAPIDocumentTests` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(local-api): serve openapi document`.

### M4 — Command line tool

#### Task 15: Client and locator
**Files:** `Sources/NoteItAPI/Client/NoteItAPIClient.swift`, `AppLocator.swift`; tests `NoteItAPIClientTests.swift`, `AppLocatorTests.swift`.
- [ ] `NoteItAPIClient` decodes `APIErrorBody` into `NoteItAPIError`; `events` parses SSE lines (`id:`, `event:`, `data:`), reconnects once with `Last-Event-ID`, ends on `revoked`.
- [ ] `AppLocator.locate`: `NOTEIT_API_URL` → `.ready`; discovery with `apiEnabled` and a successful ping → `.ready`; `apiEnabled == false` → `.apiDisabled`; otherwise, if `launch`, call `launchApp` once and poll every 200 ms until timeout.
- [ ] Tests: `testClientMapsErrors` (against a `LocalHTTPServer` on port 0 with a fake responder), `testEventsStreamParsing`, `testLocatorEnvOverride`, `testLocatorReady`, `testLocatorApiDisabled`, `testLocatorLaunchesOnceAndWaits`, `testLocatorTimesOut` (fake sleep, no real waiting).
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "NoteItAPIClientTests|AppLocatorTests"` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(cli): add api client and app locator`.

#### Task 16: `noteit` commands
**Files:** `Sources/NoteItCLI/main.swift` (modify: replaces the foundations stub body; `CLIExit` stays there), `CLIArguments.swift`, `CLICommands.swift`, `CLIOutput.swift`, `CLIKeychain.swift`, `CLIEditor.swift`; `Tests/NoteItCLITests/CLIArgumentsTests.swift`, `CLIOutputTests.swift`.
- [ ] Parser: `--name value`, `--name=value`, repeated options, `--` ends options, `-` as a positional, unknown option → usage error naming it. `help` prints per-command usage from one table.
- [ ] Commands exactly as spec §7. Stdin is read when the text argument is `-` or absent and `isatty(STDIN_FILENO) == 0`. `auth login` prompts "Enter the code shown in NoteIt:" (reads a line, strips spaces), client name `noteit CLI on <Host.current().localizedName ?? "this Mac">`. `edit` writes to a temp file in `FileManager.default.temporaryDirectory` with mode 0600, runs the editor via `Process` with the terminal attached, and on `412` creates "<title> (edited in terminal)".
- [ ] Token storage: `CLIKeychain` over `SecItemStore`-equivalent code in the CLI (the app's `SecItemStore` lives in the app target; copy the three Security calls into `CLIKeychain`, service `AppIdentity.cliKeychainService`, account = profile name from `--profile` or `NOTEIT_PROFILE`, default `default`). Profile names must match `[a-z0-9-]{1,32}`; names matching `mcp(-[a-z0-9]+)*` are left to `noteit mcp` (`private-ai`) and refused by `--profile` and `NOTEIT_PROFILE`.
- [ ] No `mcp` subtree in wave 1: `noteit mcp …` prints "noteit mcp isn't in this version of NoteIt." to stderr and exits 2 (`CLIExit.usage`). `private-ai` replaces this in wave 2 when it adds the `NoteItMCP` dependency. `noteit today` and `noteit append --today` print "Daily notes aren't available in this version." and exit 1 when the API returns `501 not_implemented`.
- [ ] Exit codes per spec. Errors go to stderr as `noteit: <message>`.
- [ ] `--version` (and `noteit version`, if the command table lists it) keeps foundations' implementation: it prints `noteit <CLIVersion.current(executableURL:)>`, where `CLIVersion` is the frozen type in `NoteItAPI/CLIVersion.swift` (foundations 5.1). That is the only code that works out the CLI's version. This task adds no version constant, no `Info.plist` reading and no second lookup in `NoteItCLI`, and `AppIdentity` still has no version. The command handler takes `executableURL: URL? = Bundle.main.executableURL` and passes it straight to `CLIVersion.current(executableURL:)`, so tests can point it at a fake path.
- [ ] Tests: `testParseOptionsAndPositionals`, `testRepeatedTags`, `testDoubleDash`, `testUnknownOption`, `testProfileFromFlagAndEnv`, `testProfileNameRules` (including `mcp-claude-desktop` refused), `testMcpCommandExits2InWave1`, `testHelpForEveryCommand`, `testListHumanOutput`, `testJSONOutputPassesThrough`, `testExitCodeMapping` (each `APIErrorCode` → `CLIExit`), `testVersionUnbundledPrintsDev` (an executable outside any app, and `executableURL: nil`, print `noteit dev`), `testVersionInsideSyntheticApp` (an executable at `Fake.app/Contents/Helpers/noteit` in the test's own temporary directory, with `CFBundleShortVersionString` `1.2.3` in `Fake.app/Contents/Info.plist`, prints `noteit 1.2.3`).
- [ ] Manual (app running with the API on): `swift run NoteItCLI auth login`, `swift run NoteItCLI new "From the terminal" --tag cli`, `echo more | swift run NoteItCLI append <id>`, `swift run NoteItCLI search terminal --json`, `swift run NoteItCLI watch` while editing a note.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "CLIArgumentsTests|CLIOutputTests"` → `Executed <n> tests, with 0 failures`; `swift run NoteItCLI --version` prints `noteit dev` (unbundled) and `swift run NoteItCLI help` exits 0.
- [ ] Commit `feat(cli): add noteit command line tool`.

#### Task 17: Embeds table and signing — Moved to foundations (task 5.5)

Summary: foundations step 5 adds the embeds table to `scripts/build_app.sh`: one row per helper and appex (path in bundle, source, build step, entitlements), signed inside-out without `--deep`; a row whose source isn't built is skipped with a log line; the main app is not a row and is signed last. Later plans only add rows (`Contents/Helpers/noteit` in T23, `Contents/PlugIns/NoteItShare.appex` in T25; `Contents/Helpers/NoteItPluginHost` and `Contents/PlugIns/NoteItClipper.appex` in their own plans). A row string lists the columns in that order, and the path in bundle is the full bundle-relative path starting with `Contents/`. The Homebrew cask `binary` line for the CLI belongs to `growth`; this plan doesn't touch `scripts/update_cask.sh`.

#### Task 23: Bundle the CLI and add the installer
Needs T16 and foundations' embeds table.
**Files:**
- Modify: `scripts/build_app.sh`, `Sources/NoteIt/Settings/IntegrationsSettingsView.swift`, `Sources/NoteIt/Palette/PaletteCommandRegistry.swift`.
- Create: `Sources/NoteIt/Automation/LocalAPI/CLIInstaller.swift`, `Tests/NoteItTests/CLIInstallerTests.swift`.

Steps:
- [ ] `build_app.sh`: add one embeds row, `"Contents/Helpers/noteit|NoteItCLI||"` (path in bundle `Contents/Helpers/noteit`, source `$BIN_DIR/NoteItCLI`, no build step, no extra entitlements). The table's inside-out signing covers it; no `--deep`. The CLI ships at `Contents/Helpers/noteit`; `growth` adds the cask's `binary` line.
- [ ] `CLIInstaller`: `state()` reads the link with `destinationOfSymbolicLink`; `install()` tries `createSymbolicLink` and on permission failure calls `runPrivileged("mkdir -p /usr/local/bin && ln -sf '<tool>' /usr/local/bin/noteit")` with single quotes escaped; `uninstall()` removes only a link that points into a `NoteIt.app`.
- [ ] Settings › Integrations › Command line tool section and the palette command **Install Command Line Tool…**.
- [ ] Tests (temp dirs instead of `/usr/local/bin`, fake `runPrivileged`): `testStateNotInstalled`, `testInstallCreatesLink`, `testInstallFallsBackToPrivileged`, `testStatePointsElsewhere`, `testUninstallRefusesForeignLink`, `testQuotingInPrivilegedCommand`.
- [ ] Verification: `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` (exit 0); `codesign --verify --strict .selftest/app/NoteIt.app/Contents/Helpers/noteit` and `codesign --verify --deep --strict .selftest/app/NoteIt.app` (no output, exit 0); `.selftest/app/NoteIt.app/Contents/Helpers/noteit --version` prints `x-test`.
- [ ] Commit `feat(cli): bundle noteit in the app and add installer`.

### M5 — Spotlight

#### Task 18: Spotlight indexing
**Files:**
- Create: `Sources/NoteIt/Automation/Spotlight/SpotlightItemBuilder.swift`, `SpotlightIndexer.swift`, `Tests/NoteItTests/SpotlightItemBuilderTests.swift`.
- Modify: `Sources/NoteIt/App/AppDelegate.swift` (registration in the store-open step; `application(_:continue:restorationHandler:)` for `CSSearchableItemActionType` → `WindowRouter.showMainWindow()` + `NoteStore.shared.reveal(id)`), `Sources/NoteIt/Settings/IntegrationsSettingsView.swift` (Spotlight section), `Sources/NoteIt/Settings/Preferences.swift` (defaults: `spotlightEnabled` true, `spotlightIncludesText` true).
- [ ] Indexer: disabled when `Bundle.main.bundleIdentifier == nil`. `SpotlightIndexer` conforms to `DerivedIndex` and registers with organise's registry once per store open, in the store-open step in `AppDelegate` (right after `NoteStore.shared` is opened and before anything else uses the store), whether `spotlightEnabled` is on or off: `noteChanged` (body changes and new notes) reindexes the note, `noteRemoved` removes it (also called when a note is locked), `metadataChanged` (metadata-only changes, which never call `noteChanged`) reindexes it after a pin, notebook move, tag change or restore from Recently Deleted and removes it when it moves to Recently Deleted, `rebuild` walks `store.notes` in batches of 100 (plain text read on the main actor per note with `plainText(for:)`, items indexed with `indexSearchableItems` off the main actor), `flush` hands over pending batches. It doesn't subscribe to `LibraryChangeFeed`. It is never unregistered: while `spotlightEnabled` is false every hook returns at once, and turning the setting back on makes it schedule its own full rebuild. No edits to `NoteStore.swift`. Index version check against `spotlightIndexVersion`.
- [ ] `shouldIndex` is false for Recently Deleted and `NoteMeta.isLocked`.
- [ ] Tests: `testShouldIndexSkipsRecentlyDeleted`, `testShouldIndexSkipsLocked`, `testRegistersAsDerivedIndex`, `testNoteRemovedDeletesItem` (fake index), `testMetadataChangedReindexesOrRemoves`, `testDormantWhileOffAndRebuildsWhenTurnedOn`, `testItemAttributes`, `testTextIsTruncated`, `testTextOmittedWhenSettingOff`, `testDomainForNoNotebook`.
- [ ] Manual: bundled build; search a unique word from a note in Spotlight; choose it → NoteIt opens the note; move it to Recently Deleted → it disappears from Spotlight within a few seconds.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SpotlightItemBuilderTests` → `Executed <n> tests, with 0 failures`; `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` succeeds (exit 0).
- [ ] Commit `feat(automation): index notes in Spotlight`.

### M6 — Shortcuts

#### Task 19: App Intents metadata spike (timebox one day)
**Files:** `scripts/build_app.sh`.
- [ ] Build the app with `-Xswiftc -emit-const-values-path -Xswiftc <dir>` (per-file const values; check the produced `.swiftconstvalues` files).
- [ ] Run `xcrun appintentsmetadataprocessor` with `--module-name NoteIt`, `--sdk-root "$(xcrun --show-sdk-path)"`, `--platform-family macOS`, `--deployment-target 14.0`, `--target-triple`, `--binary-file`, `--source-file-list`, `--swift-const-vals-list`, `--output "$APP/Contents/Resources"`. Use one trivial intent to prove it.
- [ ] Success criterion: a bundled build shows the trivial action in the Shortcuts app on macOS 14 and 15.
- [ ] If it fails: write the finding in `docs/known-limitations.md` ("Shortcuts actions aren't available yet; use the Open URLs action with noteit:// links"), remove the trivial intent, and skip T20; plugins then expose no intents either. Commit `docs: note shortcuts limitation` instead.
- [ ] Verify: `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` succeeds, then `ls .selftest/app/NoteIt.app/Contents/Resources/Metadata.appintents` lists `extract.actionsdata` and `version.json`, and `grep -c TrivialIntent .selftest/app/NoteIt.app/Contents/Resources/Metadata.appintents/extract.actionsdata` (use the trivial intent's type name) prints a number above 0.
- [ ] Commit `build: generate app intents metadata in build_app.sh`.

#### Task 20: Intents
**Files:** `Sources/NoteIt/Automation/Intents/NoteEntity.swift`, `NoteIntents.swift`, `NoteItShortcuts.swift`; `Tests/NoteItTests/AutomationServiceTests.swift` (entity mapping cases).
- [ ] Entities and intents as spec §4, all calling `AutomationService.shared`. Errors throw a `LocalizedError` with `AutomationError.message`. `OpenNoteIntent.openAppWhenRun = true`; others false.
- [ ] `NoteItShortcuts` phrases: "Create a note in \(.applicationName)", "Search \(.applicationName)", "Add to a note in \(.applicationName)".
- [ ] Tests: `testNoteEntityFromMeta`, `testEntityQueryExcludesRecentlyDeleted`, `testSuggestedEntitiesAreTenMostRecent`.
- [ ] Manual: bundled build; in Shortcuts, Create Note → Append to Note → Get Note Text, run it; check the note.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AutomationServiceTests` → `Executed <n> tests, with 0 failures`; `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` succeeds (exit 0) and `test -d .selftest/app/NoteIt.app/Contents/Resources/Metadata.appintents` exits 0.
- [ ] Commit `feat(automation): add Shortcuts actions`.

### M7 — Daily notes

#### Task 21: Daily note routes (behind `DailyNotes.isAvailable`)
Needs only the foundations daily-note seams (step 4). `linking` owns their behaviour and sets the gate to true when its daily-note UI ships; until then everything here stays unavailable.
**Files:** `Sources/NoteIt/Automation/AutomationService.swift`, `LocalAPIHandlers.swift`, `URLSchemeHandler.swift`, `Intents/NoteIntents.swift`, `Sources/NoteItCLI/CLICommands.swift`; tests in `AutomationServiceTests.swift`, `LocalAPIHandlersTests.swift`, `URLSchemeHandlerTests.swift`.
- [ ] Every daily entry point first checks the injected `dailyNotesAvailable()` (default `DailyNotes.isAvailable`). While it is false: `.dailyNotesUnavailable`, so the API returns `501 not_implemented`, the URL hosts show **Daily notes aren't available in this version.**, the CLI exits 1 with that message and the intent fails with it.
- [ ] When available, `daily(date:create:)` calls `NoteStore.dailyNote(for:createIfMissing:)`; `appendToDaily` calls `DailyLogAppender.append(_:timestamp:to:in:now:)` (both `linking`; `timestamp: Bool = true`, `now: Date = Date()`, `to: date`, `in: NoteStore.shared`) with a `DailyLogContent`: `.plain(text)` for `format: plain`, and for `format: markdown` the text parsed with the existing importer (`MarkdownCodec.parse` → `DocConverter.importDocument`, as in T2) into `.attributed(…)`. `timestamp` is passed through (default true). Automation formats no daily lines itself; timestamps are `DailyLogLine`'s `- HH:mm text`, 24-hour, `en_US_POSIX`. No fallback provider.
- [ ] `GET /v1/daily?date=&create=&format=` and `POST /v1/daily/append` with `{text, timestamp?, date?, format?}` (`plain` or `markdown`; Markdown is parsed to `.attributed` as above). `noteit today`, `noteit append --today`, `noteit://daily`, `noteit://append?daily=today` (with the confirmation from T6) and the intent use the same calls.
- [ ] Add `daily` to `PingDTO.capabilities` only while the gate is true. Add `AppendToDailyNoteIntent` (App Intents can't be registered conditionally, so it is always listed and fails with the message while the gate is false).
- [ ] Tests (availability injected, so they run before linking flips the gate): `testDailyUnavailableWhileGateOff` (service, API 501, URL host), `testPingHasDailyOnlyWhenAvailable`, `testDailyCreateAndAppend`, `testDailyAppendGoesThroughDailyLogAppender` (24-hour time under a 12-hour user locale), `testDailyAppendMarkdownFormat` (Markdown arrives as `.attributed`, with bold kept and no literal `**`), `testDailyAppendWithoutTimestamp`, `testDailyGetFormatParam`, `testDailyGetWithoutCreate404`, `testDailyRouteCreateNeedsWrite`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "AutomationServiceTests|LocalAPIHandlersTests|URLSchemeHandlerTests"` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(automation): expose daily notes`.

### M8 — Mac Share extension

#### Task 24: Share inbox and importer
Needs T2 and T6.
**Files:**
- Create: `Sources/NoteItCore/ShareInboxItem.swift`, `Sources/NoteIt/Automation/Share/ShareInboxImporter.swift`, `Tests/NoteItCoreTests/ShareInboxItemTests.swift`, `Tests/NoteItTests/ShareInboxImporterTests.swift`.
- Modify: `Sources/NoteIt/Automation/AutomationService.swift` (`createFromShare`), `URLScheme/URLSchemeHandler.swift` (`.shareInbox`), `Sources/NoteIt/App/AppDelegate.swift` (import at launch).
- [ ] `ShareInboxItem` as frozen; Foundation only, so the appex can compile the same file.
- [ ] `ShareInboxImporter`: inbox at `<app group container>/share-inbox/`. An item is complete when `item.json` exists (the extension writes it last). Imports at launch and on `noteit://new?inbox=<UUID>` (which imports every complete item, not just the named one). Each item → `AutomationService.createFromShare`: bold title line, text, the link (`urlTitle` linked to `url`), then images through `addAttachment`, into the New Notes notebook. Then it writes `note-id` (the new note's UUID) into the item folder and calls `NoteStore.persistNow(meta.id)` (foundations), which returns once the note's body and the library metadata are durable. It deletes the folder only after `persistNow` returns. If `persistNow` throws, the folder stays and the item is a complete failed item (below). On a retry, an item whose `note-id` names a note the store has is not created again: the importer calls `persistNow` on that note and then deletes the folder. The importer takes `persist: (UUID) throws -> Void`, `store.persistNow` in the app, so tests inject a failing one. Incomplete items (no `item.json`) older than 7 days are orphans of an interrupted share and are removed; this age purge never touches complete items. A complete item whose import fails stays in the inbox, is retried at each launch and on each inbox link, and shows **Couldn't save a shared item.** with **Show in Finder** once; it leaves only when it imports or the user deletes it. Never asks for confirmation: the user already pressed **Save** in the sheet, and the link imports only items from the app group inbox (spec §3).
- [ ] Without an app group container (ad-hoc builds, no Team ID) the importer does nothing and `noteit://new?inbox=` shows **NoteIt doesn't know this link.**
- [ ] Tests: `testItemRoundTrip`, `testIncompleteItemIsSkipped`, `testImportCreatesNoteWithTitleTextLinkImages`, `testImportDeletesItem`, `testOldIncompleteItemsRemoved`, `testFailedCompleteItemsKept`, `testPersistFailureKeepsItem` (a failing `persist` leaves the folder with `item.json`, the images and `note-id`, and shows the failure notice once), `testRetryAfterPersistFailureDoesNotDuplicate` (the next import with a working `persist` makes no second note and deletes the folder), `testTooManyImagesRejected`, `testInboxLinkImportsAllCompleteItems`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ShareInboxItemTests|ShareInboxImporterTests'` → `Executed <n> tests, with 0 failures`.
- [ ] Commit `feat(automation): import shared items into notes`.

#### Task 25: Share extension appex
Needs T24 and foundations' embeds table.
**Files:**
- Create: `Sources/NoteItShareExtension/ShareViewController.swift`, `ShareItemWriter.swift`, `Resources/NoteItShareExtension.entitlements`, `scripts/build_share_extension.sh`.
- Modify: `Package.swift` (type-check-only target), `Resources/NoteIt.entitlements` (app group), `scripts/build_app.sh` (embeds row), `Sources/NoteIt/Settings/IntegrationsSettingsView.swift` (Share footnote).
- [ ] `Package.swift`: `.executableTarget(name: "NoteItShareExtension", dependencies: ["NoteItCore"], path: "Sources/NoteItShareExtension")`, listed only so it type-checks; it is never copied from `.build`.
- [ ] `ShareViewController` (AppKit `NSViewController`, principal class of the extension): accepts `public.plain-text`, `public.url` and `public.image` (`NSExtensionActivationSupportsText`, `NSExtensionActivationSupportsWebURLWithMaxCount = 1`, `NSExtensionActivationSupportsImageWithMaxCount = 10`). The sheet has a **Title** field, a preview and **Cancel** / **Save**. Text over 1 MB or an image over 25 MB shows "That's too large." and isn't saved.
- [ ] `ShareItemWriter`: writes images, then `item.json`, into `<group>/share-inbox/<UUID>/`, then opens `noteit://new?inbox=<UUID>` with `NSWorkspace` and completes the request. It never opens the library.
- [ ] `scripts/build_share_extension.sh`, built like the Safari extension: `xcrun swiftc -O -application-extension -module-name NoteItShareExtension -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension -target <arch>-apple-macos14.0` per architecture with the extension sources plus `Sources/NoteItCore/ShareInboxItem.swift`, then `lipo`; assemble `$BIN_DIR/NoteItShare.appex/Contents/{MacOS,Info.plist}` (the row's source; the embeds table copies it to `Contents/PlugIns/NoteItShare.appex`) with `NSExtensionPointIdentifier = com.apple.share-services` and the activation rule.
- [ ] `build_app.sh`: one embeds row, `"Contents/PlugIns/NoteItShare.appex|NoteItShare.appex|scripts/build_share_extension.sh|Resources/NoteItShareExtension.entitlements"` (path in bundle, source in `$BIN_DIR`, build step, entitlements: App Sandbox, app group `<TeamID>.<bundle id>`). The app group needs a Team ID, so ad-hoc builds skip the Share extension: `build_share_extension.sh` exits 0 without building, the table skips the row with a log line because its source isn't built, and the app gets no app group entitlement.
- [ ] Verification: `swift build 2>&1 | tail -3` → `Build complete!`; after the ad-hoc build `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh`, `test -e .selftest/app/NoteIt.app/Contents/PlugIns/NoteItShare.appex` fails (no Share extension); after a Developer ID build, `NOTEIT_SIGN_IDENTITY="Developer ID Application: <your team>" NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh`, `plutil -p .selftest/app/NoteIt.app/Contents/PlugIns/NoteItShare.appex/Contents/Info.plist` shows the `NSExtension` keys, and `codesign --verify --strict .selftest/app/NoteIt.app/Contents/PlugIns/NoteItShare.appex` and `codesign --verify --deep --strict .selftest/app/NoteIt.app` both pass. Manual: Safari › Share › NoteIt on a page → a note with the page title and link; Preview › Share › NoteIt on an image → a note with the image; quit NoteIt first and repeat → NoteIt launches and imports.
- [ ] Commit `feat(automation): add Share → NoteIt extension`.

### Task 22: Documentation
Done per milestone for its own part, then a final pass.
**Files:** `docs/local-api.md` (new), `docs/architecture.md`, `docs/development.md`, `docs/keyboard-shortcuts.md`, `docs/known-limitations.md`, `docs/roadmap.md`, `README.md`.
- [ ] `docs/local-api.md`: turning it on, pairing, scopes, discovery file, CORS rules, the `X-NoteIt-Extension-Bundle` header for Safari extensions, rate limits, every endpoint with one `curl` example, error codes, versioning promise.
- [ ] `architecture.md`: the `NoteItAPI` and `NoteItCLI` targets, `AutomationService`, change feed, the Share extension and its inbox.
- [ ] `development.md`: `NOTEIT_LOCAL_API_DEBUG`, `NOTEIT_API_URL`, `NOTEIT_TOKEN`, `swift run NoteItCLI`.
- [ ] `keyboard-shortcuts.md`: Copy Note Link ⌃⌘L.
- [ ] `roadmap.md`: tick "Spotlight, Shortcuts" and the Mac Share extension (the phone's share extension stays with `mobile`); add "Command line tool and Local API".
- [ ] `README.md`: features list and project layout.
- [ ] Verify: `test -f docs/local-api.md`; `grep -c "curl " docs/local-api.md` is at least the number of endpoints in spec §6.10; `grep -n "X-NoteIt-Extension-Bundle" docs/local-api.md`, `grep -n "NoteItAPI" docs/architecture.md`, `grep -n "NOTEIT_API_URL" docs/development.md`, `grep -n "Copy Note Link" docs/keyboard-shortcuts.md` and `grep -n "Command line tool and Local API" docs/roadmap.md` each print at least one line.
- [ ] Commit `docs: document automation, local api and cli`.

---

## Self-review

- **Spec coverage.** URL scheme, `noteit://note/<UUID>`, `URLRouteRegistry` dispatch, confirmation for `new` and `append` links (not for the share inbox or links that only open) and x-callback (T5 in foundations, T6); Copy Note Link and palette (T6, T13, T23); App Intents with the build risk (T19, T20); Spotlight as a derived index (T18); Local API server, discovery, versioning, capabilities, auth, scopes, Keychain, origin binding (Safari by scheme + bundle id), pairing, CORS, rate limits, sizes, every endpoint, search modes, locked notes (T7–T14, after foundations); events and changes (T4, T9, T10); attachments and staged uploads (T2, T11); in-process clients (T2, T12, T13); CLI with discovery, launch fallback, token storage, profile names, every command, exit codes, no `mcp` subtree in wave 1 (T15, T16); bundling and installer (T23); daily notes through the foundations seams, behind `DailyNotes.isAvailable` (T21); Share extension (T24, T25); docs (T22).
- **Moved to foundations.** T1 (5.1, 5.2, 5.4: the `NoteItAPI` and `NoteItAPITests` targets, the `NoteItCLI` stub, wire types, `HTTPMessage`, `RouteMatch`, `OriginDecision`, `LocalAPIContext`, `ClientRecord`, `LocalAPIRouteRegistry`, `URLRouteRegistry`), T5 (5.3: `URLCommand`, `AppendPosition`) and T17 (5.5: the embeds table and inside-out signing). This plan keeps their shapes in Frozen interfaces and only adds rows and behaviour; `extendTags` and `NotebookDTOExtending` are added here (T10).
- **Ownership.** Daily notes (`linking`: `dailyNote`, `DailyLogAppender`, `DailyLogLine`), the link grammar (`linking`: `NoteLink`), setting `DailyNotes.isAvailable` (`linking`), Markdown (`markdown-storage`: `NoteItMarkdown`), `editBody`, `DerivedIndex`, ranked search, the tag tree provider and notebook `parentID`/`path` through `extendTags`/`NotebookDTOExtending` (`organise`), locked notes (`sync-security`), `noteit mcp` and `NoteItMCP` (`private-ai`, wave 2), the `X-NoteIt-Extension-Bundle` header sent by the Safari build (`web-clipper`), the cask `binary` line (`growth`) are used, not built. No task adds a hook to `NoteStore.swift`.
- **Type consistency.** `AppendPosition` (from `NoteItCore` through a typealias), `HighlightDTO`, `BodyFormatDTO`, `DailyFormat`, `ChangeKind`/`ChangeOp`, `ClientRecord`, `ClientKind`, `RouteID`, `URLCommand`, `ShareInboxItem` and `AutomationError` are defined once in the frozen interfaces and used with the same names in every task.
- **Risks.** App Intents metadata outside Xcode (spike with a documented fallback); the case-insensitive `noteit`/`NoteIt` clash (the CLI target is `NoteItCLI`, renamed only inside the bundle); writes into an open editor (handled by `editBody`); the Share extension needs a Team ID for its app group, so ad-hoc builds ship without it.
