# NoteIt Web Clipper Implementation Plan

**Goal:** A browser extension for Safari, Chrome, Edge, Brave and Firefox that saves an article, a selection, a simplified page, a screenshot of the visible area, a bookmark or an image as a NoteIt note, with images saved in the note and a link back to the page. It talks only to the NoteIt app on the same Mac, through the Local API, with a paired token.

**Architecture:**
- **App side** (`Sources/NoteIt/Clipper/`): one Local API route, `POST /v1/clips`, registered through `automation`'s `LocalAPIRouteRegistry.register` with route id `web-clipper.clips` and advertised with `addCapability("web-clipper")` on `ping`'s `capabilities`. It validates the request (`ClipRequest`), downloads or decodes images (`ClipImageFetcher`), rewrites image references (`ClipMarkdownRewriter`), converts the Markdown through `NoteItMarkdown` (`portable` flavour, images through `MarkdownImportOptions.resolveImage`) and `DocConverter` (`ClipBodyConverter`), adds the layout and capture's source line (`ClipNoteBuilder`), and creates the note through the `NoteStore` API (`ClipService`). Everything except the final `NoteStore` call is pure or actor-isolated and unit tested. No `automation` code is edited.
- **Extension** (`clipper/`): one Manifest V3 TypeScript codebase, built per browser by esbuild.
  - Content extraction runs on demand in the page: Readability for articles, Turndown for HTML to Markdown.
  - The background script owns every Local API call, the context menu and the commands.
  - The popup and options page are plain DOM.
- **Safari:** `scripts/build_safari_extension.sh` compiles `Sources/NoteItClipperExtension/` with `xcrun swiftc` and wraps it with `clipper/dist/safari/` into `NoteItClipper.appex`, which the embeds table copies to `NoteIt.app/Contents/PlugIns/NoteItClipper.appex`. `Package.swift` lists that source as a target only so it type-checks. The appex is one row in foundations' embeds table in `scripts/build_app.sh`, which signs inside-out without `--deep`.

**Tech stack:**
- App: Swift 6 toolchain in Swift 5 language mode, SwiftPM, Network (`NWConnection`, for clip images; `URLSession` is not used for them), AppKit, SafariServices. XCTest via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- Extension: TypeScript 5, esbuild, `@mozilla/readability`, `turndown`, `turndown-plugin-gfm`, Vitest with jsdom, `web-ext`; pnpm on Node 24.
- CI: GitHub Actions on `macos-15` and `ubuntu-latest`. Extension tests run in their own `clipper` job (pnpm), as program §1 allows.

**Spec:** `docs/specs/2026-10-19-web-clipper-design.md` · **Program contract:** `docs/specs/2026-10-19-program-design.md`, which wins where the two disagree.

**Prerequisites:**
- Milestone 1, task 6, and everything after it that talks to a running app needs `automation`'s Local API (`docs/specs/2026-10-19-automation-design.md` §6, `docs/plans/2026-10-19-automation.md`): the `NoteItAPI` server, `LocalAPIRouteRegistry` with `addCapability`, `APIErrorCode` (including `readOnly` and `notReady`), tokens, pairing (Safari tokens bound by the origin scheme plus the extension's bundle identifier, sent in `X-NoteIt-Extension-Bundle`), `/v1/ping`, `/v1/pair/start`, `/v1/pair/complete`, `/v1/me`, `/v1/notebooks`, `/v1/tags`, `/v1/notes/{id}/open`, the Integrations settings tab and the embeds table in `scripts/build_app.sh`. `LocalAPIRouteRegistry` (foundations task 5.2), `HTTPMessage.swift`'s `HTTPRequest`/`HTTPResponse` (foundations task 5.1) and the embeds table (foundations task 5.5) land in wave 0.
- Task 1 needs `markdown-storage`'s `NoteItMarkdown` codec (its milestone 2) with the `portable` flavour and `MarkdownImportOptions.resolveImage` (program §6), and `NoteItDocAppKit`'s `DocConverter` (foundations).
- Task 5 needs `capture-plus`'s `CaptureFormatter.sourceLine(linkingTo:label:appName:)` (its Task 7). Both plans are in wave 2, and capture-plus's Task 7 merges before Task 5 here (program §2).
- The spec's Dependencies section lists the full set. Tasks 2–4 and 7–10 depend on no other sub-project and can start at once.

---

## Conventions for every task

- Swift tests (run from the repository root): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite> 2>&1 | tail -20`
- App build: `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3` must both end with `Build complete!`.
- Extension: `pnpm --dir clipper typecheck`, `pnpm --dir clipper test` and `pnpm --dir clipper build` must pass. `pnpm --dir clipper lint:firefox` (`web-ext lint`) must report 0 errors.
- Never touch real user data. When running the app, set `NOTEIT_DATA_DIR="$PWD/.selftest/<name>"` (run from the repository root; `<name>` is any folder name) (already gitignored).
- Use a separate browser profile for manual checks: `web-ext run --source-dir clipper/dist/firefox`, and a Chrome profile started with `--user-data-dir="$PWD/.selftest/chrome"`.
- Commit after each task with Conventional Commits, scope `clipper`, e.g. `feat(clipper): add clip request validation`. Never amend, rebase or force.
- No `#Preview`. Comments only where something is non-obvious. No new third-party Swift dependencies.
- No new extension permissions beyond the spec's list. `clipper/test/manifest.test.ts` enforces it.
- User-facing strings are copied exactly from the spec.

## File structure

```
Package.swift                                         (modify: NoteItClipperExtension target for type-checking only, no product;
                                                       NoteIt links SafariServices)
Sources/NoteIt/Clipper/
  ClipRequest.swift                                   ClipMode, ClipImage, ClipRequest, ClipResponse, ClipLimits, validation
  ClipMarkdownRewriter.swift                          noteit-image: references → local file names or links
  ClipImageFetcher.swift                              ClipImageFetching protocol + actor: downloads, sniffing, host rules
  PinnedImageFetcher.swift                            thin wrapper: one image GET through PinnedHTTPClient, failures → ClipImageFailure
  ClipBodyConverter.swift                             Markdown → noteit-doc (NoteItMarkdown) → editor text (DocConverter)
  ClipNoteBuilder.swift                               @MainActor body assembly per mode, tag normalisation
  ClipService.swift                                   @MainActor: validate → images → build → NoteStore; idempotency
  ClipsRoute.swift                                    registers POST /v1/clips and the web-clipper capability; error mapping
  SafariClipperStatus.swift                           SFSafariExtensionManager wrapper + ClipperLinks
  WebClipperSettingsSection.swift                     Settings › Integrations › Web Clipper
Sources/NoteIt/Net/
  PinnedHTTPClient.swift                              shared, owned here, used by plugins: resolve once, address checks,
                                                      connect to the checked IP, TLS to the original host, HTTP/1.1, redirects
Sources/NoteIt/Settings/IntegrationsSettingsView.swift (modify, created by automation: add the section)
Sources/NoteIt/Palette/PaletteCommandRegistry.swift   (modify: "Set Up Web Clipper…")
Sources/NoteIt/App/AppDelegate.swift                  (modify: register ClipsRoute at launch)
Sources/NoteItClipperExtension/
  SafariWebExtensionHandler.swift                     NSExtensionRequestHandling; replies "unsupported"
Resources/NoteItClipperExtension.entitlements         app sandbox
scripts/build_safari_extension.sh                     the embeds row's build step: compiles the appex with xcrun swiftc, builds
                                                      clipper/dist/safari if needed, assembles NoteItClipper.appex + Info.plist
scripts/build_app.sh                                  (modify: one row in foundations' embeds table for Contents/PlugIns/NoteItClipper.appex)
Tests/NoteItTests/
  ClipRequestTests.swift, ClipMarkdownRewriterTests.swift, ClipImageFetcherTests.swift, PinnedImageFetcherTests.swift,
  PinnedHTTPClientTests.swift,
  ClipBodyConverterTests.swift, ClipNoteBuilderTests.swift, ClipServiceTests.swift
  PaletteCommandRegistryTests.swift                   (modify: the new command)
clipper/
  package.json, pnpm-lock.yaml, tsconfig.json, vitest.config.ts, .gitignore (dist/, node_modules/)
  README.md, PRIVACY.md, CHANGELOG.md
  manifest/base.json, manifest/chrome.json, manifest/firefox.json, manifest/safari.json
  scripts/build.mjs                                   esbuild per target + manifest merge + static copy
  scripts/package.mjs                                 zips for stores + source zip with BUILD.md
  icons/                                              16/32/48/128 PNG + Safari toolbar template
  store/                                              listing text, permission justifications
  src/shared/ext.ts, storage.ts, messages.ts, constants.ts
  src/api/types.ts, errors.ts, client.ts
  src/convert/markdown.ts, images.ts, url.ts, browser.ts
  src/content/extract.ts, article.ts, selection.ts, page.ts, bookmark.ts, toast.ts
  src/background/index.ts, menus.ts, commands.ts, save.ts, badge.ts
  src/popup/popup.html, popup.css, popup.ts, state.ts, tags.ts
  src/options/options.html, options.css, options.ts
  test/fixtures/*.html                                saved pages: article, lazy images, srcset, table/code, hidden nav, no-article
  test/*.test.ts                                      manifest, markdown, images, url, browser, article, selection, page, bookmark,
                                                      client, state
.github/workflows/ci.yml                              (modify: clipper job; Safari appex check on macOS)
.github/workflows/release.yml                         (modify: build clipper for Safari; NOTEIT_REQUIRE_CLIPPER=1 only after the T14 spike passes)
.github/workflows/clipper-release.yml                 (create)
docs/development.md, docs/releasing.md, docs/architecture.md, docs/roadmap.md, docs/known-limitations.md,
README.md                                             (modify: document the clipper)
```

## Frozen interfaces

### Swift (app)

```swift
// Sources/NoteIt/Clipper/ClipRequest.swift
enum ClipMode: String, Codable, CaseIterable, Sendable { case article, selection, page, screenshot, bookmark, image }

struct ClipImage: Codable, Equatable, Sendable {
    var id: String              // "i1", "i2", … referenced as noteit-image:<id>
    var url: URL?               // exactly one of url / data
    var data: Data?             // base64 in JSON
    var mimeType: String?
    var alt: String?
}

struct ClipRequest: Codable, Equatable, Sendable {
    var clientClipID: UUID
    var mode: ClipMode
    var url: URL
    var title: String
    var markdown: String?
    var images: [ClipImage] = []
    var comment: String?
    var siteName: String?
    var byline: String?
    var publishedAt: String?    // ISO 8601 date or date-time, shown as a long date when it parses
    var browser: String?
    var notebookID: UUID?
    var tags: [String] = []
    var downloadImages: Bool = true
}

struct ValidatedClip: Equatable, Sendable {
    var request: ClipRequest    // normalised title/comment/tags, markdown possibly cut
    var shortened: Bool
}

enum ClipValidationError: Error, Equatable, Sendable {
    case unsupportedURL, missingContent, tooManyImages, ambiguousImage(String), imageTooLarge(String), tooManyTags
    var message: String { get }  // plain sentence for the API error body
}

extension ClipRequest {
    func validated() throws -> ValidatedClip
}

struct ClipResponse: Codable, Equatable, Sendable {
    var noteID: UUID
    var notebookID: UUID?
    var notebookName: String?
    var title: String
    var imagesSaved: Int
    var imagesFailed: Int
    var shortened: Bool
}

enum ClipLimits {
    static let maxRequestBytes = 60 * 1024 * 1024
    static let maxMarkdownCharacters = 1_000_000
    static let maxTitleLength = 200
    static let maxCommentLength = 10_000
    static let maxTags = 20
    static let maxImages = 50
    static let maxImageBytes = 10 * 1024 * 1024
    static let maxInlineImageBytesTotal = 40 * 1024 * 1024
    static let concurrentDownloads = 4
    static let perImageTimeout: TimeInterval = 8
    static let downloadBudget: TimeInterval = 20
    static let idempotencyWindow: TimeInterval = 600
    static let idempotencyCapacity = 50
}

// Sources/NoteIt/Clipper/ClipMarkdownRewriter.swift
enum ClipMarkdownRewriter {
    static let scheme = "noteit-image:"
    /// saved: image id → local file name ("clip-image-3.png"). Saved references become `![alt](name)`,
    /// unsaved ones with a URL become `[Image: alt](url)`, others are removed.
    static func rewrite(_ markdown: String, images: [ClipImage], saved: [String: String]) -> String
}

// Sources/NoteIt/Clipper/ClipImageFetcher.swift
enum ClipImageFailure: Equatable, Sendable { case notAllowed, tooLarge, notAnImage, timedOut, http(Int), network, skipped }

struct FetchedImage: Equatable, Sendable { var id: String; var data: Data; var fileExtension: String }

struct ClipImageResults: Equatable, Sendable {
    var saved: [String: FetchedImage] = [:]
    var failed: [String: ClipImageFailure] = [:]
}

protocol ClipImageFetching: Sendable {
    func fetch(_ images: [ClipImage], pageURL: URL, download: Bool) async -> ClipImageResults
}

actor ClipImageFetcher: ClipImageFetching {
    init(pinned: PinnedImageFetcher = PinnedImageFetcher())   // tests pass one built on a client with a fake resolver and a fake transport
    func fetch(_ images: [ClipImage], pageURL: URL, download: Bool) async -> ClipImageResults
    static func fileExtension(sniffing data: Data) -> String?   // png, jpg, gif, webp, heic, tiff, bmp, svg
    static func isAllowed(_ url: URL) -> Bool                    // http(s), a host, not localhost / *.localhost, not a non-public IP literal
}

// Sources/NoteIt/Net/PinnedHTTPClient.swift — module NoteIt (the app target; no new SwiftPM target).
// Owned by web-clipper (wave 2). plugins (wave 3) sends every net.fetch through it and doesn't redeclare any of it.
protocol HostResolving: Sendable { func resolve(_ host: String) async throws -> [String] }   // numeric addresses
struct SystemHostResolver: HostResolving { /* getaddrinfo (AF_UNSPEC), off the cooperative pool */ }

enum PinnedHTTPError: Error, Equatable, Sendable { case notAllowed, tooLarge, timedOut, network }

struct PinnedHTTPPolicy: Sendable {
    var allowsURL: @Sendable (URL) -> Bool        // scheme and host rules; checked for the first URL and every redirect target
    var allowsLoopback: @Sendable (String) -> Bool // host → true only when the caller explicitly granted it (plugins' network:localhost or
                                                  // network:127.0.0.1); then loopback addresses pass for that host, other non-public ones never do
    var methods: Set<String>                      // upper-case; anything else → notAllowed before resolving
    var maxRequestBodyBytes: Int                  // 0 = no body allowed
    var maxResponseBytes: Int
    var timeout: TimeInterval                     // the whole send, redirects included
    var maxRedirects: Int
}

struct PinnedHTTPRequest: Equatable, Sendable {
    var url: URL; var method: String = "GET"; var headers: [String: String] = [:]; var body: Data? = nil
}
struct PinnedHTTPResponse: Equatable, Sendable { var status: Int; var headers: [String: String]; var body: Data; var url: URL }
                                                  // header names lowercased; url is the final URL after redirects

/// Every hop: policy.allowsURL, then the host is resolved once (IP literals are checked directly) and every address must pass
/// isPublicAddress, or isLoopbackAddress when policy.allowsLoopback(host); the connection goes to the first checked address,
/// so nothing re-resolves between the check and the connect. Redirects (301, 302, 303, 307, 308) are followed here, each
/// target through the same path. No cookies, cache, credentials or proxies exist on this path, and URLSession isn't used.
struct PinnedHTTPClient: Sendable {
    init(resolver: HostResolving = SystemHostResolver(), transport: PinnedTransporting = NWPinnedTransport())
    func send(_ request: PinnedHTTPRequest, policy: PinnedHTTPPolicy) async throws(PinnedHTTPError) -> PinnedHTTPResponse
    static func isPublicAddress(_ numeric: String) -> Bool       // inet_pton-parsed IPv4/IPv6; mapped/compatible IPv6 judged by its IPv4 part
    static func isLoopbackAddress(_ numeric: String) -> Bool     // 127.0.0.0/8, ::1, and ::ffff:127.x.y.z
}

struct PinnedRequest: Equatable, Sendable {
    var address: String          // numeric, already checked; never resolved again
    var port: UInt16             // URL port, else 443 for https and 80 for http
    var tlsServerName: String?   // the URL's original host for https, nil for http
    var head: Data               // "<METHOD> <path?query> HTTP/1.1", Host, the caller's headers, Accept-Encoding: identity,
                                 // Content-Length when there is a body, Connection: close
    var body: Data?
}
struct PinnedResponse: Equatable, Sendable { var status: Int; var headers: [String: String]; var body: Data }   // header names lowercased

protocol PinnedTransporting: Sendable {
    /// Sends `head` and `body`, reads the response (Content-Length, chunked or until close) and throws tooLarge past maxBytes.
    func exchange(_ request: PinnedRequest, maxBytes: Int, timeout: TimeInterval) async throws(PinnedHTTPError) -> PinnedResponse
}
/// NWConnection to NWEndpoint.hostPort(host: address, port:). For https: NWProtocolTLS.Options with
/// sec_protocol_options_set_tls_server_name(tlsServerName) and the system's normal certificate validation against that name.
struct NWPinnedTransport: PinnedTransporting { init() }

// Sources/NoteIt/Clipper/PinnedImageFetcher.swift — the clipper's thin wrapper over PinnedHTTPClient
/// One image GET: method GET only, no body, Referer and Accept: image/*, allowsURL = ClipImageFetcher.isAllowed,
/// allowsLoopback always false, at most 3 redirects, maxResponseBytes = maxBytes. PinnedHTTPError maps one to one onto
/// ClipImageFailure; a non-200 status → http(code), a Content-Type that isn't image/* → notAnImage.
struct PinnedImageFetcher: Sendable {
    init(client: PinnedHTTPClient = PinnedHTTPClient())
    func get(_ url: URL, referer: String, maxBytes: Int, timeout: TimeInterval) async throws(ClipImageFailure) -> Data
}

// Sources/NoteIt/Clipper/ClipBodyConverter.swift
import NoteItMarkdown
import NoteItDoc
import NoteItDocAppKit
enum ClipBodyConverter {
    /// images: local file name ("clip-image-3.png") → bytes. MarkdownCodec.parse in the portable flavour (after a leading
    /// blank line, front matter ignored) with MarkdownImportOptions.resolveImage answering from `images` → BodyContainer
    /// with the saved images as attachments → DocConverter.importDocument with the app's styles.
    /// resolveImage returns nil for any other URL, so those images are dropped; it never fetches or reads files.
    static func attributedString(fromMarkdown markdown: String, images: [String: FetchedImage]) async throws -> NSAttributedString
}

// Sources/NoteIt/Clipper/ClipNoteBuilder.swift
@MainActor
enum ClipNoteBuilder {
    /// images: local file name → bytes, passed on to ClipBodyConverter.
    static func build(_ clip: ValidatedClip, rewrittenMarkdown: String, images: [String: FetchedImage]) async throws -> NSAttributedString
    nonisolated static func normalizedTag(_ raw: String) -> String?
    nonisolated static func bylineText(byline: String?, publishedAt: String?) -> String?
    static let shortenedNotice = "Clip shortened: the page was longer than NoteIt saves in one note."
}

// Sources/NoteIt/Clipper/ClipService.swift
enum ClipServiceError: Error, Equatable {
    case invalid(ClipValidationError), notebookNotFound(UUID), notebookReadOnly(UUID), libraryUnavailable, conversionFailed
}

@MainActor
final class ClipService {
    init(store: NoteStore, fetcher: ClipImageFetching = ClipImageFetcher(),
         now: @escaping () -> Date = Date.init,
         notify: @escaping (ClipResponse) -> Void = ClipService.showNotice)
    func save(_ request: ClipRequest) async throws -> ClipResponse
    static func showNotice(_ response: ClipResponse)        // CaptureToast "Clipped to <notebook>" unless NoteIt is active
}

// Sources/NoteIt/Clipper/ClipsRoute.swift — RouteSpec, LocalAPIContext, HTTPResponse, APIErrorCode come from automation's NoteItAPI
import NoteItAPI
enum ClipsRoute {
    static let capability = "web-clipper"
    /// RouteSpec(id: "web-clipper.clips", method: .POST, pattern: "/clips", scope: .write, body: .json, bucket: .write,
    ///           maxBodyBytes: ClipLimits.maxRequestBytes, summary: "Save a web clip") — automation's public init
    static let spec: RouteSpec
    static func register(in registry: LocalAPIRouteRegistry = .shared, service: ClipService)   // register(spec) + addCapability(capability)
    static func handle(_ context: LocalAPIContext, service: ClipService) async -> HTTPResponse
    /// .invalid → .badRequest, .notebookNotFound → .notFound, .notebookReadOnly → .readOnly (403),
    /// .libraryUnavailable → .notReady (503, "Your library is still opening. Try again in a moment."),
    /// .conversionFailed and anything else → .internal.
    /// Oversized bodies are rejected as .tooLarge by the server before the handler runs.
    static func apiError(for error: Error) -> (code: APIErrorCode, message: String)
}

// From capture-plus (Task 7), used as is:
// CaptureFormatter.sourceLine(linkingTo url: URL, label: String?, appName: String?) -> NSAttributedString

// Sources/NoteIt/Clipper/SafariClipperStatus.swift
enum SafariClipperState: Equatable { case on, off, unavailable }
enum SafariClipperStatus {
    static let extensionBundleID = AppIdentity.bundleID + ".clipper"
    static func state() async -> SafariClipperState
    static func openSafariSettings()
}
enum ClipperLinks {
    static let chrome: URL      // Chrome Web Store listing; the clipper README's install section until it's approved
    static let firefox: URL     // AMO listing; same fallback
}
```

### TypeScript (extension)

```ts
// clipper/src/api/types.ts
export type ClipMode = "article" | "selection" | "page" | "screenshot" | "bookmark" | "image";
export interface ClipImage { id: string; url?: string; data?: string; mimeType?: string; alt?: string }
export interface ClipDraft {
  mode: ClipMode; url: string; title: string; markdown?: string; images: ClipImage[];
  siteName?: string; byline?: string; publishedAt?: string; excerpt?: string;
  wordCount: number; shortened: boolean;
}
export interface ClipChoices { title: string; notebookID?: string; tags: string[]; comment?: string; downloadImages: boolean }
export interface ClipRequest extends Omit<ClipDraft, "excerpt" | "wordCount" | "shortened">, ClipChoices {
  clientClipID: string; browser?: string;
}
export interface ClipResponse {
  noteID: string; notebookID?: string; notebookName?: string; title: string;
  imagesSaved: number; imagesFailed: number; shortened: boolean;
}
export interface Ping { name: "NoteIt"; apiVersion: number; appVersion: string; capabilities: string[] }
export interface Notebook { id: string; name: string; symbol: string; color: string; sortIndex: number; noteCount: number; parentID?: string }
export interface Tag { name: string; noteCount: number }
export interface Connection { port: number; token: string; clientID: string; pairedAt: string }

// clipper/src/api/errors.ts
export type ApiErrorKind =
  | "unreachable" | "unauthorized" | "notebookGone" | "notebookReadOnly" | "tooLarge" | "busy" | "notReady" | "appTooOld"
  | "pairingWrongCode" | "pairingCancelled" | "pairingDenied" | "pairingBusy" | "failed";
// code and message come from automation's body {"error":{"code","message"}}; retryAfter from Retry-After on 429
export class ApiError extends Error { kind: ApiErrorKind; code?: string; retryAfter?: number }

// clipper/src/api/client.ts
export class LocalApiClient {
  constructor(opts: { port: number; token?: string; extensionBundle?: string; fetch?: typeof fetch });  // extensionBundle: Safari build only
  ping(): Promise<Ping>;                                           // GET /v1/ping, 1 s timeout
  startPairing(clientName: string): Promise<{ pairingID: string; expiresAt: string }>;   // kind "extension", scopes read+write
  completePairing(pairingID: string, code: string): Promise<{ token: string; clientID: string; scopes: string[] }>;
  disconnect(): Promise<void>;                                     // DELETE /v1/me
  notebooks(): Promise<{ notebooks: Notebook[]; defaultNotebookID: string | null }>;
  tags(): Promise<Tag[]>;
  saveClip(req: ClipRequest): Promise<ClipResponse>;               // 90 s timeout
  openNote(id: string): Promise<void>;
}

// clipper/src/shared/constants.ts
export const PORT_RANGE = [47600, 47609] as const;               // automation's default and fallbacks
export const SAFARI_EXTENSION_BUNDLE_ID = "io.github.rutbergphilip.noteit.clipper";  // sent as X-NoteIt-Extension-Bundle by the Safari build
// clipper/src/api/discover.ts
export function findPort(opts: { preferred?: number; fixed?: number; fetch?: typeof fetch }): Promise<number>;  // throws ApiError("unreachable")
export const MAX_DRAFT_BYTES = 60 * 1024 * 1024;
export const MAX_MARKDOWN_CHARS = 1_000_000;
export const MAX_IMAGES = 50;
export const EXTRACT_TIMEOUT_MS = 10_000;

// clipper/src/convert/markdown.ts
export function htmlToMarkdown(root: Node, baseURI: string): { markdown: string; images: ClipImage[]; shortened: boolean };
// clipper/src/convert/url.ts
export function cleanURL(url: string): string;                     // strips the spec's tracking parameters
// clipper/src/convert/browser.ts
export function browserName(nav: Navigator, target: "chrome" | "firefox" | "safari"): Promise<string | undefined>;
// clipper/src/content/extract.ts — the injected entry; returns via executeScript's result
export function extract(mode: Exclude<ClipMode, "screenshot" | "image">): Promise<ClipDraft>;
```

---

## Tasks

Dependency graph:
- **Milestone 1:** T1 ∥ T2 → {T3, T4} in parallel → T5 (needs T1, T3 and `capture-plus`'s `sourceLine(linkingTo:label:appName:)`, its Task 7, which merges first in wave 2) → T6 (needs T4, T5 and automation's `LocalAPIRouteRegistry`). T1 needs `NoteItMarkdown` and `DocConverter`.
- **Milestone 2:** T7 → {T8, T9} in parallel → T10 (needs T8) → T11 (needs T9, T10) → T12 → T13 (needs T6).
- **Milestone 3:** T14 (needs T7; its spike gates the milestone) → T15 (needs foundations' embeds table) → T16 (T16 can run in parallel with T15).
- **Milestone 4:** T17 (needs T15 for the appex check; the `clipper` job alone needs only T7) → T18 → T19.
- Milestones 1 and 2 can run in parallel. Milestone 3 needs only T7 to start.

### Milestone 1 — NoteIt accepts clips

Ships on its own: once the Local API is on, `curl` or any script can save a clip, with images, tags and a source line.

#### Task 1: Markdown to note text through NoteItMarkdown
**Files:** create `Sources/NoteIt/Clipper/ClipBodyConverter.swift` and `Tests/NoteItTests/ClipBodyConverterTests.swift`.

The source line is not extracted here: `capture-plus` owns that change (its Task 7 extracts `CaptureFormatter.sourceLine(linkingTo:label:appName:)`), and this plan only calls it in T5.
- [ ] `attributedString(fromMarkdown:images:)`:
  1. Prefix a blank line and call `MarkdownCodec.parse` (`NoteItMarkdown`) in the `portable` flavour. Ignore any front matter it reports.
  2. Pass `MarkdownImportOptions(resolveImage:)` with a closure that returns the bytes for a URL whose path is a key in `images` and nil for everything else. Saved images become attachments (MIME type from the sniffed extension, the file name, the bytes); image nodes the closure returns nil for are removed. The closure never fetches or reads files; downloads stay in `ClipImageFetcher` (T4) with its limits.
  3. `DocConverter.importDocument(_:styles:)` (`NoteItDocAppKit`) with the app's style provider, then `NoteItTextView.normalize`.
  - No `MarkdownReader`, no file system access, no `BodyCodec` (that stays inside `NoteBodyStorage`).
- [ ] Tests: `testHeadingsListsTablesAndCodeKeepStyles`, `testCodeBlockKeepsLanguage`, `testSavedImageBecomesAttachment` (the attachment's bytes equal the input), `testUnknownImagePathIsDropped`, `testAbsolutePathIsNeverRead`, `testRemoteImageURLIsNeverFetched`, `testLeadingRuleIsNotFrontMatter` (Markdown starting with `---\ntitle: x\n---` keeps its text), `testChecklistSurvives`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipBodyConverterTests 2>&1 | tail -20` → `Executed N tests, with 0 failures`.
- [ ] Commit `feat(clipper): convert clip Markdown through NoteItMarkdown`.

#### Task 2: Clip request and validation (parallel with T1)
**Files:** create `Sources/NoteIt/Clipper/ClipRequest.swift` and `Tests/NoteItTests/ClipRequestTests.swift`.
- [ ] Write the frozen types. Decoding uses `JSONDecoder` with default `Data` base64 decoding; unknown keys are ignored.
- [ ] `validated()`:
  - `url` http(s) with a host, else `unsupportedURL`;
  - the title single-lined and cut to 200 characters with "…", or the host when empty;
  - `comment` cut to 10,000; more than 20 tags → `tooManyTags`;
  - more than 50 images → `tooManyImages`; an image with both or neither of `url`/`data` → `ambiguousImage(id)`;
  - inline data over 10 MB per image or 40 MB in total → `imageTooLarge(id)`;
  - article, selection and page need non-blank `markdown`; screenshot and image need at least one image; bookmark needs nothing else (`missingContent` otherwise);
  - `markdown` over 1,000,000 characters is cut at the last `\n\n` before the limit (or hard at the limit if there is none), with `shortened = true`.
- [ ] Create `clipper/test/fixtures/clip-article.json`: the spec's example without comments, with a small real PNG as `i2`.
- [ ] Tests: one per rule above, plus `testDecodesTheSharedExample` (reads that fixture through `#filePath`) and `testUnknownKeysAreIgnored`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipRequestTests 2>&1 | tail -20` → `Executed N tests, with 0 failures`. `swift build 2>&1 | tail -3` → `Build complete!`, exit 0.
- [ ] Commit `feat(clipper): add clip request model and validation`.

#### Task 3: Markdown image rewriting (parallel with T4)
**Files:** create `Sources/NoteIt/Clipper/ClipMarkdownRewriter.swift` and `Tests/NoteItTests/ClipMarkdownRewriterTests.swift`.
- [ ] Scan for `![` … `](noteit-image:<id>)`. The alt text may contain escaped `]`, and the id is `[A-Za-z0-9_-]+`.
  - Saved → `![alt](<file name>)`.
  - Unsaved with a URL → `[Image: <alt, else the URL's last path component, else "image">](<url>)`.
  - Otherwise → removed.
- [ ] Leave every other image or link untouched, and never rewrite inside fenced code blocks or inline code.
- [ ] Tests: `testSavedImageBecomesLocalName`, `testFailedImageBecomesLabelledLink`, `testInlineFailureIsRemoved`, `testAltWithBrackets`, `testCodeBlocksUntouched`, `testUnknownIDIsRemoved`, `testOrdinaryImagesUntouched`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipMarkdownRewriterTests 2>&1 | tail -20` → `Executed N tests, with 0 failures`.
- [ ] Commit `feat(clipper): rewrite clip image references`.

#### Task 4: Pinned HTTP client and image fetcher (parallel with T3)
**Files:** create `Sources/NoteIt/Net/PinnedHTTPClient.swift`, `Sources/NoteIt/Clipper/ClipImageFetcher.swift`, `Sources/NoteIt/Clipper/PinnedImageFetcher.swift`, `Tests/NoteItTests/PinnedHTTPClientTests.swift`, `Tests/NoteItTests/ClipImageFetcherTests.swift` and `Tests/NoteItTests/PinnedImageFetcherTests.swift` (with a fake `HostResolving` that counts calls and a fake `PinnedTransporting` that records each `PinnedRequest` and answers from a table; every fetch test injects both, so no test touches real DNS or the network). `PinnedHTTPClient` is shared: `plugins` (wave 3) uses it for `net.fetch`, so it holds no clipper rules.
- [ ] `PinnedHTTPClient.send`, for each hop:
  - `policy.allowsURL(url)`, else `notAllowed`. The method must be in `policy.methods` and a body at most `policy.maxRequestBodyBytes`, else `notAllowed`, before anything is resolved.
  - Resolve the host once with `resolver` (`SystemHostResolver`, `getaddrinfo`). No address → `notAllowed`. Every address must pass `isPublicAddress`, or `isLoopbackAddress` when `policy.allowsLoopback(host)` is true; otherwise `notAllowed`, with nothing sent. Other non-public addresses (`10/8`, `192.168/16`, link-local and the rest) are never allowed, whatever the policy. IP literals skip the resolver and get the same check.
  - Build a `PinnedRequest` for the first address, in the resolver's order, with `tlsServerName` = the original host for https, and call `transport.exchange` with `policy.maxResponseBytes` and the time left of `policy.timeout`. Nothing resolves the host again for this hop. The head drops any caller `Host`, `Content-Length`, `Transfer-Encoding`, `Connection` and `Accept-Encoding` and writes its own.
  - 301, 302, 303, 307 or 308 with a `Location`: resolve it against the current URL and repeat the hop from the top (at most `policy.maxRedirects`; one more, or a missing `Location`, → `notAllowed`). 301, 302 and 303 switch to `GET` without a body (`HEAD` stays `HEAD`); 307 and 308 keep the method and body. A redirect to another host drops `Authorization`. A rejected target → `notAllowed`, and nothing is sent to it.
  - Any other status is returned as is, with the final URL.
- [ ] `NWPinnedTransport.exchange`: `NWConnection` to `.hostPort(host: <numeric address>, port:)`; for https, `NWProtocolTLS.Options` with `sec_protocol_options_set_tls_server_name` set to the original host and no custom verify block, so the system validates the certificate against that name and a failure is `network`. Send `head` and `body`, then read the status line and headers, and the body by `Content-Length`, `chunked` or until close, stopping past `maxBytes` (`tooLarge`) and at `timeout` (`timedOut`). An internal init takes extra trust anchors for tests only; it installs a verify block that evaluates `SecTrust` with `SecPolicyCreateSSL(true, serverName)` against those anchors plus the system's.
- [ ] `PinnedImageFetcher.get`: one `client.send` of `GET` with `Referer` and `Accept: image/*`, using the policy in Frozen interfaces (`allowsURL` = `isAllowed`, `allowsLoopback` always false, methods `GET`, no body, `maxBytes`, `timeout`, 3 redirects). Map `PinnedHTTPError` to the `ClipImageFailure` case of the same name. Only `200` is accepted; other statuses → `http(code)`. A `Content-Type` that isn't `image/*` → `notAnImage`.
- [ ] `fetch`:
  - Inline images are sniffed and stored with no network.
  - URL images: `notAllowed` if `!isAllowed`, and `skipped` when `download == false`.
  - Each URL image is one `pinned.get(url, referer:, maxBytes: maxImageBytes, timeout: perImageTimeout)`; its failures pass through unchanged.
  - Download with a task group of at most 4 at a time, under an overall deadline of `downloadBudget`; cancelled ones become `timedOut`.
  - Each request sets `Referer` to the page's scheme + host + `/`.
  - Sniff the type of the returned bytes, or fail with `notAnImage`.
- [ ] `isAllowed`: scheme http/https and a host; reject `localhost`, `*.localhost`, and any IP literal for which `PinnedHTTPClient.isPublicAddress` is false.
- [ ] `PinnedHTTPClient.isPublicAddress`: false for `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.168.0.0/16`, `224.0.0.0/4` and above, `::`, `::1`, `fc00::/7`, `fe80::/10`, `ff00::/8`, and for `::ffff:a.b.c.d` / `::a.b.c.d` whose IPv4 part is not public; false for anything that doesn't parse.
- [ ] `fileExtension(sniffing:)`: PNG `89 50 4E 47`, JPEG `FF D8 FF`, GIF `GIF8`, WebP `RIFF....WEBP`, HEIC `ftypheic|heix|mif1` at offset 4, TIFF `II*\0`/`MM\0*`, BMP `BM`. SVG: after an optional BOM, whitespace and `<?xml …?>`/comments, the first element is `<svg`.
- [ ] Tests:
  - `testDownloadsAndSniffsPNG`, `testRejectsLoopbackHosts` (table-driven), `testStopsOverSizeLimit`, `testNonImageFails`, `testHTTPErrorIsReported`;
  - in `PinnedHTTPClientTests`: `testPublicAddressTable` (each range above, both edges, plus `8.8.8.8` and `2606:4700::1` public), `testLoopbackAddressTable`, `testDNSRebindingIsPinned` (as below, through `send`), `testRedirectToPrivateAddressIsRejected` (302 to a host the fake resolver maps to `192.168.1.10` → `notAllowed`, nothing sent to it), `testGrantedLocalhostIsAllowed` (`allowsLoopback` true for `localhost`, resolver answers `127.0.0.1` → the request goes to `127.0.0.1`), `testGrantedLocalhostStillRejectsPrivate` (same policy, a host resolving to `10.0.0.5` → `notAllowed`), `testUngrantedLocalhostIsRejected`, `testMethodNotInPolicyIsRejected`, `testBodyOverPolicyIsRejected`, `testSeeOtherSwitchesToGet`, `testTemporaryRedirectKeepsMethodAndBody`, `testCrossHostRedirectDropsAuthorization`, `testTimeoutCoversRedirects`;
  - `testRedirectToLoopbackIsCancelled` (transport answers 302 to `http://127.0.0.1/x.png` → `notAllowed`, the transport never sees the second request), `testRedirectToPublicHostIsFollowed`, `testRedirectToPrivateHostIsRejected` (302 to `http://img2.example/x.png`, which the fake resolver maps to `10.0.0.7` → `notAllowed`, nothing sent to it), `testFourthRedirectIsRejected`;
  - `testHostResolvingToMappedLoopbackIsRejected` (a fake resolver maps `img.example` to `::ffff:127.0.0.1` → `notAllowed`, no request sent), `testHostWithAnyPrivateAddressIsRejected` (`[93.184.216.34, 10.0.0.5]`);
  - `testDNSRebindingIsPinned` (the fake resolver returns `93.184.216.34` on the first call and `127.0.0.1` on any later one: the image downloads, the resolver is called exactly once, and the transport's only `PinnedRequest` has `address == "93.184.216.34"` and `tlsServerName == "img.example"`);
  - `testNon200Fails` (`204` → `http(204)`), `testNonImageContentTypeFails` (`text/html` → `notAnImage`);
  - `testDisabledDownloadsSkipURLImagesButKeepInline`, `testRefererIsPageOrigin`, `testNoCookiesSent` (the request head has no `Cookie` header), `testBudgetCancelsSlowImages` (the transport delays, with the budget injected through an internal init);
  - `PinnedHTTPClientTests.testTLSNameMismatchIsRejected`: a local `NWListener` on `127.0.0.1` with TLS serves a leaf certificate for `other.example`, signed by a test CA (both embedded as base64 constants in the test file, so `Package.swift` needs no resources); `NWPinnedTransport`, given the test CA as an extra anchor, fails with `network` for `tlsServerName == "img.example"` and succeeds for `"other.example"`;
  - in `PinnedImageFetcherTests`: `testErrorsMapToClipImageFailure` (each `PinnedHTTPError` case), `testRequestIsGetWithRefererAndAcceptImage`, `testLocalhostNeverAllowed` (the wrapper's policy refuses a host resolving to `127.0.0.1`);
  - `testConcurrencyNeverExceedsFour`, `testSniffingTable`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'PinnedHTTPClientTests|ClipImageFetcherTests|PinnedImageFetcherTests' 2>&1 | tail -20` → `Executed N tests, with 0 failures`, in under 5 s in total.
- [ ] Commit `feat(clipper): download and check clipped images through a pinned http client`.

#### Task 5: Note builder
**Files:** create `Sources/NoteIt/Clipper/ClipNoteBuilder.swift` and `Tests/NoteItTests/ClipNoteBuilderTests.swift`.
- [ ] `build`:
  1. Title paragraph (`EditorStyle.paragraph(title, kind: .title)`).
  2. Comment paragraphs (`.body`), when present.
  3. The rest per mode, in the spec's layout table:
     - the source line is `CaptureFormatter.sourceLine(linkingTo: url, label: title, appName: browser)`, from `capture-plus`; a nil `appName` (an empty `browser` is treated as nil) leaves out " in …". `CaptureFormatter` is not modified here;
     - the byline line comes from `bylineText`;
     - content is `try await ClipBodyConverter.attributedString(fromMarkdown: rewrittenMarkdown, images: images)` (T1);
     - Selection restyles `.body` paragraphs to `.quote` with `EditorStyle.paragraphStyle(for: .quote)` and puts the source line last, after an empty paragraph, as `CaptureFormatter.body` does;
     - Bookmark: the description as a body paragraph, then the preview image if saved.
  4. The tag line, if any tags survive normalisation.
  5. `shortenedNotice` when `clip.shortened`.

  Finish with `NoteItTextView.normalize`.
- [ ] `normalizedTag`: trim, drop a leading `#`, spaces → `-`, keep only characters that `NoteStore.parseTags("#" + tag)` returns unchanged. Check the result with `parseTags` and return nil if it doesn't round-trip.
- [ ] `bylineText`: `By <byline> · <long date>`, either part optional. `publishedAt` is parsed as an ISO 8601 date or date-time and shown with `.dateTime.day().month(.wide).year()` in the user's locale. Unparseable dates are dropped.
- [ ] Tests:
  - per mode: `testArticleLayout`, `testSelectionMatchesCaptureLayout` (compare with `CaptureFormatter.body` for a plain-text selection), `testPageLayout`, `testScreenshotHasOneAttachment`, `testBookmarkWithDescriptionAndImage`, `testImageMode`;
  - `testTagsBecomeParseableHashtags` (`"Read Later"` → `#read-later`, `"#c++"` → `#c`), `testNoteTitleIsTheOnlyTitleParagraph`, `testShortenedNotice`, `testNoteMetaTitleAndTags` (create through `NoteStore.applyDerivedFields`).
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipNoteBuilderTests 2>&1 | tail -20` → `Executed N tests, with 0 failures`.
- [ ] Commit `feat(clipper): build notes from clips`.

#### Task 6: Clip service and route
**Files:**
- Create `Sources/NoteIt/Clipper/ClipService.swift`, `Sources/NoteIt/Clipper/ClipsRoute.swift` and `Tests/NoteItTests/ClipServiceTests.swift`.
- Modify `Sources/NoteIt/App/AppDelegate.swift`, where the Local API starts (from `automation`).

Steps:
- [ ] `save`:
  1. Check the idempotency cache, keyed by `clientClipID`, entries younger than 10 minutes, at most 50.
  2. `validated()`.
  3. Resolve the notebook: given and missing → `notebookNotFound`; a notebook the user can only read (sharing) → `notebookReadOnly`; nil → `store.defaultNotebookIDForNewNotes`.
  4. If the store isn't loaded yet (the store's existing initialised flag), wait up to 10 s, then `libraryUnavailable` (`503 not_ready`).
  5. Fetch images.
  6. Name the saved ones `clip-image-<n>.<ext>` in request order and keep them in memory.
  7. Rewrite, build (T5, through `NoteItMarkdown`), then create the note through the store API, `store.createNote(in:initial:)`. A conversion error is `conversionFailed`.
  8. Cache and return the response, and call `notify`.

  One clip runs at a time: a simple async lock (a FIFO of continuations) on the service.
- [ ] `showNotice`: `CaptureToastController.shared.show(_ content: CaptureToastContent, onEvent: @escaping (CaptureToastEvent) -> Void)` takes a required `onEvent` closure. Call it as `CaptureToastController.shared.show(CaptureToastContent(symbol: "tray.and.arrow.down", tone: .success, title: "Clipped to \(name)"), onEvent: { _ in store.reveal(response.noteID); WindowRouter.showMainWindow() })`, so a click on the notice opens the clipped note in the main window. Skipped when `NSApp.isActive`.
- [ ] `ClipsRoute.register`: `registry.register(spec) { await handle($0, service:) }` with route id `web-clipper.clips`, then `registry.addCapability(ClipsRoute.capability)`. `handle` decodes `context.request.body` off the main actor, calls `service.save`, and answers `HTTPResponse.json(response, status: 201)`. Errors use `let mapped = ClipsRoute.apiError(for: error)` (it returns `(code: APIErrorCode, message: String)`), then `return HTTPResponse.error(mapped.code, mapped.message)`, with codes from `APIErrorCode` only; a decoding error → `.badRequest` "The clip couldn't be read.", `notebookReadOnly` → `.readOnly`, `libraryUnavailable` → `.notReady` with the message "Your library is still opening. Try again in a moment.". Auth, scope, origin, CORS, rate limits and the 60 MB body limit are the server's.
- [ ] This task edits no `automation` code. `LocalAPIRouteRegistry.register` and `addCapability` come from foundations task 5.2, and `APIErrorCode.readOnly` and `.notReady` from program §10; if they haven't landed in `NoteItAPI`, this task waits for them.
- [ ] Register the route in `AppDelegate` at launch, before the Local API starts (`automation`'s §6.11 registers at launch).
- [ ] Tests (`ClipServiceTests`, a real `NoteStore` in a temporary library like `MarkdownImporterTests`, and a fake `ClipImageFetching`):
  - `testSavesToDefaultNotebook`, `testSavesToChosenNotebook`, `testUnknownNotebookFails`;
  - `testRepeatedClientClipIDReturnsFirstResult` (one note in the store), `testIdempotencyExpiresAfterTenMinutes` (injected `now`);
  - `testSavedImageIsInTheNoteBody`, `testImageCountsInResponse`, `testClipsRunOneAtATime`, `testLibraryNotReadyIsNotReady503` (the message is exactly "Your library is still opening. Try again in a moment."), `testReadOnlyNotebookIsReadOnly403`;
  - `testErrorMapping` for `ClipsRoute.apiError` (every `ClipServiceError` case), `testSpecMatchesSpecTable` (route id `web-clipper.clips`, method, pattern, scope, body limit), `testRegisterAddsWebClipperCapability` (a fresh registry lists `"web-clipper"` in its capabilities).
- [ ] Verify:
  - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClipServiceTests 2>&1 | tail -20` → `Executed N tests, with 0 failures`; `swift build -c release 2>&1 | tail -3` → `Build complete!`, exit 0.
  - Manual: run the debug app with `NOTEIT_DATA_DIR=.selftest/clip`, turn on the Local API and make a token with `write` scope (`automation`'s UI). `curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' --data @clipper/test/fixtures/clip-article.json http://127.0.0.1:47600/v1/clips` returns 201 (use the port shown in Settings › Integrations). The note shows the title, source line, headings, a table and a downloaded image. Delete `.selftest/clip`.
- [ ] Commit `feat(clipper): accept clips through the Local API`.

### Milestone 2 — Extension for Chrome, Edge, Brave and Firefox

Ships on its own: side-loaded or store builds clip into NoteIt with pairing.

#### Task 7: Extension scaffold
**Files:** create `clipper/package.json`, `tsconfig.json`, `vitest.config.ts`, `.gitignore`, `manifest/*.json`, `scripts/build.mjs`, `src/shared/ext.ts`, `src/shared/constants.ts`, `icons/*` and `test/manifest.test.ts`.
- [ ] Scripts:
  - `build` (all targets), `build:chrome`, `build:firefox`, `build:safari`;
  - `typecheck` (`tsc --noEmit`), `test` (`vitest run`);
  - `lint:firefox` (`web-ext lint --source-dir dist/firefox`), `package` (T18).

  `"packageManager": "pnpm@10"`, `"engines": { "node": ">=24" }`.
- [ ] Manifests per spec §1 and §2:
  - `action.default_popup`, `options_ui.page`;
  - `commands`: `_execute_action` `{ default: "Alt+Shift+S", mac: "MacCtrl+Shift+S" }`, `quick-clip` `{ default: "Alt+Shift+A", mac: "MacCtrl+Shift+A" }`;
  - icons, `name` "NoteIt Clipper", description "Save articles, selections, pages, screenshots and bookmarks to NoteIt on your Mac."
- [ ] `build.mjs`: esbuild bundles `background`, `content/extract`, `content/toast`, `popup`, `options` as IIFE ES2022. It merges the manifests, copies HTML/CSS/icons and writes `dist/<target>/`. No source maps in store builds.
- [ ] `ext.ts`: `export const ext = (globalThis as any).browser ?? (globalThis as any).chrome`, with typed wrappers for the APIs used.
- [ ] Icons: render `design/assets/logo/noteit-mark.svg` to PNG with `rsvg-convert` or `sips` once, and commit the PNGs.
- [ ] `manifest.test.ts`: for each target, permissions are exactly `["activeTab","contextMenus","scripting","storage"]` and there are no `host_permissions`, `optional_host_permissions` or `content_scripts`; both commands' `mac` keys are `MacCtrl+Shift+S` and `MacCtrl+Shift+A` (Control, not `Ctrl`, which is ⌘ on a Mac); the Firefox gecko id and minimum versions are set; the version equals `package.json`.
- [ ] Verify: `pnpm --dir clipper install && pnpm --dir clipper typecheck && pnpm --dir clipper test && pnpm --dir clipper build && pnpm --dir clipper lint:firefox` → all pass. `ls clipper/dist` → `chrome firefox safari`.
- [ ] Commit `build(clipper): scaffold the web extension`.

#### Task 8: HTML to Markdown and URL helpers (parallel with T9)
**Files:** create `clipper/src/convert/markdown.ts`, `images.ts`, `url.ts`, `browser.ts`, `test/markdown.test.ts`, `test/images.test.ts`, `test/url.test.ts`, `test/browser.test.ts` and `test/fixtures/*.html`.
- [ ] Turndown with the spec's options and rules: heading demotion, `img`/`picture` → `noteit-image:` with the image list, code language, unsafe links, video embeds, the 2-px tracking pixel drop, the 50-image cap, and cutting at 1,000,000 characters at a block boundary.
- [ ] `images.ts`: srcset parsing (`w` and `x` descriptors; the largest at most 2000 w, else the largest), lazy attributes, absolute URLs against `baseURI`, deduplication by URL (the same URL reuses its id), `data:` image bytes as base64 up to 10 MB.
- [ ] `url.ts`: `cleanURL` removes the spec's tracking parameters and keeps everything else, including the fragment.
- [ ] `browser.ts`:
  - Safari or Firefox by build target.
  - Chromium: `navigator.brave?.isBrave()` → Brave, then `userAgentData.brands` (Google Chrome, Microsoft Edge, Opera, Vivaldi). Arc via the `--arc-palette-title` CSS variable check.
  - Otherwise undefined.
- [ ] Tests: the fixtures convert to expected Markdown snapshots (committed `.md` files next to the fixtures), plus one unit test per rule, `cleanURL` table tests, and `browserName` with faked navigators.
- [ ] Verify: `pnpm --dir clipper test` → all pass.
- [ ] Commit `feat(clipper): convert pages to Markdown`.

#### Task 9: Local API client, storage and messages (parallel with T8)
**Files:** create `clipper/src/api/types.ts`, `errors.ts`, `client.ts`, `discover.ts`, `src/shared/storage.ts`, `src/shared/messages.ts`, `test/client.test.ts` and `test/discover.test.ts`.
- [ ] `LocalApiClient` per the frozen interface: `AbortController` timeouts, `Authorization: Bearer` on authenticated calls, `Content-Type: application/json` on JSON bodies, `X-NoteIt-Extension-Bundle: <extensionBundle>` on every request (pairing included) when `extensionBundle` is set, which the Safari build does with `SAFARI_EXTENSION_BUNDLE_ID`, and no other headers (the API's CORS allow-list), the base URL `http://127.0.0.1:${port}`. Parse `automation`'s nested error body and map to `ApiError` kinds exactly as in spec §5, including `403 read_only` → `notebookReadOnly`. A `TypeError` from fetch, or a timeout, is `unreachable`.
- [ ] `findPort`: a fixed port is used as is; otherwise try `preferred` first, then 47600 to 47609 in order, each `ping` with a 1 s timeout, and accept only `name === "NoteIt"`.
- [ ] `storage.ts`: typed `getConnection`/`setConnection`/`clearConnection`, `getPrefs` (`defaultMode`, `downloadImages: true`, `rememberTags: false`, `port`) and `getRecent` (`notebookID`, `tags`), all in `storage.local`.
- [ ] `messages.ts`: a discriminated union of the requests and replies from spec §3, and a `send()` helper with typed replies.
- [ ] Tests with a fake `fetch`: each error mapping from spec §5, only the allowed headers present, `X-NoteIt-Extension-Bundle` on every request including `pair/start` and `pair/complete` when `extensionBundle` is set and absent otherwise, timeouts, `pairingCancelled` on `403 pairing_failed`, `notReady` on `503 not_ready`, `appTooOld` when `capabilities` lacks `"web-clipper"` (a `ping` with only an old `features` field is also `appTooOld`), `saveClip` posting the exact JSON shape, and `findPort` skipping a port held by something that isn't NoteIt.
- [ ] Verify: `pnpm --dir clipper test` → all pass.
- [ ] Commit `feat(clipper): add the Local API client`.

#### Task 10: Content extractors and in-page notice
**Files:** create `clipper/src/content/extract.ts`, `article.ts`, `selection.ts`, `page.ts`, `bookmark.ts`, `toast.ts`, and `test/article.test.ts`, `selection.test.ts`, `page.test.ts`, `bookmark.test.ts`.
- [ ] Implement each mode exactly per spec §4. `extract` races the work against `EXTRACT_TIMEOUT_MS` and returns a `ClipDraft`. Article falls back to Page and sets a `fellBack` flag for the popup's message.
- [ ] `page.ts` marks hidden elements on the live DOM with `data-noteit-hidden`, clones, and removes the marks from the live DOM in `finally`.
- [ ] `toast.ts`: a closed shadow root at `position: fixed; top: 12px; right: 12px; z-index: 2147483647`. The text and the optional action button come from the message. It fades after 3 s, or 8 s for errors, and stays while hovered. Only one notice at a time.
- [ ] Tests on jsdom fixtures:
  - an article with byline and date;
  - a page with no article (falls back);
  - a multi-range selection, and a selection inside a textarea;
  - a page with hidden navigation;
  - bookmark metadata precedence (`og:` over `meta`);
  - the description cut at 500 characters.
- [ ] Verify: `pnpm --dir clipper test` → all pass.
- [ ] Commit `feat(clipper): extract articles, selections, pages and bookmarks`.

#### Task 11: Background: save flow, context menu, commands
**Files:** create `clipper/src/background/index.ts`, `menus.ts`, `commands.ts`, `save.ts` and `badge.ts`.
- [ ] `menus.ts`: on `runtime.onInstalled`, create the parent **NoteIt** and the spec's items with the right `contexts` (`page`, `selection`, `link`, `image`). Clicks map to modes; links become bookmarks of `linkUrl` with `selectionText` or the link text as the title.
- [ ] `save.ts`:
  1. `prepare(tab, mode)`: for screenshot, `tabs.captureVisibleTab(tab.windowId, { format: "png" })`; for image, a draft from `srcUrl`; otherwise `scripting.executeScript({ target: { tabId, allFrames: mode === "selection" }, files: ["content/extract.js"] })`, then call `extract`. Scripting errors fall back to a bookmark from `tab.title`/`tab.url`, with `restricted: true`.
  2. `save(draft, choices)`: builds `ClipRequest` with `crypto.randomUUID()`, `cleanURL`, `browserName`, then `saveClip`, and stores `recent`.
- [ ] `commands.ts`: `quick-clip` runs prepare (automatic mode) and save with the recent notebook, then shows the toast through `scripting.executeScript(files: ["content/toast.js"])`, or the badge on restricted pages.
- [ ] `badge.ts`: a green check mark for 2 s / `!` red until clicked. A click after a failure opens the popup with the stored error (`action.openPopup` where supported; otherwise the badge stays and the popup reads `lastError` on open).
- [ ] The background handles every `messages.ts` request. Pairing state (`pairingID`) lives in memory, keyed by the popup's port connection. An `unauthorized` error in any browser keeps the prepared clip and shows **Connect Again**. There is no Safari-specific re-pairing: `automation` binds Safari extension tokens by the origin scheme plus the extension's bundle identifier, which the Safari build sends in `X-NoteIt-Extension-Bundle`, so they survive Safari restarts.
- [ ] Before each request the background resolves the port with `findPort({ preferred: connection.port, fixed: prefs.port })` and saves a changed port to `connection`.
- [ ] Verify: `pnpm --dir clipper typecheck && pnpm --dir clipper build` → pass. Manual in Chrome (load unpacked `clipper/dist/chrome`) against the debug app from T6: each context menu item creates the expected note, and the toast appears.
- [ ] Commit `feat(clipper): save clips from the context menu and shortcut`.

#### Task 12: Popup and options page
**Files:** create `clipper/src/popup/popup.html`, `popup.css`, `popup.ts`, `state.ts`, `tags.ts`, `src/options/options.html`, `options.css`, `options.ts` and `test/state.test.ts`.
- [ ] `state.ts`: a pure reducer over the states `connect`, `pairing`, `unreachable`, `appTooOld`, `form`, `saving`, `saved`, `error`, with the events from the background. Unit test every transition, including:
  - unreachable → open app → poll succeeds → form, with the inputs kept;
  - unauthorized → connect, with the draft kept;
  - notebookGone and notebookReadOnly → form with notebooks reloaded and the message.
- [ ] `popup.ts`:
  - On open: `ping()` (through the background's port lookup), then `notebooks()` and `tags()` in parallel, and `prepare` for the starting mode (selection > article if readerable > bookmark, or the options default).
  - Mode buttons re-run `prepare`. ⌘↩ saves and Esc closes.
  - Polling after **Open NoteIt** runs every second for 20 s. **Open NoteIt** sends `openApp`, which calls `tabs.update(tabId, { url: "noteit://settings?tab=integrations" })`.
- [ ] `tags.ts`: a chip input with autocomplete (prefix match first, then substring, at most 8 suggestions); Return or comma adds.
- [ ] CSS follows the app's tokens (`Sources/NoteIt/Design/Tokens.swift` colours), light and dark with `prefers-color-scheme`, 360 px wide, every control labelled for VoiceOver.
- [ ] Options page: Connection (Connect/Disconnect), Default clip, Save images in the note, Remember last tags, Advanced › Port, Shortcuts (Chrome links to `chrome://extensions/shortcuts`; Firefox explains **Manage Extension Shortcuts**), and the privacy line.
- [ ] Confirm in Chrome, Firefox and Safari that the background `fetch` to `http://127.0.0.1` succeeds with no host permission (CORS from `automation`). If one browser blocks it, add `"optional_host_permissions": ["http://127.0.0.1/*"]` for that target only, request it from the **Connect** click, update `manifest.test.ts` and the spec's Permissions section.
- [ ] Verify: `pnpm --dir clipper test` → pass. Manual in Chrome and Firefox (`web-ext run`): connect with a code, a wrong code twice, every mode, the saved state's **Open in NoteIt**, the unreachable flow with the app quit, Disconnect (the browser disappears from **Connected apps** in Settings › Integrations), and pairing while another app is pairing (`pairingBusy`).
- [ ] Commit `feat(clipper): add the popup and options page`.

#### Task 13: End-to-end pass and review
- [ ] Clip each mode on five real sites (a news article, a docs page with code and tables, a blog with lazy images, a page with a selection inside an iframe, a PDF tab) in Chrome, Edge, Brave and Firefox. Record the results in the PR description.
- [ ] Review the diff for correctness and security, in particular: the host and address rules (redirects, DNS resolution, the pinned address and TLS server name, IPv4-mapped IPv6), token handling (never logged, never in `storage.sync`), extraction cleanup on the live DOM, and the idempotency of retries. Fix what's found.
- [ ] Verify: `pnpm --dir clipper test`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5` → all pass.
- [ ] Commit any fixes as `fix(clipper): …`.

### Milestone 3 — Safari

Ships on its own: NoteIt.app carries the Safari clipper. If the T14 spike fails, this milestone is held back, `release.yml` gets no clipper steps, and `docs/known-limitations.md` says Safari isn't supported yet; milestones 1, 2 and 4 still ship.

#### Task 14: Safari app extension, built with swiftc (spike first)
**Files:**
- Modify `Package.swift`.
- Create `Sources/NoteItClipperExtension/SafariWebExtensionHandler.swift`, `Resources/NoteItClipperExtension.entitlements` and `scripts/build_safari_extension.sh`.

Steps:
- [ ] Handler:
  ```swift
  import Foundation
  final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
      func beginRequest(with context: NSExtensionContext) {
          let item = NSExtensionItem()
          item.userInfo = ["message": ["error": "unsupported"]]   // SFExtensionMessageKey
          context.completeRequest(returningItems: [item])
      }
  }
  ```
  Use `@objc(SafariWebExtensionHandler)` only if the principal class name doesn't resolve as `NoteItClipperExtension.SafariWebExtensionHandler`.
- [ ] `Package.swift`, for type-checking only (program §1): a plain `.target(name: "NoteItClipperExtension", path: "Sources/NoteItClipperExtension", swiftSettings: [.unsafeFlags(["-application-extension"])])`, with no product and nothing depending on it. Its SwiftPM output is never packaged. Also add `linkerSettings: [.linkedFramework("SafariServices")]` to `NoteIt`.
- [ ] `build_safari_extension.sh`, the embeds row's build step and the one way the appex binary is built:
  1. Honour `NOTEIT_SKIP_CLIPPER` and `NOTEIT_REQUIRE_CLIPPER`.
  2. Compile `Sources/NoteItClipperExtension/*.swift` with `xcrun swiftc -O -application-extension -module-name NoteItClipperExtension -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension -target <arch>-apple-macos14.0` for each architecture the app is built for, then `lipo` when `NOTEIT_UNIVERSAL=1`.
  3. Build `clipper/dist/safari` with `pnpm --dir clipper install --frozen-lockfile && pnpm --dir clipper build:safari` when it's missing.
  4. Create `$BIN_DIR/NoteItClipper.appex/Contents/{MacOS,Resources}` (the row's source; the embeds table copies it into `Contents/PlugIns/`) and copy the binary and `dist/safari/*`.
  5. Write the Info.plist with `plutil`, the same way `build_app.sh` does, with the spec's keys and the app's version numbers. Run `plutil -lint`.
  6. Never sign; signing is the embeds table's job (T15).
- [ ] Spike, before anything else in this milestone, and record the outcome in the commit message:
  - the script's binary has `_NSExtensionMain` as its entry (`otool -l … | grep -A3 LC_MAIN`);
  - signed ad-hoc inside-out with its entitlements and loaded into a scratch app, Safari (with **Allow Unsigned Extensions**) lists **NoteIt Clipper** and the extension's popup opens.

  If it fails, stop here and hold the milestone back as described above.
- [ ] Verify: `swift build -c release 2>&1 | tail -3` → `Build complete!` (the target type-checks). Running the script with a scratch `BIN_DIR` produces `NoteItClipper.appex` there, and `plutil -p` shows the `NSExtension` keys.
- [ ] Commit `build(clipper): build the Safari app extension with swiftc`.

#### Task 15: Add the appex to the embeds table
**Files:** modify `scripts/build_app.sh` (one row in foundations' embeds table) and `docs/development.md`.
- [ ] Add the row with program §10's columns: path in bundle `Contents/PlugIns/NoteItClipper.appex`; source `NoteItClipper.appex`; build step `scripts/build_safari_extension.sh`; entitlements file `Resources/NoteItClipperExtension.entitlements`. As a row string that is `"Contents/PlugIns/NoteItClipper.appex|NoteItClipper.appex|scripts/build_safari_extension.sh|Resources/NoteItClipperExtension.entitlements"`. Signing order isn't a column: the table signs inside-out without `--deep`, the appex before the main app, which is signed last and isn't a row. Nothing else in `build_app.sh` changes. Signing works the same for ad-hoc and Developer ID builds, with the same identity, hardened runtime and timestamp as the app.
- [ ] `NOTEIT_UNIVERSAL=1` must produce a universal appex binary too (`lipo -info`).
- [ ] `docs/development.md`: document `NOTEIT_SKIP_CLIPPER` and `NOTEIT_REQUIRE_CLIPPER`, that the Node/pnpm requirement is only for the clipper, and **Safari › Develop › Allow Unsigned Extensions** for ad-hoc builds.
- [ ] Verify:
  - `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` → last line `==> Done: ` followed by the absolute path ending in `/.selftest/app/NoteIt.app`, exit 0.
  - `codesign --verify --deep --strict .selftest/app/NoteIt.app` → no output, exit 0.
  - `codesign -d --entitlements - .selftest/app/NoteIt.app/Contents/PlugIns/NoteItClipper.appex` shows `app-sandbox`.
  - `NOTEIT_HARDENED_RUNTIME=1 NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` passes too (exit 0, and both `codesign` checks above pass again).
  - Launch the app, enable unsigned extensions in Safari, and **NoteIt Clipper** appears in Safari › Settings › Extensions. It connects and clips one article.
  - Delete `.selftest/app`.
- [ ] Commit `build(clipper): add the Safari clipper to the embeds table`.

#### Task 16: Web Clipper settings section and palette command (parallel with T15)
**Files:**
- Create `Sources/NoteIt/Clipper/SafariClipperStatus.swift` and `Sources/NoteIt/Clipper/WebClipperSettingsSection.swift`.
- Modify `Sources/NoteIt/Settings/IntegrationsSettingsView.swift` (created by `automation`), `Sources/NoteIt/Palette/PaletteCommandRegistry.swift` and `Tests/NoteItTests/PaletteCommandRegistryTests.swift`.

Steps:
- [ ] `SafariClipperStatus.state()` wraps `SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier:)` in a continuation: an error → `.unavailable`, `isEnabled` → `.on`/`.off`. It refreshes when the Settings window becomes key.
- [ ] The section after **Connected apps** in `IntegrationsSettingsView`, the Integrations tab (raw value `integrations`, program §9): header "Web Clipper"; the Safari row with the state text and **Open Safari Extensions…**; two link rows; the footnote from the spec.
- [ ] Palette: `command("setUpWebClipper", "Set Up Web Clipper…", symbol: "globe", shortcut: nil, keywords: ["browser", "extension", "safari", "chrome", "firefox", "clip"])`, which calls `SettingsTabRouter.show(.integrations)`.
- [ ] Tests: `PaletteCommandRegistryTests.testWebClipperCommandIsListed`. `SafariClipperStatus` is thin and checked manually.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaletteCommandRegistryTests 2>&1 | tail -20` → `Executed N tests, with 0 failures`. A window-only screenshot of Settings › Integrations in light and dark, viewed and polished.
- [ ] Commit `feat(clipper): add Web Clipper settings and palette command`.

### Milestone 4 — CI, releases, stores, docs

#### Task 17: CI
**Files:** modify `.github/workflows/ci.yml`.
- [ ] New job `clipper` on `ubuntu-latest`, the browser-extension job program §1 allows; the extension's tests run only here: checkout, `pnpm/action-setup@v4`, `actions/setup-node@v4` (Node 24, pnpm cache from `clipper/pnpm-lock.yaml`), then `pnpm --dir clipper install --frozen-lockfile`, `typecheck`, `test`, `build`, `lint:firefox`.
- [ ] `build-and-test` (macOS), only once the T14 spike has passed: add Node and pnpm setup, `pnpm --dir clipper install --frozen-lockfile && pnpm --dir clipper build:safari`, then `NOTEIT_INSTALL_DIR="$RUNNER_TEMP/apps" NOTEIT_REQUIRE_CLIPPER=1 ./scripts/build_app.sh`, then check `test -x "$RUNNER_TEMP/apps/NoteIt.app/Contents/PlugIns/NoteItClipper.appex/Contents/MacOS/NoteItClipperExtension"`.
- [ ] Verify: push a branch, and both jobs pass on GitHub.
- [ ] Commit `ci: build and test the web clipper`.

#### Task 18: Releases and store listings
**Files:**
- Create `.github/workflows/clipper-release.yml`, `clipper/scripts/package.mjs`, `clipper/CHANGELOG.md`, `clipper/PRIVACY.md` and `clipper/store/{chrome,firefox}.md`.
- Modify `.github/workflows/release.yml` and `docs/releasing.md`.

Steps:
- [ ] `package.mjs`: zip `dist/chrome` and `dist/firefox` as `out/noteit-clipper-<target>-<version>.zip`. The source zip is `clipper/` minus `node_modules`, `dist` and `out`, plus a generated `BUILD.md` with the exact commands and Node/pnpm versions.
- [ ] `clipper-release.yml`, triggered by `push: tags: ["clipper-v*.*.*"]` and `workflow_dispatch` with `dry_run`:
  1. Check that the version matches `package.json`.
  2. Install, typecheck, test, build, lint, package.
  3. Upload the artifact.
  4. Unless dry run: create the GitHub release **NoteIt Clipper X.Y.Z** with the `clipper/CHANGELOG.md` section.
  5. The Chrome Web Store upload and publish uses its API with OAuth refresh-token secrets; skip with a notice if missing.
  6. `web-ext sign --channel=listed --upload-source-code out/noteit-clipper-source-<v>.zip`, using the AMO secrets; skip if missing.
- [ ] `release.yml`: before **Build NoteIt.app**, set up Node 24 and pnpm and run `pnpm --dir clipper install --frozen-lockfile && pnpm --dir clipper build:safari`. Add `NOTEIT_REQUIRE_CLIPPER: "1"` to the build step's env only if the T14 spike passed and T15's Safari check succeeded; otherwise leave it out (and leave the clipper steps out if milestone 3 is held back).
- [ ] Coordinate with `growth`, which also edits `release.yml` (the Pages trigger, later removing the Homebrew job). These edits land first; `growth` rebases its `release.yml` changes on top. Say so in the PR description and keep this change to the build step and the steps before it.
- [ ] `docs/releasing.md`: a "Web clipper" section covering the tag format, the secrets table (`CWS_*`, `AMO_*`), first-time store setup (developer accounts, the listing text from `clipper/store/`, permission justifications, the privacy policy link to `clipper/PRIVACY.md`), and the fact that Safari ships with the app.
- [ ] Verify: run `clipper-release.yml` with `dry_run` → the artifact holds three zips. Run `release.yml` with `dry_run` → the DMG's app contains the appex. `web-ext lint` passes on the zipped Firefox build.
- [ ] Commit `ci(clipper): release the clipper to the Chrome Web Store and AMO`.

#### Task 19: Documentation
**Files:** modify `README.md`, `docs/architecture.md`, `docs/roadmap.md`, `docs/known-limitations.md` and `docs/specs/2026-10-19-web-clipper-design.md`. Create `clipper/README.md`.
- [ ] README: "Web clipper" in the product tour (install per browser, connecting), and in the engineer section how to build `clipper/`.
- [ ] Architecture: the `Clipper/` folder, the route, and the appex packaging.
- [ ] Roadmap: add and tick **Web clipper**, linking the spec.
- [ ] Known limitations:
  - visible-area screenshots only;
  - the browser must be on the same Mac as NoteIt;
  - images that need a login can't be downloaded and are saved as links;
  - ad-hoc builds need Allow Unsigned Extensions in Safari.
- [ ] `clipper/README.md`: install, development (`pnpm dev` with esbuild watch, `web-ext run`, Chrome load unpacked), the test commands, and the permission rationale.
- [ ] Update the spec with any deviations, such as what the T14 spike found.
- [ ] Verify: links resolve (`grep -o '](.*\.md)'` in the changed files, each target exists). No local machine paths in the docs.
- [ ] Commit `docs: document the web clipper`.

## Self-review

- **Spec coverage:**
  - Modes: article, selection, page and bookmark in T10; screenshot and image in T11; layouts in T5.
  - Popup with notebook picker, tags, title edit and **Open in NoteIt**: T12. Keyboard shortcuts and context menu: T7, T11.
  - Pairing and the stored token: T9, T12. Unreachable app or API off: T9 mapping, T12 states and polling.
  - Image downloads and their limits: T4, T6. Markdown conversion through `NoteItMarkdown`: T1. Source attribution reused from `capture-plus`'s `sourceLine`: T5. Tracking parameter removal: T8.
  - Safari packaging and signing: T14, T15. Settings and palette: T16.
  - Store distribution and release CI: T17, T18. Privacy and the minimal permissions: T7 (manifest test), T18 (`PRIVACY.md`, listings).
- **Ownership:**
  - The Local API server, pairing, tokens, the notebooks, tags and open endpoints, and the URL scheme are `automation`'s; this plan only registers `/v1/clips` (route id `web-clipper.clips`), calls `addCapability("web-clipper")`, adds one row to the embeds table in `build_app.sh` and adds a section to the Integrations tab. It edits no `automation` code.
  - `CaptureFormatter.sourceLine(linkingTo:label:appName:)` is `capture-plus`'s change (its Task 7, merged before T5 in wave 2); this plan only calls it. Markdown parsing is `markdown-storage`'s `NoteItMarkdown` (`portable` flavour, `MarkdownImportOptions.resolveImage`); body files are written by `NoteBodyStorage` through `NoteStore`.
  - Image text search is `capture-plus`'s. Nested notebooks and tags are `organise`'s and are used when present.
  - The network inventory entry is `sync-security`'s.
  - `PinnedHTTPClient` and everything in `Sources/NoteIt/Net/PinnedHTTPClient.swift` is this plan's (T4), in the `NoteIt` app target. `plugins` (wave 3) uses it for `net.fetch` with its own `PinnedHTTPPolicy` and adds no transport of its own; a change to the client's shape is made here and checked against both callers.
- **Types:**
  - `ClipRequest`, `ClipImage` and `ClipResponse` are defined once in Swift (T2) and once in TypeScript (T9), and both match the spec's JSON. `ClipServiceTests` (found from the repository root through `#filePath`, as `SyncEngineTests` does) and `client.test.ts` both use the same example, `clipper/test/fixtures/clip-article.json`, created in T2.
  - `ValidatedClip` flows T2 → T5 → T6.
- **Risks:** building the appex with `xcrun swiftc` (T14 spike; if it fails, milestone 3 is held back and releases never require the clipper); a browser refusing loopback `fetch` without a host permission (T12 check, with an optional-permission fallback); `release.yml` conflicts with `growth` (these edits land first, `growth` rebases); store review time (store releases are separate from app releases). Safari's changing extension origin is handled by `automation`'s binding by origin scheme plus bundle identifier.
- **Names from `automation`:** `LocalAPIRouteRegistry`, `RouteSpec`, `LocalAPIContext`, `HTTPResponse` (built in foundations tasks 5.1–5.2), `APIErrorCode` (including `readOnly` and `notReady`), `addCapability(_:)`, `SettingsTabRouter.show(.integrations)` and the endpoint paths are taken from its spec §6.10–6.11, its plan's frozen interfaces and program §10. This plan adds no names to `automation`. Nothing else is left open.
