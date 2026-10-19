# NoteIt Private AI Implementation Plan

**Goal:** Add on-device, off-by-default smart features to NoteIt: search by meaning, "Ask your notes" with cited sources, summaries and suggested titles and tags, and an MCP server (`noteit mcp`) that lets other apps read, and optionally write, notes through the Local API.

**Architecture:** Two new library targets hold everything that can be tested without the UI:
- `NoteItSmart` (depends on `NoteItCore`): chunking, embedding (`NLContextualEmbedding`), the Int8 vector index and its file format, brute-force cosine search, Reciprocal Rank Fusion, prompt building, citation and suggestion parsing, the `TextGenerator` protocol with an Apple Foundation Models implementation (macOS 26+, compiled only when the SDK has it) and an OpenAI-compatible loopback-only implementation.
- `NoteItMCP` (depends on `NoteItAPI` and `NoteItCore`): JSON-RPC over stdio, MCP method handling for protocol versions `2026-07-28`, `2025-11-25` and `2025-06-18`, tools and resources, all against a `NotesBackend` protocol.

The app adds `Sources/NoteIt/Smart/` (settings model, controller, indexer, search model, Ask panel, note actions, capture title refiner, MCP setup sheet), a Smart Features settings tab, palette and menu wiring, and `NoteStore+Smart.swift`. The semantic indexer is a `DerivedIndex`; note text is read through `NoteBodyStorage` and changed through `NoteStore.editBody`. The `NoteItCLI` target from `automation` gains its `NoteItMCP` dependency, the `noteit mcp` command tree and a `LocalAPIBackend` in T19, in wave 2.

**Tech stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftPM, SwiftUI/AppKit, NaturalLanguage, Accelerate, FoundationModels (optional, `#if canImport`), URLSession. No third-party dependencies. Tests use XCTest via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

**Spec:** `docs/specs/2026-10-19-private-ai-design.md`

**Prerequisites:** this is a wave 2 sub-project. Everything needs foundations (wave 0): `NoteItCore`, `NoteBodyStorage`, `NoteStore.editBody`, the `DerivedIndex` registry, `NoteMeta.isLocked` (data only), the frozen shortcut, hotkey, Settings tab and menu tables, and the `NoteItAPI` target with `LocalAPIRouteRegistry` (foundations 5.1, 5.2; `NoteLink` is in `NoteItCore` from 5.3). `editBody` (4.5) and the `DerivedIndex` registry (4.4) are built by foundations with the shapes `organise` owns; this plan only consumes them. T8 rebases on `organise`'s `PaletteRanker` change (`bodyMatches: [UUID: Double]`), which merges first. M4 (MCP) needs `automation`'s `NoteItCLI` target, `NoteItAPIClient`, `AutomationService.clients` and the endpoints listed under *Dependencies* in the spec. Where `automation` has not merged yet, M4 tasks T17–T18 can be built and tested against `NotesBackend` fakes; T19–T20 wait for it.

---

## Conventions for every task

- Test command (from the repository root): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite> 2>&1 | tail -20`.
- App build: `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3` both end with `Build complete!` and 0 errors. Build once with an SDK that lacks FoundationModels (CI's default Xcode on macos-15) to prove the `#if canImport` guards: the CI run on the PR covers this.
- Never touch real user data in `~/Library/Application Support/NoteIt`. When running the app, set `NOTEIT_DATA_DIR="$PWD/.selftest/<name>"` (run from the repository root; `<name>` is any folder name) (gitignored).
- Tests never download model assets or call a model. They use `HashEmbedder` and `ScriptedGenerator` from `Tests/NoteItSmartTests/Support/`. The one live embedding test skips itself (`XCTSkip`) when `NLContextualEmbedding` has no assets.
- Never log note text, questions, answers or embeddings. Log counts, timings and error codes.
- Pure logic goes in `NoteItSmart` / `NoteItMCP`; app files stay thin. Everything the app or CLI uses is `public` and `Sendable`-correct.
- Commit after each task with Conventional Commits, scope `smart` or `mcp`, e.g. `feat(smart): add chunker`. Never amend, rebase or force.
- No `#Preview`. Comments only where something is non-obvious.

## File structure

```
Package.swift                                         (modify: + NoteItSmart (depends on NoteItCore) and NoteItMCP (depends on NoteItAPI, NoteItCore)
                                                       libraries and their test targets; NoteIt depends on NoteItSmart and NoteItMCP;
                                                       platforms unchanged; NoteItCLI gains NoteItMCP in T19, not here)
Sources/NoteItSmart/
  Text/Chunker.swift                                  Chunk, Chunker (version 1)
  Embedding/TextEmbedder.swift                        TextEmbedder protocol, EmbedderIdentity, EmbedderError
  Embedding/NLContextualTextEmbedder.swift            NLContextualEmbedding, mean pooling, L2 normalization, asset requests
  Embedding/LanguagePicker.swift                      dominant language of a text sample
  Index/VectorMath.swift                              normalize, quantize/dequantize (Int8 + scale), blocked dot products (Accelerate)
  Index/IndexManifest.swift                           manifest.json Codable types
  Index/VectorFile.swift                              vectors-<gen>.bin reader/writer (header, rows, append)
  Index/SemanticIndex.swift                           actor: load, upsert, remove, search, neighbours, baseline, compaction
  Ranking/HybridRanker.swift                          note hits from chunk hits, RRF fusion, MatchSources
  Generation/TextGenerator.swift                      protocol, GenerationRequest, GeneratorAvailability, GenerationError, TokenEstimate
  Generation/LoopbackPolicy.swift                     URL and model-name checks
  Generation/OpenAICompatibleGenerator.swift          /models, /chat/completions with SSE, proxy-free ephemeral session
  Generation/SSEParser.swift                          server-sent events line parser
  Generation/AppleTextGenerator.swift                 #if canImport(FoundationModels), @available(macOS 26.0, *)
  Ask/AskPromptBuilder.swift                          AskExcerpt, AskPrompt, budgeted prompt
  Ask/AnswerParser.swift                              citation segments, NO_ANSWER
  Ask/AskRetriever.swift                              candidate selection (semantic + keyword), relevance gate
  Writing/WritingPrompts.swift                        summary, combine, titles, tags requests
  Writing/SuggestionParser.swift                      titles, tags (TagSuggestion)
  Writing/NeighborTags.swift                          tags from similar notes
  Writing/Summarizer.swift                            single-pass and map-reduce summary orchestration
Sources/NoteItMCP/
  JSONValue.swift                                     JSON value enum (Codable)
  JSONRPC.swift                                       request/response/notification/error types, line framing
  MCPProtocol.swift                                   versions, server info, discover/initialize results
  NotesBackend.swift                                  protocol + value types + BackendError
  MCPTools.swift                                      tool definitions, schemas, argument validation, result mapping
  MCPResources.swift                                  resources/list, templates, read
  MCPConfigSnippet.swift                              config snippets for Claude Desktop, VS Code, Cursor, other; profile name rule
  MCPServer.swift                                     actor: handle(line:), run(input:output:), cancellation
Sources/NoteIt/
  Smart/SmartSettings.swift                           @MainActor ObservableObject over PrefKey values; generator factory
  Smart/SmartController.swift                         settings observation, availability, turn on/off, status text; storeDidOpen(_:) creates and registers the indexer, storeWillClose() drops it
  Smart/SemanticIndexer.swift                         DerivedIndex conformance, queue, batches, pausing, baseline refresh
  Smart/SmartSearchService.swift                      related(query:scope:), hybrid(query:limit:) for the list, palette, Ask, Local API
  Smart/SmartSearchModes.swift                        registerSearchMode for meaning and hybrid; addCapability/removeCapability("meaning-search")
  Smart/SemanticSearchModel.swift                     debounced Related results for NoteListView
  Smart/AskModel.swift                                question → retrieval → stream → parsed answer; save/copy
  Smart/AskPanel.swift                                NSPanel controller (like PalettePanel)
  Smart/AskView.swift                                 question field, scope popup, answer with chips, sources
  Smart/SmartNoteActions.swift                        summarize, suggest title/tags, related notes, add tag (all edits via editBody)
  Smart/SmartNoteViews.swift                          sparkles menu, summary/title/related popovers, tag chip row
  Smart/SmartCaptureTitleRefiner.swift                capture-plus's CaptureTitleRefining, backed by Suggest Title
  Smart/MCPSetupSheet.swift                           app picker, access level, snippet, copy; presented from Settings › Integrations
  Model/NoteStore+Smart.swift                         semanticIndexURL, indexingTexts(for:) via NoteBodyStorage, liveIndexableNotes, revision lookups
  Settings/SmartSettingsView.swift                    Smart Features tab
  App/SmartCommands.swift                             AskNotesMenuItem, placed in the Edit menu's Find group
  (modify) Settings/SettingsView.swift                Tab.smart (raw value `smart`, position 7, symbol sparkles)
  (modify) Settings/Preferences.swift                 PrefKey/PrefDefault smart keys
  (modify) Settings/ShortcutsSettingsView.swift       askNotes tile in the HotkeyAction switch
  (modify) App/MenuShortcuts.swift                    MenuShortcutCommand.askNotes (⌥⌘A), MenuShortcutRules
  (modify) App/NoteItApp.swift                        AskNotesMenuItem in the textEditing (Find) command group
  (modify) App/AppDelegate.swift                      HotkeyAction.askNotes handler; SmartController.shared.start() at launch; storeDidOpen(NoteStore.shared) in the store-open step
  (modify) Hotkeys/HotkeyAction.swift                 case askNotes at frozen position 12
  (modify) Sync/Keychain.swift                        Account.smartLocalServerKey
  (modify) Palette/PaletteRanker.swift                PaletteMode.ask, PaletteItemKind.ask, related items (on organise's bodyMatches signature)
  (modify) Palette/PaletteModel.swift                 related results, ask activation
  (modify) Palette/PaletteView.swift                  placeholder text for ask mode
  (modify) Palette/PaletteCommandRegistry.swift       smart commands
  (modify) Views/NoteListView.swift                   Related section
  (modify) Views/EditorContainerView.swift            sparkles menu in EditorHeader, tag chip row
  (modify) Editor/RichTextEditor.swift                pendingSelection
Sources/NoteItCLI/                                    (target from automation; bundled as Contents/Helpers/noteit)
  MCPCommand.swift                                    `noteit mcp`, `noteit mcp setup`, `noteit mcp store-token`
  LocalAPIBackend.swift                               NotesBackend over NoteItAPIClient
Tests/NoteItSmartTests/
  Support/HashEmbedder.swift, Support/ScriptedGenerator.swift, Support/StubURLProtocol.swift
  ChunkerTests, VectorMathTests, VectorFileTests, SemanticIndexTests, HybridRankerTests, LoopbackPolicyTests,
  SSEParserTests, OpenAICompatibleGeneratorTests, AskPromptBuilderTests, AnswerParserTests, AskRetrieverTests,
  SuggestionParserTests, NeighborTagsTests, SummarizerTests, NLContextualEmbedderLiveTests
Tests/NoteItMCPTests/
  Support/FakeNotesBackend.swift
  JSONRPCTests, MCPProtocolTests, MCPToolsTests, MCPResourcesTests, MCPConfigSnippetTests, MCPServerTests
Tests/NoteItTests/
  SemanticIndexerTests, PaletteRankerTests (extend), SmartSettingsTests, AskModelTests, SmartNoteActionsTests, SmartSearchModesTests
docs/architecture.md, docs/keyboard-shortcuts.md, docs/known-limitations.md, docs/roadmap.md, README.md   (modify)
```

## Frozen interfaces

```swift
// NoteItSmart/Text/Chunker.swift
public struct Chunk: Sendable, Equatable {
    public var index: Int
    public var range: Range<Int>          // UTF-16 offsets into the normalized note text
    public var text: String               // shown to the user and put in prompts
    public var embeddingText: String      // "<title>\n<text>"
}
public enum Chunker {
    public static let version = 1
    public static let maxWords = 180
    public static let maxCharacters = 1_000
    public static let overlapMaxWords = 30
    public static let maxChunksPerNote = 64
    public static let minWords = 3
    public static func normalize(_ text: String) -> String            // drops U+FFFC, collapses spaces, keeps line breaks
    public static func chunks(title: String, text: String) -> [Chunk]  // text is normalized first
}

// NoteItSmart/Embedding/TextEmbedder.swift
public struct EmbedderIdentity: Codable, Sendable, Equatable {
    public var kind: String               // "nl-contextual" | "hash-test"
    public var modelIdentifier: String
    public var revision: Int
    public var dimension: Int
    public var language: String           // BCP 47, e.g. "en"
}
public enum EmbedderError: Error, Sendable, Equatable { case assetsUnavailable, assetsDownloading, unsupportedLanguage, failed(String) }
public protocol TextEmbedder: Sendable {
    var identity: EmbedderIdentity { get }
    func prepare() async throws                         // loads, requesting assets once if needed
    func embed(_ texts: [String]) async throws -> [[Float]]   // each L2-normalized, count == identity.dimension
}
public final class NLContextualTextEmbedder: TextEmbedder, @unchecked Sendable {
    public init?(language: NLLanguage)
}
public enum LanguagePicker { public static func dominantLanguage(of samples: [String]) -> NLLanguage }  // .english when undetermined

// NoteItSmart/Index/VectorMath.swift
public enum VectorMath {
    public static func normalized(_ v: [Float]) -> [Float]
    public static func quantize(_ v: [Float]) -> (values: [Int8], scale: Float)
    public static func dequantize(_ values: ArraySlice<Int8>, scale: Float) -> [Float]
    /// Dot products of `query` with `rowCount` rows stored contiguously in `matrix` (row-major, Int8) with per-row scales.
    public static func dotProducts(query: [Float], matrix: [Int8], scales: [Float], dimension: Int) -> [Float]
}

// NoteItSmart/Index/IndexManifest.swift
public struct IndexedNote: Codable, Sendable, Equatable {
    public var revision: String
    public var firstRow: Int
    public var ranges: [[Int]]            // [start, length], UTF-16
}
public struct IndexManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var embedder: EmbedderIdentity
    public var chunkerVersion: Int
    public var baseline: Float?
    public var vectorsFile: String        // "vectors-<gen>.bin"
    public var rowCount: Int
    public var notes: [String: IndexedNote]
}

// NoteItSmart/Index/VectorFile.swift
public struct VectorRow: Sendable, Equatable { public var noteID: UUID; public var chunkIndex: Int; public var scale: Float; public var values: [Int8] }
public enum VectorFile {
    public static let magic: [UInt8] = Array("NIVX".utf8)
    public static let headerSize = 32
    public static func create(at url: URL, dimension: Int) throws
    public static func append(_ rows: [VectorRow], to url: URL, dimension: Int) throws -> Int  // returns first new row index
    public static func readAll(at url: URL, dimension: Int) throws -> [VectorRow]               // throws on bad header or partial row
}

// NoteItSmart/Index/SemanticIndex.swift
public struct ChunkHit: Sendable, Equatable { public var noteID: UUID; public var chunkIndex: Int; public var range: Range<Int>; public var similarity: Float }
public struct IndexStats: Sendable, Equatable { public var noteCount: Int; public var rowCount: Int; public var liveRowCount: Int; public var bytesOnDisk: Int64 }
public enum IndexLoadResult: Sendable, Equatable { case empty, loaded, rebuilt(reason: String) }
public actor SemanticIndex {
    public static let relatedMargin: Float = 0.03
    public static let minNotesForBaseline = 20
    public init(directory: URL, identity: EmbedderIdentity)
    public func load() throws -> IndexLoadResult             // wrong version/identity/chunker or corrupt files → deletes and returns .rebuilt
    public func indexedRevisions() -> [UUID: String]
    public func upsert(_ id: UUID, revision: String, chunks: [Chunk], vectors: [[Float]]) throws
    public func remove(_ ids: Set<UUID>) throws
    public func saveManifest() throws
    public nonisolated func saveManifestNow() throws         // writes the latest manifest snapshot on the calling thread; returns once manifest.json is written
    public func search(_ query: [Float], limit: Int, allowed: Set<UUID>?) -> [ChunkHit]
    public func neighbours(of id: UUID, limit: Int, allowed: Set<UUID>?) -> [(noteID: UUID, similarity: Float)]
    public func relatedThreshold() -> Float?                 // baseline + margin; nil until a baseline exists
    public func refreshBaseline(sampleSize: Int, seed: UInt64) // 95th percentile of random cross-note pairs
    public func compactIfNeeded() throws                     // unreferenced rows > 30%
    public func deleteAll() throws
    public func stats() -> IndexStats
}

// NoteItSmart/Ranking/HybridRanker.swift
public struct MatchSources: OptionSet, Sendable, Hashable { public let rawValue: Int; public static let keyword, meaning: MatchSources }
public struct RankedNote: Sendable, Equatable { public var id: UUID; public var score: Double; public var matchedBy: MatchSources }
public enum HybridRanker {
    public static let rrfK = 60.0
    public static func noteHits(_ hits: [ChunkHit], threshold: Float) -> [(id: UUID, similarity: Float)]  // best chunk per note, ≥ threshold, sorted
    public static func fuse(keyword: [UUID], meaning: [UUID], updatedAt: [UUID: Date], limit: Int) -> [RankedNote]
    public static func related(keyword: [UUID], meaning: [UUID], limit: Int) -> [UUID]   // meaning-only, keyword order untouched
}

// NoteItSmart/Generation/TextGenerator.swift
public enum UnavailableReason: Sendable, Equatable {
    case needsNewerMacOS, deviceNotEligible, appleIntelligenceOff, modelNotReady
    case serverUnreachable(String), noModelSelected, modelMissing(String), notLoopback, cloudModel(String), other(String)
}
public enum GeneratorAvailability: Sendable, Equatable { case available, unavailable(UnavailableReason) }
public struct GenerationRequest: Sendable, Equatable {
    public var instructions: String
    public var prompt: String
    public var maxResponseTokens: Int
    public var temperature: Double
}
public enum GenerationError: Error, Sendable, Equatable {
    case contextTooLong, refused, unsupportedLanguage, timedOut, cancelled, server(status: Int, message: String), unavailable(UnavailableReason)
}
public protocol TextGenerator: Sendable {
    var displayName: String { get }
    func availability() async -> GeneratorAvailability
    func contextTokens() async -> Int
    func countTokens(_ text: String) async -> Int
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error>   // cumulative snapshots
}
public enum TokenEstimate { public static func conservative(_ text: String) -> Int }   // (utf8.count + 2) / 3

// NoteItSmart/Generation/LoopbackPolicy.swift
public enum LoopbackPolicy {
    public enum Violation: Error, Sendable, Equatable { case notLoopback(String), badScheme(String), hasCredentials, cloudModel(String) }
    public static func validate(_ url: URL) throws -> URL     // returns URL with "localhost" → "127.0.0.1"
    public static func validateModel(_ name: String) throws
}

// NoteItSmart/Generation/OpenAICompatibleGenerator.swift
public struct LocalServerConfig: Codable, Sendable, Equatable { public var baseURL: URL; public var model: String; public var contextTokens: Int }
public struct OpenAICompatibleGenerator: TextGenerator {
    public init(config: LocalServerConfig, apiKey: String?, protocolClasses: [AnyClass]? = nil) throws  // throws LoopbackPolicy.Violation
    public func listModels() async throws -> [String]
}

// NoteItSmart/Generation/AppleTextGenerator.swift
#if canImport(FoundationModels)
@available(macOS 26.0, *)
public struct AppleTextGenerator: TextGenerator { public init() }
#endif

// NoteItSmart/Ask
public struct AskExcerpt: Sendable, Equatable {
    public var number: Int; public var noteID: UUID; public var title: String; public var notebook: String?
    public var updatedAt: Date; public var range: Range<Int>; public var text: String
}
public struct AskPrompt: Sendable, Equatable { public var request: GenerationRequest; public var excerpts: [AskExcerpt] }
public enum AskPromptBuilder {
    public static let noAnswerToken = "NO_ANSWER"
    public static let maxQuestionCharacters = 500
    public static let answerReserveTokens = 700
    public static func build(question: String, candidates: [AskExcerpt], contextTokens: Int, maxExcerpts: Int,
                             countTokens: (String) -> Int, now: Date) -> AskPrompt
}
public enum AnswerSegment: Sendable, Equatable { case text(String), citation(Int) }
public struct ParsedAnswer: Sendable, Equatable { public var segments: [AnswerSegment]; public var cited: [Int]; public var isNoAnswer: Bool }
public enum AnswerParser { public static func parse(_ raw: String, validNumbers: Set<Int>) -> ParsedAnswer }
public struct RetrievalInput: Sendable {
    public var semanticHits: [ChunkHit]            // already scoped and filtered, best first
    public var relatedThreshold: Float?
    public var keywordNotes: [UUID]                // ranked, scoped
    public var chunksByNote: [UUID: [Chunk]]       // for keyword notes and semantic hits
    public var queryTerms: [String]                // folded
}
public enum RetrievalOutcome: Sendable, Equatable { case nothingRelevant, candidates([(noteID: UUID, chunk: Chunk)]) }
public enum AskRetriever {
    public static let semanticLimit = 24, keywordNotes = 5, keywordOnlyNotes = 8, maxChunksPerNote = 3
    public static func select(_ input: RetrievalInput) -> RetrievalOutcome
}

// NoteItSmart/Writing
public struct TagSuggestion: Sendable, Equatable { public var tag: String; public var isNew: Bool }
public enum WritingPrompts {
    public static func summary(title: String, text: String) -> GenerationRequest
    public static func combine(summaries: [String]) -> GenerationRequest
    public static func titles(text: String) -> GenerationRequest
    public static func tags(text: String, existing: [String]) -> GenerationRequest
}
public enum SuggestionParser {
    public static func titles(_ raw: String) -> [String]                                  // ≤ 3, ≤ 60 chars each
    public static func tags(_ raw: String, existing: Set<String>, current: Set<String>) -> [TagSuggestion]  // ≤ 5
}
public enum NeighborTags {
    public static func suggest(neighbours: [(tags: [String], similarity: Float)], current: Set<String>, limit: Int) -> [String]
}
public enum Summarizer {
    public static let maxGroups = 12
    public static func summarize(title: String, text: String, generator: TextGenerator) async throws -> (summary: String, partial: Bool)
}

// NoteItMCP/NotesBackend.swift
public struct ClientScopes: Sendable, Equatable { public var clientName: String; public var canRead: Bool; public var canWrite: Bool }
public struct SearchQuery: Sendable, Equatable { public var text: String; public var limit: Int; public var notebook: String?; public var tag: String?; public var mode: String }
public struct NoteSummary: Codable, Sendable, Equatable {
    public var id: UUID; public var title: String; public var notebook: String?; public var tags: [String]
    public var updatedAt: Date; public var locked: Bool; public var snippet: String?; public var matchedBy: [String]?
}
public struct SearchResponse: Sendable, Equatable { public var results: [NoteSummary]; public var mode: String }
public struct NoteDocument: Codable, Sendable, Equatable {
    public var id: UUID; public var title: String; public var notebook: String?; public var tags: [String]
    public var createdAt: Date; public var updatedAt: Date; public var revision: String; public var markdown: String
}
public struct NoteRef: Codable, Sendable, Equatable { public var id: UUID; public var revision: String }
public struct NewNote: Sendable, Equatable { public var title: String; public var markdown: String; public var notebook: String?; public var tags: [String] }
public struct NotebookInfo: Codable, Sendable, Equatable { public var id: UUID; public var name: String; public var noteCount: Int }
public struct TagInfo: Codable, Sendable, Equatable { public var tag: String; public var count: Int }
public enum BackendError: Error, Sendable, Equatable {
    case unreachable, unauthorized, revoked, forbidden(scope: String), notFound, locked, conflict(currentRevision: String),
         notAvailable, notImplemented, invalid(String), server(String)   // notAvailable: search mode off; notImplemented: daily gated
}
public protocol NotesBackend: Sendable {
    func whoAmI() async throws -> ClientScopes          // GET /v1/me
    func capabilities() async throws -> Set<String>     // GET /v1/ping, field `capabilities`
    func search(_ query: SearchQuery) async throws -> SearchResponse
    func recentNotes(limit: Int) async throws -> [NoteSummary]
    func readNote(id: UUID) async throws -> NoteDocument
    func createNote(_ note: NewNote) async throws -> NoteRef
    func append(id: UUID, markdown: String, ifRevision: String?) async throws -> NoteRef
    func notebooks() async throws -> [NotebookInfo]
    func tags() async throws -> [TagInfo]
    func dailyNote(date: String) async throws -> NoteDocument?                       // GET /v1/daily?date=&format=markdown
    func appendToDailyNote(date: String, markdown: String) async throws -> NoteRef  // POST /v1/daily/append {text, format, date}
}

// NoteItMCP/MCPConfigSnippet.swift
public enum MCPClientApp: String, CaseIterable, Sendable { case claudeDesktop = "claude-desktop", vscode, cursor, other
    public var profileName: String                         // "mcp-claude-desktop", "mcp-vscode", "mcp-cursor", "mcp-other"
}
public enum MCPConfigSnippet {
    public static let profilePattern = "^mcp(-[a-z0-9]+)*$"
    public static func isValidProfile(_ name: String) -> Bool
    public static func snippet(for app: MCPClientApp, executable: String, allowWrite: Bool) -> String
    public static func configLocation(for app: MCPClientApp) -> String
}

// NoteItMCP/MCPProtocol.swift + MCPServer.swift
public enum MCPProtocol {
    public static let stateless = "2026-07-28"
    public static let legacy = ["2025-11-25", "2025-06-18"]
    public static let maxMessageBytes = 4 * 1024 * 1024
}
public struct MCPServerOptions: Sendable { public var allowWrite: Bool; public var serverVersion: String; public var today: @Sendable () -> String }
public actor MCPServer {
    public init(backend: NotesBackend, options: MCPServerOptions)
    public func handle(line: String) async -> String?        // nil for notifications
    public func run(input: FileHandle, output: FileHandle) async
}

// NoteIt/Model/NoteStore+Smart.swift (app, @MainActor)
extension NoteStore {
    var semanticIndexURL: URL { get }                         // rootURL/semantic-index (the data folder, never contentRootURL)
    struct IndexingText: Sendable { var id: UUID; var revision: String; var title: String; var text: String; var tags: [String] }
    func liveIndexableNotes() -> [(id: UUID, revision: String)] // not deleted, !meta.isLocked; revision = meta.revision or updatedAt stamp
    func indexingTexts(for ids: [UUID]) async -> [IndexingText] // locked notes skipped; bodies via bodyStorage.read(id).text off the main actor
    func revisionStamp(of id: UUID) -> String?
}

// NoteIt/Smart/SemanticIndexer.swift (app, @MainActor)
// Conforms to DerivedIndex (foundations 4.4, organise's shapes): noteChanged(_:body:), noteRemoved(_:), metadataChanged(_:),
// rebuild(notes:body:) async, func flush() (synchronous: blocks until manifest.json is written, through saveManifestNow()).
// Registered once per store open with NoteStore.registerDerivedIndex and never unregistered; dormant while search by meaning is off.
final class SemanticIndexer: DerivedIndex {
    init(store: NoteStore)
    func activate(index: SemanticIndex, embedder: TextEmbedder)   // search by meaning turned on: schedules its own full rebuild
    func deactivate()                                             // search by meaning turned off: cancels work; hooks become no-ops
    func drainForTesting() async
}

// NoteIt/Smart/SmartCaptureTitleRefiner.swift (app)
@MainActor final class SmartCaptureTitleRefiner: CaptureTitleRefining {
    func refinedTitle(for noteID: UUID, kind: CaptureKind, heuristicTitle: String) async -> String?   // nil when off, no model, locked, or failed
}

// NoteIt/Smart/SmartSearchService.swift (app, @MainActor)
struct SmartScope: Equatable { var selection: SidebarSelection }
final class SmartSearchService {
    static let shared: SmartSearchService
    var isAvailable: Bool { get }
    func related(to query: String, scope: SidebarSelection, keyword: [UUID], limit: Int) async -> [UUID]
    func relatedNotes(to noteID: UUID, limit: Int) async -> [UUID]
    func hybrid(query: String, keyword: [UUID], limit: Int) async -> [RankedNote]   // the Local API hybrid handler passes the IDs from its own keyword search
}

// NoteIt/Smart/SmartSearchModes.swift (app, @MainActor)
enum SmartSearchModes {
    static let capability = "meaning-search"
    /// registerSearchMode("meaning") and registerSearchMode("hybrid") on automation's LocalAPIRouteRegistry.
    /// Handlers receive only SearchQuery and LocalAPIContext; hybrid runs the shared keyword search itself.
    /// addCapability(capability) when search by meaning turns on, removeCapability(capability) when it turns off.
    /// Errors use APIErrorCode only.
    static func register(on registry: LocalAPIRouteRegistry, service: SmartSearchService)
}

// NoteIt/Editor/RichTextEditor.swift (addition)
@MainActor static var pendingSelection: [UUID: NSRange]
```

## Tasks

Milestones ship on their own: M1 (search by meaning), M2 (Ask your notes), M3 (summaries, titles, tags), M4 (MCP).

Dependency graph:
- M1: T1 → {T2, T3, T4} in parallel → T5 → T6 → {T7, T8} in parallel → T9. T8 starts after `organise`'s `PaletteRanker` change has merged.
- M2: after T1: {T10, T11, T12} in parallel (T11 depends on T10's protocol file only) → T13 → T14. T13 needs M1.
- M3: after T10 and T5: T15 → T16.
- M4: T17 → T18 can start right after T1 and run in parallel with M1–M3. T19 and T20 need `automation`'s CLI and Local API; T20 also needs T6 (`SmartSearchService`).
- T21 last.

### Milestone 1: Search by meaning

#### Task 1: Package targets, settings keys, shared test support
**Files:**
- Modify `Package.swift`: add `.target(name: "NoteItSmart", dependencies: ["NoteItCore"], path: "Sources/NoteItSmart")`, `.target(name: "NoteItMCP", dependencies: ["NoteItAPI", "NoteItCore"], path: "Sources/NoteItMCP")`, `.testTarget(name: "NoteItSmartTests", dependencies: ["NoteItSmart"], path: "Tests/NoteItSmartTests")`, `.testTarget(name: "NoteItMCPTests", dependencies: ["NoteItMCP"], path: "Tests/NoteItMCPTests")`; add `"NoteItSmart"` and `"NoteItMCP"` to the `NoteIt` target's dependencies. `NoteItCLI` is not changed here; T19 adds `NoteItMCP` to it. Don't touch `platforms`; foundations set it once.
- Create `Sources/NoteItSmart/Embedding/TextEmbedder.swift`, `Generation/TextGenerator.swift` (frozen types only), `Sources/NoteItMCP/JSONValue.swift`.
- Create `Tests/NoteItSmartTests/Support/HashEmbedder.swift`: deterministic embedder (identity kind `hash-test`, dimension 64) that hashes lowercased word unigrams and bigrams into buckets and normalizes, so texts sharing words are similar.
- Create `Tests/NoteItSmartTests/Support/ScriptedGenerator.swift`: returns scripted snapshots per call, records requests, can throw a scripted `GenerationError`.
- Modify `Sources/NoteIt/Settings/Preferences.swift`: add the keys from the spec's settings table to `PrefKey`, defaults to `PrefDefault` (`smartLocalServerURL = "http://127.0.0.1:11434/v1"`, `smartLocalServerContextTokens = 8192`).
- Modify `Sources/NoteIt/Sync/Keychain.swift`: `case smartLocalServerKey = "smart-local-server-key"`.

Steps:
- [ ] Add the targets; run `swift build`, then confirm the bundle script still finds the `NoteIt` binary: `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` exits 0 and `test -x .selftest/app/NoteIt.app/Contents/MacOS/NoteIt` exits 0.
- [ ] Write the frozen types; `TokenEstimate.conservative` returns `(text.utf8.count + 2) / 3`.
- [ ] Tests (`HashEmbedderTests` in `NoteItSmartTests`): same text gives the same vector; vectors have unit length; "trip to Rome" is closer to "Rome trip plans" than to "invoice 2024".
- [ ] Verify: `swift test --filter "NoteItSmartTests|ImportHygieneTests"` PASS; `swift build` and `swift build -c release` end with `Build complete!`.
- [ ] Commit `feat(smart): add smart and MCP targets with shared types`.

#### Task 2: Chunker
**Files:** `Sources/NoteItSmart/Text/Chunker.swift`, `Tests/NoteItSmartTests/ChunkerTests.swift`.
- [ ] `normalize`: remove U+FFFC; replace tabs and runs of spaces with one space; trim each line; collapse 3+ line breaks to 2.
- [ ] Pack paragraphs (split on `\n`) into chunks up to `maxWords` words and `maxCharacters` characters. Split an oversized paragraph with `NLTokenizer(unit: .sentence)`; split an oversized sentence at the last whitespace before the limit.
- [ ] Overlap: each chunk after the first starts with the previous chunk's last sentence if it has ≤ `overlapMaxWords` words. The chunk's `range` starts at that sentence, so ranges may overlap.
- [ ] `embeddingText = title + "\n" + text`. Fewer than `minWords` words in the whole note → `[]`. Stop after `maxChunksPerNote`.
- [ ] Ranges are UTF-16 offsets into the normalized text, and `(normalized as NSString).substring(with:)` of a range equals `text`.
- [ ] Tests: `testShortNoteIsOneChunk`, `testTinyNoteHasNoChunks`, `testParagraphsPackUpToLimit`, `testLongParagraphSplitsAtSentences`, `testHugeSentenceSplitsAtWord`, `testOverlapCarriesLastShortSentence`, `testRangesMatchText` (with emoji and Swedish å/ä/ö), `testAttachmentCharactersDropped`, `testMaxChunksPerNote`, `testDeterministic`.
- [ ] Verify: `swift test --filter ChunkerTests` PASS.
- [ ] Commit `feat(smart): add note chunker`.

#### Task 3: Vector math and file format
**Files:** `Sources/NoteItSmart/Index/VectorMath.swift`, `Index/IndexManifest.swift`, `Index/VectorFile.swift`, `Tests/NoteItSmartTests/VectorMathTests.swift`, `VectorFileTests.swift`.
- [ ] `quantize`: `scale = max(|v|) / 127` (zero vector → scale 0, values 0); `values[i] = Int8((v[i] / scale).rounded())`.
- [ ] `dotProducts`: process 1,024 rows at a time; convert Int8 to Float with `vDSP.convertElements(of:to:)`, multiply-add with `cblas_sgemv` (row-major), then multiply each result by its row scale.
- [ ] `VectorFile`: header = magic, UInt16 version 1, UInt16 dimension, 24 zero bytes. Row = 16-byte UUID, UInt16 chunk index, UInt16 zero, Float32 scale (little-endian bit pattern), `dimension` Int8. `append` opens with `FileHandle(forWritingTo:)`, seeks to end, writes, `synchronize()`s, and returns `(fileSize - headerSize) / rowSize` before the write. `readAll` rejects a wrong magic, version or dimension, and a size that isn't `headerSize + n × rowSize` (throws), so a torn append is detected.
- [ ] Tests: quantize/dequantize cosine error < 0.005 on 100 random unit vectors; `dotProducts` matches a naive Float loop within 1e-3 for 2,500 rows (crossing block boundaries); file round trip; bad magic, wrong dimension and a truncated last row each throw; manifest JSON round trip with stable keys.
- [ ] Verify: `swift test --filter "VectorMathTests|VectorFileTests"` PASS.
- [ ] Commit `feat(smart): add vector quantization and index file format`.

#### Task 4: Embedding with NaturalLanguage
**Files:** `Sources/NoteItSmart/Embedding/NLContextualTextEmbedder.swift`, `Embedding/LanguagePicker.swift`, `Tests/NoteItSmartTests/NLContextualEmbedderLiveTests.swift`.
- [ ] `init?(language:)` wraps `NLContextualEmbedding(language:)`; identity = `kind "nl-contextual"`, `modelIdentifier`, `revision`, `dimension`, `language.rawValue`.
- [ ] `prepare()`: if `hasAvailableAssets` is false, call `requestAssets` once (bridged with `withCheckedThrowingContinuation`); `.available` → `load()`; `.notAvailable`/`.error` → `EmbedderError.assetsUnavailable`. A second `prepare()` while a request is running awaits the same task.
- [ ] `embed`: for each text, `embeddingResult(for:language:)`, then `enumerateTokenVectors(in:)` summing vectors, divide by count, convert Double → Float, `VectorMath.normalized`. Texts are already short enough (chunker limits); anything past `maximumSequenceLength` is truncated by the model, which is fine.
- [ ] `LanguagePicker.dominantLanguage`: feed up to 200 samples (first 500 characters each) to one `NLLanguageRecognizer`, return the top hypothesis, falling back to `.english`.
- [ ] Live test: `XCTSkip` unless `NLContextualEmbedding(language: .english)?.hasAvailableAssets == true`; check unit length, dimension, and that two paraphrases score higher than an unrelated sentence. `LanguagePicker` tests run everywhere (English, Swedish and mixed samples).
- [ ] Verify: `swift test --filter "NLContextualEmbedderLiveTests|LanguagePickerTests"` PASS or skipped.
- [ ] Commit `feat(smart): embed text with NLContextualEmbedding`.

#### Task 5: SemanticIndex actor and ranking
**Files:** `Sources/NoteItSmart/Index/SemanticIndex.swift`, `Ranking/HybridRanker.swift`, `Tests/NoteItSmartTests/SemanticIndexTests.swift`, `HybridRankerTests.swift`.
- [ ] In memory: `matrix: [Int8]`, `scales: [Float]`, `rowNote: [UUID]`, `rowChunk: [Int]`, `live: [Bool]`, plus the manifest. `load()` reads the manifest and file; rows not referenced by the manifest are marked dead. Any mismatch in version, identity, `Chunker.version`, or a file error deletes the folder and returns `.rebuilt(reason:)`.
- [ ] `upsert` marks the note's old rows dead, appends new rows to the file, updates the manifest entry (`firstRow`, `ranges`) and in-memory arrays. Manifest saves are explicit (`saveManifest()`), so the indexer debounces them. Every change to the manifest also updates a lock-protected snapshot; `saveManifestNow()` encodes that snapshot and writes it atomically on the calling thread, without hopping to the actor, so a synchronous caller can wait for it.
- [ ] `search`: dot products over live rows (dead or disallowed rows get `-inf`), partial sort for the top `limit`.
- [ ] `neighbours(of:)`: average the note's chunk vectors, normalize, search, drop the note itself, best chunk per note.
- [ ] `refreshBaseline`: with a seeded `SplitMix64`, pick `sampleSize` pairs of live rows from different notes, take the 95th percentile of their dot products. Needs `minNotesForBaseline` notes, else leaves it nil.
- [ ] `compactIfNeeded`: when dead rows > 30% of rows, write `vectors-<gen+1>.bin` with live rows, rewrite the manifest's `firstRow`s, save the manifest atomically, then delete the old file.
- [ ] `HybridRanker`: `noteHits` keeps each note's best chunk ≥ threshold; `fuse` sums `1 / (rrfK + rank)` (rank starting at 1) over both lists, ties by newer `updatedAt`, sets `matchedBy`; `related` returns meaning hits not in `keyword`, in meaning order, up to `limit`.
- [ ] Tests (with `HashEmbedder` and a temp directory): upsert/search finds the right note; re-upsert replaces old rows; remove hides rows; reload after save restores the same results; a manifest pointing past the file end → `.rebuilt`; identity change → `.rebuilt`; rows appended without a manifest save are ignored after reload; after `upsert`, `saveManifestNow()` called from a synchronous context has written `manifest.json` by the time it returns (read the file straight after the call); compaction keeps results identical and shrinks the file; baseline is nil below 20 notes and deterministic for a seed; `allowed` filters; `neighbours` excludes self. Ranker: RRF order on a hand-computed example, ties by date, `matchedBy` flags, `related` leaves keyword hits out.
- [ ] Performance test: 40,000 rows × 512 dimensions, `measure` a search; assert under 60 ms in release (`swift test -c release --filter SemanticIndexPerformanceTests`), reported, not enforced in debug.
- [ ] Verify: `swift test --filter "SemanticIndexTests|HybridRankerTests"` PASS.
- [ ] Commit `feat(smart): add semantic index and hybrid ranking`.

#### Task 6: App wiring: store access, settings model, controller, indexer, search service
**Files:** create `Sources/NoteIt/Model/NoteStore+Smart.swift`, `Smart/SmartSettings.swift`, `Smart/SmartController.swift`, `Smart/SemanticIndexer.swift`, `Smart/SmartSearchService.swift`, `Tests/NoteItTests/SemanticIndexerTests.swift`, `Tests/NoteItTests/SmartSettingsTests.swift`; modify `App/AppDelegate.swift` (call `SmartController.shared.start()` after `SyncController.shared.start()`, which only starts settings observation, and call `SmartController.shared.storeDidOpen(NoteStore.shared)` in the store-open step, the same step where linking registers `LinkIndex` and automation registers `SpotlightIndexer`). `Model/NoteStore.swift` is not modified.
- [ ] `NoteStore+Smart`: `semanticIndexURL = rootURL.appendingPathComponent("semantic-index", isDirectory: true)` (the data folder, also for Markdown libraries, never `contentRootURL`). `liveIndexableNotes()` = `activeNotes` where `!meta.isLocked`, reading the foundations field directly (no local stub). `revisionStamp` = `meta.revision?.uuidString ?? "t" + updatedAt.timeIntervalSince1970`. `indexingTexts(for:)`: skips locked notes; for notes with a cached or dirty body, reads `bodyCache` on the main actor; for others, calls `bodyStorage.read(id)` in a detached `.utility` task (`NoteBodyStorage` is safe to call off the main actor), then returns title, `.text.string` of the `StoredBody`, tags and the revision stamp captured before reading. No `bodyURL` and no `readBody`. This is the only code that reads note bodies for these features.
- [ ] `SmartSettings`: `@MainActor final class SmartSettings: ObservableObject` with `@AppStorage`-backed properties for every key, plus `func makeGenerator() -> TextGenerator?` (returns nil for `none`; `AppleTextGenerator` inside `#if canImport(FoundationModels)` + `#available(macOS 26.0, *)`; `OpenAICompatibleGenerator` with the Keychain key).
- [ ] `SmartController.shared` (`@MainActor`, `ObservableObject`): `@Published var status: IndexStatus` (`off`, `downloadingModel`, `indexing(done:total:)`, `paused(reason:)`, `upToDate(notes:bytes:)`, `failed(String)`). `start()` observes `smartEnabled`/`smartSearchEnabled` through `UserDefaults.didChangeNotification` (coalesced, like `AppDelegate.scheduleDefaultsSync`). Turning search on: pick the language (`LanguagePicker` over 200 note texts), create the embedder, `prepare()`, open `SemanticIndex`, then `indexer.activate(index:embedder:)`, which schedules the indexer's own full rebuild. `start()` creates no indexer and registers nothing. Store lifecycle:
  - `storeDidOpen(_ store: NoteStore)` is called from the store-open step in `AppDelegate`, right after `NoteStore.shared` is opened and before anything else uses the store, next to the linking and automation registrations. It creates a new `SemanticIndexer(store:)` and registers it with `store.registerDerivedIndex` (indexID `semantic`, checked first with `canRegisterDerivedIndex`), once per store open, whether search by meaning is on or off. There is no unregister call (program §7). If search by meaning is on, it then activates the indexer as above.
  - `storeWillClose()` is called when that store closes. It calls `indexer.deactivate()` and drops every store-specific object: the indexer reference, the open `SemanticIndex`, pending queues and the status. It doesn't delete the index on disk. The next `storeDidOpen` starts from nothing and registers its own indexer with the new store, so no index or indexer state carries over from one store to the next.
  - Turning off: `indexer.deactivate()` (cancel work; every hook becomes a no-op), `deleteAll()`, status `off`. The indexer stays registered and dormant until the store closes; turning on again reactivates the same indexer without registering again. `rebuild()` deletes and restarts.
- [ ] `SemanticIndexer` conforms to `DerivedIndex`. While it is not active (search by meaning off), every hook returns at once without reading anything. When active: `noteChanged(_:body:)` (body changes and new notes) queues the note and starts a 3 s debounce; `noteRemoved` removes its rows at once (deleted for good, and locking: the registry sends `noteRemoved` when a note is locked and never sends `noteChanged` for a locked note); `metadataChanged` removes the rows of a note moved to Recently Deleted and queues a restored one, and ignores pins, moves and tag changes (metadata-only changes never call `noteChanged`); `rebuild(notes:body:)` diffs `liveIndexableNotes()` with `indexedRevisions()`, removes what's gone and queues what changed; `flush()` is synchronous, as frozen in foundations: it calls `index.saveManifestNow()` on the calling thread and returns only once the manifest is written. It starts no `Task`. As a second guard, the worker drops a note whose `meta.isLocked` is true. No subscription to `NoteStore.$notes` and no hook added to `NoteStore.swift`. Worker: queue ordered most recently edited first; batches of 16 → `indexingTexts` → `Chunker.chunks` → `embed` → re-check `revisionStamp` and `isLocked` on the main actor, drop if changed → `upsert`. Save the manifest after every 200 notes and 5 s after the queue drains; then `compactIfNeeded`, and `refreshBaseline(sampleSize: 500, seed: 1)` after a full build or 500 changes. Pause while `ProcessInfo.processInfo.isLowPowerModeEnabled` or `thermalState >= .serious` (observe `NSProcessInfoPowerStateDidChange` and `ProcessInfo.thermalStateDidChangeNotification`).
- [ ] `SmartSearchService`: embeds the query with the controller's embedder, scopes with `store.notes(for: scope, search: "")` IDs, and returns `HybridRanker.related(...)` above `relatedThreshold()`. `relatedNotes(to:)` uses `neighbours`. `hybrid(...)` uses `fuse`. All return `[]` when unavailable.
- [ ] Tests (`NoteItTests`, scratch `NoteStore(rootURL:)` in a temp dir, `SemanticIndexer` registered once with the store's `DerivedIndex` registry, then activated with a `HashEmbedder`-backed index): create three notes → after `indexer.drainForTesting()` all are indexed; edit one → only that note is re-embedded (count calls); delete for good → removed; moved to Recently Deleted (`metadataChanged`) → removed, restored → indexed again; a note edited during embedding is re-queued, not stored stale; a note with `meta.isLocked` set is never embedded and its body is never read (counting `NoteBodyStorage` fake); locking an indexed note removes its rows (through `refreshDerivedIndexes(for:)`, which sends `noteRemoved`); `semanticIndexURL` is under `rootURL`; with search by meaning off the registered indexer embeds nothing and reads no body on create, edit and `rebuild`; turning it back on schedules a full rebuild without registering again (registering twice would trap); `start()` alone registers nothing; `storeDidOpen` registers exactly one indexer with that store, and `storeWillClose()` followed by `storeDidOpen` on a second scratch store registers a new indexer with the second store, leaves the first store's indexer deactivated, and carries no queued notes or status across; `flush()` after an edit leaves an up-to-date `manifest.json` on disk when it returns; `SmartSettings` defaults are all off and `makeGenerator()` returns nil.
- [ ] Verify: `swift test --filter "SemanticIndexerTests|SmartSettingsTests"` PASS; `swift build` clean.
- [ ] Commit `feat(smart): index notes by meaning in the background`.

#### Task 7: Smart Features settings tab (search part)
**Files:** create `Sources/NoteIt/Settings/SmartSettingsView.swift`; modify `Settings/SettingsView.swift` (`Tab.smart` already exists from foundations 6.3 at frozen position 7 with symbol `sparkles`, hidden by `isAvailable`; this task makes `isAvailable` true for `smart`, points the case at `SmartSettingsView` with `Label("Smart Features", systemImage: "sparkles")`, and doesn't add, rename or reorder cases, so `noteit://settings?tab=smart` works).
- [ ] `Form` with `.formStyle(.grouped)` like the other tabs. Master toggle and footnote (`SettingsFootnote`), then the Search section: toggle, live status line from `SmartController.status`, **Rebuild Index**, **Show in Finder** (`NSWorkspace.shared.activateFileViewerSelecting([semanticIndexURL])`), footnote text from the spec. Rows below the master toggle are `.disabled(!smartEnabled)`.
- [ ] The Writing section is added in T14 and the AI apps row in T19; leave nothing visible for them yet.
- [ ] Verify manually: `NOTEIT_DATA_DIR=.selftest/smart swift run NoteIt`, open Settings › Smart Features, turn on both toggles, watch the status reach *Up to date*, confirm `.selftest/smart/semantic-index/` exists; turn search off and confirm the folder is gone. `swift build -c release` clean.
- [ ] Commit `feat(smart): add Smart Features settings tab`.

#### Task 8: Related results in the note list and Open Quickly
**Files:** create `Sources/NoteIt/Smart/SemanticSearchModel.swift`; modify `Views/NoteListView.swift`, `Palette/PaletteRanker.swift`, `Palette/PaletteModel.swift`; extend `Tests/NoteItTests/PaletteRankerTests.swift`.
- [ ] `SemanticSearchModel` (`@MainActor ObservableObject`): `@Published private(set) var related: [UUID]`; `update(query:scope:keyword:)` cancels the previous task, waits 250 ms, requires ≥ 3 characters and an available service, calls `SmartSearchService.related(…, limit: 10)`, and publishes only if the query is still current.
- [ ] `NoteListView`: when searching and `related` is non-empty, render keyword rows as today, then `Section("Related")` with `NoteRow`s (tag `note.id`, same context menu). Not in `.recentlyDeleted`. `reconcileSelection` is unchanged: related notes aren't part of `visibleNotes`, so selection never jumps to them on its own.
- [ ] Rebase on `organise`'s `PaletteRanker` change first: `bodyMatches` is `[UUID: Double]` and body-only matches sort by score. Related items never change that order.
- [ ] `PaletteRanker.items(…)`: new parameter `related: [UUID] = []`, after `bodyMatches`. In `.everything` mode with non-empty text, append up to 5 related notes not already listed (as title or body matches), as `PaletteItem(id: "related:<uuid>", kind: .note(id), subtitle: "Related · <notebook>")`, before the create-note row. Update the `PaletteItem.id` comment.
- [ ] `PaletteModel.recompute()` passes `relatedResults`; a `SemanticSearchModel` owned by the palette model refreshes them and calls `recompute()` when they arrive (keeping the selected row by id, as `refresh()` does).
- [ ] Tests: ranker appends related after scored body matches without reordering them, dedupes notes already shown, caps at 5, and ignores related in `.commands` mode and for empty text.
- [ ] Verify: `swift test --filter PaletteRankerTests` PASS; manual check in `.selftest/smart` that typing "holiday" lists a note about "vacation in Italy" under Related.
- [ ] Commit `feat(smart): show related notes in search and Open Quickly`.

#### Task 9: M1 docs
**Files:** `docs/architecture.md` (new *Smart features* section, the data-folder file list gets `semantic-index/`, folders table gets `Smart/`, targets table gets `NoteItSmart`, the `DerivedIndex` list gets the semantic indexer), `docs/known-limitations.md` (one model per library; 64-chunk cap; locked notes are never searched by meaning), `docs/roadmap.md`, `README.md` (product tour line).
- [ ] Write in the existing plain style; no machine paths.
- [ ] Verify: `grep -n "Smart features" docs/architecture.md`, `grep -n "semantic-index/" docs/architecture.md`, `grep -n "NoteItSmart" docs/architecture.md` and `grep -n "semantic" docs/known-limitations.md` each print at least one line.
- [ ] Commit `docs: document search by meaning`.

### Milestone 2: Ask your notes

#### Task 10: Generators and loopback policy
**Files:** `Sources/NoteItSmart/Generation/LoopbackPolicy.swift`, `SSEParser.swift`, `OpenAICompatibleGenerator.swift`, `Tests/NoteItSmartTests/Support/StubURLProtocol.swift`, `LoopbackPolicyTests.swift`, `SSEParserTests.swift`, `OpenAICompatibleGeneratorTests.swift`.
- [ ] `LoopbackPolicy.validate`: scheme `http`/`https` only; no `user`/`password`; host (lowercased, brackets stripped) must be `localhost`, `::1`, or parse as IPv4 in `127.0.0.0/8` (use `inet_pton`, not string prefixes, so `127.0.0.1.example.com` fails); return the URL with `localhost` → `127.0.0.1`. `validateModel` rejects names ending in `-cloud` or `:cloud` (case-insensitive).
- [ ] `SSEParser`: feed bytes, emit `data:` payloads per event, handle `\r\n`, multi-line data, comments, and `[DONE]`.
- [ ] Generator: `URLSessionConfiguration.ephemeral`, `connectionProxyDictionary = [:]`, `timeoutIntervalForRequest = 10`, `timeoutIntervalForResource = 120`, `protocolClasses` injectable for tests; a delegate that refuses redirects. `listModels()` → `GET /models`, `data[].id`. `availability()` → validate, then `listModels` (unreachable → `.serverUnreachable("127.0.0.1:11434")`; model not listed → `.modelMissing`; empty model → `.noModelSelected`). `stream` → `POST /chat/completions` `{model, messages: [{role: system, content: instructions}, {role: user, content: prompt}], stream: true, temperature, max_tokens}`, yielding the accumulated `choices[0].delta.content`. HTTP errors → `.server(status:message:)` with the body cut to 200 characters. Task cancellation cancels the data task. `countTokens` uses `TokenEstimate.conservative`; `contextTokens` returns the config value.
- [ ] Tests: policy accepts `http://localhost:11434/v1`, `http://127.0.0.2:8080`, `http://[::1]:1234/v1`; rejects `http://192.168.1.10`, `http://example.com`, `http://127.0.0.1.example.com`, `ftp://127.0.0.1`, `http://u:p@127.0.0.1`, model `gpt-oss:120b-cloud`. SSE cases. Generator with `StubURLProtocol`: request body shape, Authorization header only with a key, streamed snapshots accumulate, 404 maps to `.server`, redirect to `http://example.com` is refused, cancellation stops the stream.
- [ ] Verify: `swift test --filter "LoopbackPolicyTests|SSEParserTests|OpenAICompatibleGeneratorTests"` PASS.
- [ ] Commit `feat(smart): add loopback-only local model server support`.

#### Task 11: Apple Foundation Models generator
**Files:** `Sources/NoteItSmart/Generation/AppleTextGenerator.swift`.
- [ ] Whole file in `#if canImport(FoundationModels)`; type `@available(macOS 26.0, *)`.
- [ ] `availability()` maps `SystemLanguageModel.default.availability` (`.available`, `.unavailable(.deviceNotEligible)`, `.appleIntelligenceNotEnabled`, `.modelNotReady`, other → `.other`).
- [ ] `contextTokens()`/`countTokens(_:)`: `if #available(macOS 26.4, *)` use `SystemLanguageModel.default.contextSize` and `tokenCount(for:)`; else 4,096 and `TokenEstimate.conservative`.
- [ ] `stream`: new `LanguageModelSession(instructions:)` per request; iterate `streamResponse(to:options: GenerationOptions(temperature:maximumResponseTokens:))`, yielding each snapshot's content. Map `LanguageModelSession.GenerationError.exceededContextWindowSize` → `.contextTooLong`, `.guardrailViolation` → `.refused`, `.unsupportedLanguageOrLocale` → `.unsupportedLanguage`; cancellation → `.cancelled`.
- [ ] No unit tests (the model isn't available in CI). Manual check on a macOS 26 Mac with Apple Intelligence on: a debug launch argument `-smartSelfTest` (handled in `AppDelegate.handleDebugArguments`, `#if DEBUG`) runs one short request and logs the length of the answer.
- [ ] Verify: `swift build` and `swift build -c release` clean with the current SDK; CI on macos-15 builds clean (guards work).
- [ ] Commit `feat(smart): add Apple Intelligence text generation on macOS 26`.

#### Task 12: Retrieval, prompt and answer parsing
**Files:** `Sources/NoteItSmart/Ask/AskRetriever.swift`, `AskPromptBuilder.swift`, `AnswerParser.swift`, tests `AskRetrieverTests.swift`, `AskPromptBuilderTests.swift`, `AnswerParserTests.swift`.
- [ ] `AskRetriever.select`: related semantic hits (≥ threshold) up to 24; for the top 5 keyword notes, the chunk with the most `queryTerms` (folded with `NoteItCore`'s text folding, the same folding search uses) not already present; fuse chunk lists with RRF; cap 3 chunks per note, keep fused order. If no related hit and no keyword note → `.nothingRelevant`. With no threshold (no semantic index), use the top 8 keyword notes × 3 chunks.
- [ ] `AskPromptBuilder.build`: instructions text from the spec (exact wording lives here, one constant); question trimmed and capped (callers refuse > 500 earlier); excerpts numbered from 1 in order, header `"[n] <title> — <notebook> (edited <d MMM yyyy>)"` (notebook part omitted when nil), dates in `en_US_POSIX` with a fixed format so tests are stable; add excerpts while `countTokens(instructions + prompt) + answerReserveTokens <= contextTokens` and count ≤ `maxExcerpts`.
- [ ] `AnswerParser.parse`: regex `\[(\d+(?:\s*,\s*\d+)*)\]` → citation segments, numbers outside `validNumbers` dropped; text before/after kept; `isNoAnswer` when the trimmed answer starts with `NO_ANSWER`; `cited` in first-appearance order, unique. Works on partial snapshots (a trailing `[1` stays text until closed).
- [ ] Tests: gate returns `.nothingRelevant`; 3-per-note cap; keyword-only mode; budget stops adding excerpts at the limit (with a counting closure); header formats; parser handles `[1]`, `[1, 3]`, `[9]` invalid, partial `[2`, `NO_ANSWER`, and no citations.
- [ ] Verify: `swift test --filter "AskRetrieverTests|AskPromptBuilderTests|AnswerParserTests"` PASS.
- [ ] Commit `feat(smart): build cited prompts from retrieved note passages`.

#### Task 13: Ask model, panel, palette, menu and hotkey
**Files:** create `Sources/NoteIt/Smart/AskModel.swift`, `AskPanel.swift`, `AskView.swift`, `App/SmartCommands.swift`, `Tests/NoteItTests/AskModelTests.swift`; modify `App/MenuShortcuts.swift` (`MenuShortcutCommand.askNotes`, title "Ask Your Notes…", default `MenuShortcut("a", [.command, .option])`, and the `MenuShortcutRules` entry; delete the `askNotes` row from `PlannedMenuShortcuts` in the same change), `docs/keyboard-shortcuts.md` (⌥⌘A in the Edit menu), `App/NoteItApp.swift` (Ask Your Notes… in the Find group), `Hotkeys/HotkeyAction.swift` (case `askNotes`, whose `hotkeyID` comes from `HotkeyOrder` position 12 (foundations 6.2), whatever order the cases merge in; title "Ask Your Notes", description "Ask a question and get an answer from your notes.", symbol `sparkles`, no default binding), `Settings/ShortcutsSettingsView.swift` (tile colour case for `askNotes` in the action switch), `App/AppDelegate.swift` (handler case in the hotkey switch → `AskPanelController.shared.show(question: nil)`), `Palette/PaletteRanker.swift` (`PaletteMode.ask` for a leading `?`; `PaletteItemKind.ask(String)`, single row "Ask your notes: “…”", id `ask`), `Palette/PaletteModel.swift` (activate `.ask` → dismiss, open Ask panel with the question), `Palette/PaletteView.swift` (placeholder "Ask a question about your notes" in ask mode), `Palette/PaletteCommandRegistry.swift` (`askNotes` command, available when Ask is on), `Editor/RichTextEditor.swift` (`pendingSelection`, applied where `pendingCaret` is).
- [ ] Check `MenuShortcutRules` accepts ⌥⌘A and the foundations test that no two default shortcuts are equal still passes; add `askNotes` to the conflict checks the store already runs over `allCases`.
- [ ] Hotkey tests from foundations still pass: raw values unique, first six cases unchanged, `askNotes` in its frozen position, no default binding.
- [ ] `AskModel` (`@MainActor ObservableObject`): `question`, `scope`, `state` (`idle`, `searching`, `nothingRelevant`, `answering(ParsedAnswer)`, `done(ParsedAnswer)`, `failed(String)`), `excerpts`. `ask()`: refuse > 500 characters; gather keyword notes (`store.notes(for: scope, search: question)` IDs, or `organise`'s ranking when present), dropping locked notes; semantic hits (locked notes are never indexed); chunks for those notes via `NoteStore.indexingTexts` + `Chunker`; `AskRetriever.select`; build the prompt (Apple: 8 excerpts; local: 16); stream; on `.contextTooLong` retry once with half the excerpts; map errors to the spec's messages. `stop()` cancels. `saveAsNote()` creates the note through `createNoteInCurrentContext(initial:)`, with each source as a link built by `NoteItCore.NoteLink` (`noteit://note/<UUID>`, title as link text).
- [ ] `AskPanel`: `NSPanel` hosting `AskView`, 640×520, resizable, floating, closes on Esc and cancels; reuses `TransientSurfaceHider` like the palette when shown over another app.
- [ ] `AskView`: question field (↩ asks), scope popup, answer text built from segments with citation chips (buttons), *"Read but not used"* / *"Also read"* groups, footnote for uncited answers, Copy Answer, Save as Note, Stop. Source click → `PaletteModel`-style open (select sidebar so the note is visible), set `RichTextEditor.pendingSelection[id]` to the range only if the note's revision stamp equals the one used.
- [ ] Menu: in `App/NoteItApp.swift`'s existing `CommandGroup(replacing: .textEditing)` (the Find group), add `AskNotesMenuItem()` (from `SmartCommands.swift`) right after Search Notes, before the Find submenu: `Button("Ask Your Notes…")` with `.menuShortcut(.askNotes)`, shown only when Ask is on. No File menu items and no Smart Features submenu.
- [ ] Tests (`AskModelTests`, scratch store, `HashEmbedder`, `ScriptedGenerator`): nothing relevant → no generator call; answer with `[1]` → state `done` with one citation; `NO_ANSWER` → no-answer state; `.contextTooLong` → second call with fewer excerpts; `stop()` → cancelled, no state change after; 501-character question refused; a locked note matching the question by title is never read or sent; Save as Note links use `noteit://note/<UUID>`. Ranker tests for `?` mode.
- [ ] Verify: `swift test --filter "AskModelTests|PaletteRankerTests|MenuShortcutStoreTests|HotkeyActionTests"` PASS; manual run with a local Ollama (`ollama serve`, any small model) in `.selftest/smart`: ask a question answered by a seeded note, click a chip, confirm the passage is selected.
- [ ] Commit `feat(smart): add Ask your notes with cited sources`.

#### Task 14: Settings › Writing section and M2 docs
**Files:** modify `Settings/SmartSettingsView.swift`; `docs/architecture.md`, `docs/keyboard-shortcuts.md` (⌥⌘A, `?` in the palette), `docs/known-limitations.md`, `README.md`.
- [ ] Model popup (`none`, `apple`, `localServer`) with availability text; Apple row disabled before macOS 26 with *"Needs macOS 26 or later"*; **Open System Settings…** opens `x-apple.systempreferences:com.apple.Siri-Settings.extension` when Apple Intelligence is off. Local server fields: address (validated with `LoopbackPolicy` on commit, inline error), model popup + Refresh (`listModels`), context size stepper (4,096–131,072), API key `SecureField` (Keychain), **Test Connection** (runs `availability()` and a 1-token request). Toggles: Ask your notes, Summaries titles and tags, Suggest tags while I write (the last disabled unless search by meaning is on). Footnotes from the spec.
- [ ] First time `smartEnabled` turns on: set `smartGenerator` to `apple` if available, else leave `none`.
- [ ] Verify manually: switching models updates availability; entering `http://192.168.1.2:11434/v1` shows *"Only servers on this Mac are allowed."* and isn't saved.
- [ ] Commit `feat(smart): choose a model in Smart Features settings` and `docs: document Ask your notes`.

### Milestone 3: Summaries, titles and tags

#### Task 15: Writing logic
**Files:** `Sources/NoteItSmart/Writing/WritingPrompts.swift`, `SuggestionParser.swift`, `NeighborTags.swift`, `Summarizer.swift`, tests `SuggestionParserTests.swift`, `NeighborTagsTests.swift`, `SummarizerTests.swift`.
- [ ] Prompts as in the spec; temperatures 0.5; `maxResponseTokens` 300 (summary), 120 (titles), 80 (tags). `titles` uses the first 600 words; `tags` includes up to 200 existing tags.
- [ ] `SuggestionParser.titles`: split lines, strip `1.`, `-`, `*`, quotes and trailing `.`, drop empties and case-insensitive duplicates, cut to 60 characters on a word boundary with `…`, max 3. `tags`: split on lines and commas, lowercase, drop `#`, spaces → `-`, keep `a-z0-9`, letters with diacritics, `-`, `_`, `/`; drop current tags and duplicates; `isNew` when not in `existing`; max 5.
- [ ] `NeighborTags.suggest`: weight = similarity; sum per tag; keep tags with ≥ 25% of the total weight, not in `current`, by weight, up to `limit`.
- [ ] `Summarizer.summarize`: if `countTokens(text) + 700 + instructions <= contextTokens`, one request; else group `Chunker` chunks into groups that fit, summarize up to 12 groups, then `combine`; `partial` when groups were dropped.
- [ ] Tests with `ScriptedGenerator`: single-pass vs map-reduce call counts; partial flag; parser edge cases (numbered, quoted, duplicate, Swedish tag `#möte`, nested `work/planning`); neighbour weighting.
- [ ] Verify: `swift test --filter "SuggestionParserTests|NeighborTagsTests|SummarizerTests"` PASS.
- [ ] Commit `feat(smart): add summaries and title and tag suggestions`.

#### Task 16: Editor UI for writing helpers
**Files:** create `Sources/NoteIt/Smart/SmartNoteActions.swift`, `Smart/SmartNoteViews.swift`, `Smart/SmartCaptureTitleRefiner.swift`, `Tests/NoteItTests/SmartNoteActionsTests.swift`; modify `Views/EditorContainerView.swift` (`EditorHeader`: sparkles `Menu` before the pin button when `smartEnabled`; `SmartTagSuggestionRow` between the header and `FormattingToolbar`), `Palette/PaletteCommandRegistry.swift` (Summarize Note, Suggest Title, Suggest Tags, Related Notes; available for a live, unlocked note when the matching feature is on). No menu bar items for these four.
- [ ] `SmartNoteActions` (`@MainActor`): `summarize(noteID:)`, `suggestTitles(noteID:)`, `suggestTags(noteID:)` (model if chosen, else `NeighborTags`), `relatedNotes(noteID:)`, `insertSummary(_:into:)`, `applyTitle(_:to:)`, `addTag(_:to:)`. Every edit calls `NoteStore.editBody(id, actionName:) { text in … }` (`organise`), which handles an open editor (main window or floating note; read-only surfaces such as cheat sheets mirror the change through `OpenEditorRegistry`), keeps undo as one step named after the action, and marks the note for saving. No direct text view edits and no `updateBody`. `addTag` uses `organise`'s tag API when present, else appends `\n#tag` through `editBody`. Every action refuses a note with `meta.isLocked` and the menu shows it disabled with *"This note is locked."*
- [ ] `SmartCaptureTitleRefiner` implements `capture-plus`'s `CaptureTitleRefining`: `refinedTitle(for:kind:heuristicTitle:)` returns the first `SuggestionParser.titles` result from `WritingPrompts.titles` over the note's text, or `nil` when *Summaries, titles and tags* is off, no model is available, the note is locked, or generation fails. Hand an instance to `capture-plus` the way its plan exposes the hook; `capture-plus` decides when to call it and applies the title.
- [ ] Views: summary popover (text, Insert at Top, Copy, Close, *"Summarizes the first part of this note."* when partial); title popover (3 buttons); related popover (5 rows, click opens); tag chip row (chips with *new* badge, Dismiss; dismissed state keyed by note id + revision stamp, kept in memory).
- [ ] Suggest while writing: `SmartController` observes the `localNoteChange` notification (foundations 4.5, `userInfo["noteID"]`) with `kind: edited` for the selected note; after 5 s idle, ≥ 40 words, no tags, not locked, compute `NeighborTags` and show the row.
- [ ] Tests (`SmartNoteActionsTests`, scratch store, `ScriptedGenerator`): insert summary, apply title and add tag each go through `editBody` and undo in one step, for a note open in an editor and for a closed note; actions on a locked note neither read the body nor call the generator; the refiner returns `nil` when writing is off and the first suggestion otherwise.
- [ ] Verify: `swift test --filter SmartNoteActionsTests` PASS; manually in `.selftest/smart` with a local model: each action works, each edit undoes in one ⌘Z; with model `none`, Summarize and Suggest Title are disabled with the tooltip and Suggest Tags still works. `swift build -c release` clean.
- [ ] Commit `feat(smart): add summary, title and tag actions to the editor` and `docs: document summaries and suggestions`.

### Milestone 4: MCP server

#### Task 17: JSON-RPC and protocol core
**Files:** `Sources/NoteItMCP/JSONRPC.swift`, `MCPProtocol.swift`, `NotesBackend.swift`, `Tests/NoteItMCPTests/Support/FakeNotesBackend.swift`, `JSONRPCTests.swift`, `MCPProtocolTests.swift`.
- [ ] `JSONRPC`: decode one line into request (has `id` and `method`), notification (no `id`) or invalid; encode responses without embedded newlines (`JSONEncoder` with `.withoutEscapingSlashes`, never pretty-printed). Errors: `-32700` parse, `-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal.
- [ ] Version handling: a request with `_meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"` is stateless; `initialize` with a supported legacy version echoes it, an unsupported one returns `2025-11-25`; `server/discover` returns server info, capabilities (`tools`, `resources`), supported versions and instructions. Requests with no version and no prior `initialize` are treated as `2025-11-25` for compatibility.
- [ ] `FakeNotesBackend`: in-memory notes, notebooks, tags, daily notes; configurable scopes and errors; a configurable set of locked note ids (listed and searched with `locked: true` and an empty snippet, title-only matching, `.locked` from `readNote`, `append` and daily reads of a locked daily note); a configurable `capabilities` set (default empty) returned by `capabilities()`, with a counter of calls so T18 can check it is asked once per process.
- [ ] Tests: line framing (embedded newline in a string stays escaped), each error code, `initialize` negotiation, `server/discover`, notifications produce no output, oversized line → `-32700`; the fake's locked notes behave as above and its `capabilities` set round-trips.
- [ ] Verify: `swift test --filter "JSONRPCTests|MCPProtocolTests"` PASS.
- [ ] Commit `feat(mcp): add JSON-RPC framing and protocol negotiation`.

#### Task 18: Tools, resources and the server loop
**Files:** `Sources/NoteItMCP/MCPTools.swift`, `MCPResources.swift`, `MCPConfigSnippet.swift`, `MCPServer.swift`, tests `MCPToolsTests.swift`, `MCPResourcesTests.swift`, `MCPConfigSnippetTests.swift`, `MCPServerTests.swift`.
- [ ] Tool definitions exactly as the spec's table: `inputSchema`, `outputSchema`, annotations, descriptions in plain words. Write tools (and `daily_note.append`) are present only when `options.allowWrite && scopes.canWrite`; scopes come from `backend.whoAmI()` once per process (re-fetched after an `unauthorized`). `canWrite` is true for `write` or `admin`, since 01's scopes are cumulative.
- [ ] Argument validation with `-32602` for protocol-level type errors, and tool errors (`isError: true`) for semantic ones (empty query, limit out of range, unknown id format). `read_note` accepts a UUID, `noteit://note/<UUID>` (parsed with `NoteItCore.NoteLink`) or `noteit://open?id=<UUID>`; truncates `markdown` to 100,000 characters with `truncated: true`. Every `uri` the server prints is `NoteLink`'s `noteit://note/<UUID>`.
- [ ] `search_notes`: asks `backend.capabilities()` once per process (re-asked after a `.notAvailable`); without `meaning-search` it sends `mode=keyword` directly; on `.notAvailable` from `meaning`/`hybrid` it repeats with `keyword`. Results carry `locked`, and locked results have an empty snippet. `.notImplemented` from daily gives the daily message.
- [ ] Results: `content: [{type: "text", text: <short summary>}]`, `structuredContent: <JSON>`. `BackendError` → messages from the spec, including `.locked` → *"This note is locked. Unlock it in NoteIt to read it."*
- [ ] Resources: list (50 recent, `noteit://note/<UUID>`, locked notes title only), templates (`noteit://note/{id}`, `noteit://daily?date={date}`), read (`noteit://note/<UUID>` and `noteit://open?id=<UUID>` through `readNote`; `noteit://daily?date=<date>` through `dailyNote(date:)`, which never creates; a locked note is a resource error); `ttlMs` on lists under `2026-07-28`.
- [ ] `MCPConfigSnippet`: profile names from `MCPClientApp.profileName`, all matching `^mcp(-[a-z0-9]+)*$`; snippet JSON for each app as in the spec, with `"--allow-write"` added for write access; config file locations as text.
- [ ] `MCPServer.run`: read stdin with `FileHandle.bytes.lines`, handle requests concurrently (each in a child task keyed by id), write responses through one serial writer, honour `notifications/cancelled` by cancelling the task and sending no response. Stops at EOF.
- [ ] Tests: `tools/list` read-only vs write (all four combinations of flag and scope); each tool happy path; `append_to_note` revision conflict message; `daily_note` without `append` doesn't create; unreachable backend message; locked note: listed with `locked: true` and empty snippet, `read_note` and `resources/read` fail with the locked message; `read_note` accepts all three id forms; printed URIs use `noteit://note/`; search without `meaning-search` never asks for `hybrid`; resources list/read; cancellation; two interleaved requests answered with the right ids; snippets and profile name rule.
- [ ] Verify: `swift test --filter NoteItMCPTests` PASS.
- [ ] Commit `feat(mcp): add NoteIt MCP tools and resources`.

#### Task 19: `noteit mcp` subcommand and setup (needs `automation`)
**Files:** create `Sources/NoteItCLI/MCPCommand.swift`, `Sources/NoteItCLI/LocalAPIBackend.swift`; add `"NoteItMCP"` to `NoteItCLI`'s dependencies in `Package.swift`; replace the reserved `noteit mcp` stub in the CLI's command table with the whole `mcp` command tree, which this sub-project owns. In the app: create `Sources/NoteIt/Smart/MCPSetupSheet.swift`; modify `Settings/SmartSettingsView.swift` (AI apps row that links to Integrations).
- [ ] `noteit mcp [--profile <name>] [--allow-write] [--launch-app]`: `--profile` defaults to `mcp`; resolve the token (`NOTEIT_TOKEN`, else Keychain service `io.github.rutbergphilip.noteit.cli`, account = profile) and the port (`local-api.json`) with `automation`'s CLI helpers, but with its auto-launch turned off (the `--no-launch` behaviour) unless `--launch-app` is given; build `LocalAPIBackend`; run `MCPServer`. Nothing but protocol messages on stdout; the CLI's own messages go to stderr.
- [ ] `LocalAPIBackend` over `NoteItAPIClient` and `NoteItAPI`'s wire types: map each `NotesBackend` method to the endpoints in the spec's *Needs from 01* list (`capabilities()` reads `PingDTO`'s `capabilities` field; daily uses `GET /v1/daily?date=&format=markdown` and `POST /v1/daily/append` with `{text, format: "markdown", date}`). Errors by the nested body's `APIErrorCode`: `unauthorized` → `.unauthorized`, `token_revoked` → `.revoked`, `forbidden_scope` → `.forbidden`, `not_found` and `note_deleted` → `.notFound`, `note_locked` (423) → `.locked`, `revision_mismatch` (412) → `.conflict` with the revision from the returned note, `not_available` (501, a search mode that is turned off) → `.notAvailable` (the server retries search with `keyword`); `not_implemented` (501, daily routes while `DailyNotes.isAvailable` is false) → `.notImplemented`, shown as *"Daily notes aren't available in this version of NoteIt."*; `bad_request` (400) → `.invalid`; connection refused or no discovery file → `.unreachable`. No string codes of its own.
- [ ] `noteit mcp setup <claude-desktop|vscode|cursor|other> [--write]`: pair through `automation`'s flow (`POST /v1/pair/start` with `clientName: "MCP · <App>"`, `kind: "mcp"`, scopes `read` or `write`; prompt for the code), save the token as `MCPClientApp.profileName` (`mcp-claude-desktop`, `mcp-vscode`, `mcp-cursor`, `mcp-other`), print `MCPConfigSnippet.snippet` with the bundled binary's real path (`Bundle.main.executableURL` resolved through symlinks).
- [ ] `noteit mcp store-token --profile <name>`: refuses names that don't match `mcp(-[a-z0-9]+)*`; reads one token line from stdin (refuses a TTY), checks it with `GET /v1/me`, writes the Keychain item; `--delete` removes the profile's item instead. Used by the setup sheet, so the item is created by the CLI binary and later read without a prompt.
- [ ] `MCPSetupSheet` (app): app picker, Read only / Read and write, the warning text from the spec, Create → `AutomationService.shared.clients` issues a client of kind `mcp` (never `NoteItAPI`'s `ClientRegistry` directly), then `Process` runs `Contents/Helpers/noteit mcp store-token --profile <profileName>` with the token written to its stdin pipe; on failure the new client is revoked through `AutomationService.clients` and the error shown; snippet with Copy and the config file location. It's presented from **Set Up an AI App…** in Settings › Integrations' connected apps section (`automation`), which also lists and revokes MCP clients. If that entry hasn't landed yet, the sheet stays unreachable from the UI and `noteit mcp setup` is the way in.
- [ ] Settings › Smart Features: the AI apps row is a short explanation and **Open Integrations…**, which opens `noteit://settings?tab=integrations` through `SettingsTabRouter`. No client list, no setup and no revoke here.
- [ ] Tests: `LocalAPIBackend` against a `URLProtocol` stub (status and `APIErrorCode` mapping including `423 note_locked`, request paths and bodies, `capabilities` parsing); `store-token` rejects `default`, `mcp-` and `mcp_bad`, and accepts `mcp` and `mcp-claude-desktop`; daily `501 not_implemented` maps to `.notImplemented` and a search `501 not_available` to `.notAvailable`.
- [ ] Verify: end-to-end in `.selftest/mcp`: run the app with the Local API on, create a read-only profile, then
  `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' | <cli> mcp --profile mcp-other`
  prints one line listing five read tools and no write tools; repeat with a write profile and `--allow-write` and see seven tools. Connect Claude Desktop or VS Code with the generated snippet and run a search.
- [ ] Commit `feat(mcp): add noteit mcp subcommand and setup`.

#### Task 20: Search modes for the Local API (needs `automation` and T6)
**Files:** create `Sources/NoteIt/Smart/SmartSearchModes.swift`, `Tests/NoteItTests/SmartSearchModesTests.swift`; modify `Smart/SmartController.swift` (register on start, toggle the capability), `Smart/SmartSearchService.swift` (if needed). No edits to `automation`'s route table or search handler.
- [ ] `SmartSearchModes.register`: `LocalAPIRouteRegistry.registerSearchMode("meaning", handler:)` and `registerSearchMode("hybrid", handler:)`. A handler receives only the `SearchQuery` and the `LocalAPIContext` (the frozen `SearchModeHandler`). The `hybrid` handler runs the shared keyword search itself on the main actor (`AutomationService.search(_:notebook:tag:limit:)`, the same search `mode=keyword` uses) and passes those note IDs to `SmartSearchService.hybrid(query:keyword:limit:)`; `meaning` passes an empty keyword list; `meaning` returns only notes with `.meaning`. Locked notes never come back from the meaning side (they aren't indexed); keyword hits on locked notes keep `locked: true` and an empty preview. Each result gets `matchedBy` and an optional `score`, with automation's `highlights` format for keyword matches.
- [ ] While search by meaning is off, both handlers return `501 not_available`; unknown modes stay `automation`'s `400 bad_request`. Errors use `APIErrorCode` only, in the nested error body.
- [ ] `SmartController` calls `addCapability("meaning-search")` when search by meaning becomes available, so `GET /v1/ping` lists it in its `capabilities` field, and `removeCapability("meaning-search")` (idempotent, from the foundations frozen registry) when it is turned off. The search modes stay registered; while off they return `501 not_available`.
- [ ] Tests (`SmartSearchModesTests`, through the registry with a stub request): `meaning`/`hybrid` give `501 not_available` when smart search is off; `mode=bogus` gives `400 bad_request`; with a `HashEmbedder`-backed index, a meaning-only note is returned with `matchedBy: ["meaning"]`; a locked note never appears as a meaning match; `ping` lists `meaning-search` only while on (on → off → on → off gives the right list each time); hybrid results include keyword-only notes found by the handler's own keyword search.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SmartSearchModesTests` PASS; `search_notes` through `noteit mcp` reports the mode used.
- [ ] Commit `feat(smart): register meaning and hybrid search modes` and `docs: document the MCP server` (architecture, README setup section, known limitations).

### Final

#### Task 21: Review, end-to-end checks, docs
- [ ] Review in three passes and fix findings until a pass is clean:
  - (a) privacy: every network call (only asset download and loopback), no note text in logs, deleted notes excluded everywhere, locked notes never indexed or sent to a model and shown by title only (`locked: true`, empty preview, `423 note_locked` on body reads), locking a note removes its chunks, settings off really means no files and no model loads;
  - (b) index correctness: crash between append and manifest save, model identity change, compaction, edits during embedding;
  - (c) UI: main-thread work while indexing 10,000 notes (Instruments Time Profiler, typing latency unchanged), Ask cancellation, palette stability while Related results arrive.
- [ ] Benchmarks: no generator of our own. Hand `surfaces-polish` the semantic search metrics for its benchmark suite (first build time, index size on disk, query embedding plus search p95 over 20 fixed queries), measured over a library made with its shared `NOTEIT_BENCH_FIXTURE=10000`. Expose what the suite needs: `SmartController.rebuild()` and the indexer's `drainForTesting()` for build time, `SemanticIndex.stats()` for size, `SmartSearchService.related(…)` for queries. Record the first numbers in the PR.
- [ ] Run the full suite: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5` — all pass; `swift build -c release` clean; `NOTEIT_VERSION=x-test NOTEIT_BUILD=99999999999999 NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` (exit 0), then `codesign --verify --deep --strict .selftest/app/NoteIt.app` (no output, exit 0).
- [ ] Relaunch the installed app with a copy of a real library in `NOTEIT_DATA_DIR`, confirm smart features are off, no `semantic-index/` exists, and nothing changed. Delete `.selftest`.
- [ ] Commit `docs: finish private AI documentation`.

## Self-review

- **Spec coverage:**
  - Settings tab and keys: T1, T7, T14, T19.
  - Search by meaning (model, chunking, file format, incremental indexing, pausing, baseline, brute-force search): T2–T6. Related in list and palette: T8. Blending: T5 (`related`, `fuse`), T8, T20.
  - Ask your notes (retrieval, gate, budget, prompt, streaming, citations, sources, save/copy, errors, menu, palette `?`, hotkey): T10–T13.
  - Providers (Apple with `#available`/`canImport`, local server loopback-only, proxy-free, no redirects, cloud-model block, Keychain key): T10, T11, T14.
  - Summaries, titles, tags, tags from similar notes, related notes, suggest while writing, the capture title refiner: T15, T16.
  - Locked notes (title only, `locked: true`, empty preview, never indexed, chunks removed on lock, disabled actions, `423` in MCP): T6, T13, T16, T18, T19, T20, T21.
  - MCP (stdio, versions, tools, resources with `noteit://note/<UUID>`, daily through `GET /v1/daily` and `POST /v1/daily/append`, scopes, `--allow-write`, `--launch-app`, `mcp` profiles, setup sheet and command, snippets): T17–T19. Client listing and revoking stay in Integrations. Search modes over the Local API: T20.
  - Privacy checks, benchmark metrics, docs: T9, T14, T16, T20, T21.
- **Types:** `Chunk`, `ChunkHit`, `EmbedderIdentity`, `TextGenerator`, `GenerationRequest`, `AskExcerpt`, `RankedNote`, `NotesBackend`, `MCPClientApp`, `MCPConfigSnippet`, `SmartCaptureTitleRefiner` and `SmartSearchModes` are defined once in *Frozen interfaces* and used with the same names in every task. `SemanticIndexer` conforms to foundations' `DerivedIndex`; body reads go through `NoteBodyStorage` and body writes through `editBody`. `SmartSearchService.hybrid` (T6) is what T20 calls. `MenuShortcutCommand.askNotes` and `HotkeyAction.askNotes` (case 12) are added in T13 only.
- **Placeholders:** none. Paths inside `automation`'s CLI target follow that sub-project's plan; T19 is the only task that touches its files (the `mcp` command tree and `NoteItCLI`'s dependency). T19 and T20 use `automation`'s app code only through `AutomationService.clients`, `AutomationService.search` (the hybrid handler's keyword list), `registerSearchMode`, `addCapability` and `removeCapability`.
- **Risks:** `NLContextualEmbedding` asset availability on CI (live test skips); FoundationModels symbols missing from older SDKs (`canImport` guard, CI build proves it); first-build time on Intel Macs (pausing and resumable checkpoints keep it harmless).
