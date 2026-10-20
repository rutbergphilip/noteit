# Foundations (Wave 0) Implementation Plan

**Goal:** Build the shared modules and seams that every wave 1 sub-project needs, with no user-visible change except the General settings tab becoming a scrolling form (6.5) and Restore Version in an open note becoming one Undo step (4.5). Wave 0 delivers these pieces:

- **`NoteItCore`:** a Foundation-only module, built for macOS and iOS.
- **`NoteItDoc` and `NoteItDocTestSupport`:** a portable document model with test support.
- **`NoteItDocAppKit`:** the AppKit converter for the document model.
- **`NoteItSync` additions:** the store session, feature, keyring, raw-meta and layout-registry seams.
- **`NoteStore` seams:** body storage, `BodyCodec`, `editBody`, `OpenEditorRegistry` with read-only observers, the `localNoteChange` notification, the derived-index registry, lock fields, and daily notes behind the `DailyNotes.isAvailable` gate.
- **`NoteItAPI`:** the wire types and the route and search-mode registries. The URL host registry stays in the app target.
- **`build_app.sh`:** an embeds table and inside-out signing.
- **Frozen tables:** the program's frozen tables as code constants, each checked by a test, and the General settings tab as a scrolling form with a fixed section order.
- **Roadmap:** `docs/roadmap.md` records that wave 0 is done (6.6).

After wave 0, wave 1 plans add files and register into these seams. They don't edit each other's code.

**Architecture:** The app target `NoteIt` keeps its UI, `NoteStore` and AppKit editor.

- **Moving to `NoteItCore`:** the pure parts — models, text folding, library coding, the library query, daily titles and URL grammar. The app re-exports it with `@_exported import NoteItCore`, so existing files compile unchanged.
- **Document model:** split in two. `NoteItDoc` has no AppKit. `NoteItDocAppKit` holds the `NSAttributedString` converter.
- **`NoteItSync`:** gains `StoreSession`, the single value that says which features, key and body encoding a store uses. Every engine and controller path reads it instead of reading the manifest directly.
- **New stores:** stay `formatVersion` 1 with no features. The gates only start working once a wave 1 plan turns a feature on.
- **New in the app:** registries that wave 1 plans fill in — derived indexes, open editors, API routes, search modes, capabilities and URL hosts. None of them has a user-facing entry in wave 0.

**Tech Stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftPM (swift-tools 5.10), XCTest, CryptoKit, AppKit (app and `NoteItDocAppKit` only), Sparkle 2.10, bash (`scripts/build_app.sh`).

**Spec:** [docs/specs/2026-10-19-program-design.md](../specs/2026-10-19-program-design.md), §1 (target graph), §2 (wave 0 steps), §4 (sync rules), §6 (body edits and codecs), §7 (derived indexes and per-Mac files), §9 (frozen tables) and §10 (API rules). These specs supply further detail and are cited per task:

- [markdown-storage §3.12](../specs/2026-10-19-markdown-storage-design.md)
- [linking §10](../specs/2026-10-19-linking-design.md)
- [organise §1.3](../specs/2026-10-19-organise-design.md)

---

## Moved here from other plans

| Foundations step | Moved from | What changes on the way |
|---|---|---|
| 1 `NoteItCore` | mobile Tasks 0.1–0.3, organise T1 (fold + `FuzzyMatcher`) | Package gets `platforms: [.macOS(.v14), .iOS(.v17)]` and library products. `ImportHygieneTests` cover every portable target. `SidebarSelection` gets the §9 cases now. |
| 2 `NoteItDoc*` | web-app Phase 0 Tasks 0.1–0.3 and the `AttachmentLimit` part of Task 0.6, mobile Task 0.5 | Split into `NoteItDoc` / `NoteItDocAppKit` / `NoteItDocTestSupport`. Adds the markdown-storage §3.12 asks (`codeBlock.language`, `BodyContainer.frontMatter`, unknown keys kept, `ImagePolicy` as a pure enum in `NoteItDoc` applied by `NoteItDocAppKit`, self-contained `.noteitdoc` files), the `noteit:` href allowlist and `AttachmentLimit`. The editor's enforcement of the cap and `PassphraseHint` stay in web-app Task 0.6. |
| 3 `NoteItSync` seams | sync-security M0 (Tasks 0.1, 0.2) plus the keyring value types from its Task 4.1; `PendingBody` and `SyncState.pendingBodyVersions` from web-app Task 0.4 | `PendingBody` and `pendingBodyVersions` keep web-app's shape and are declared and persisted but unused in wave 0, so sync-security's rekey precondition (wave 2) and web-app's doc-body publish (wave 3) share one field. `StoreFeature` has the four §4 names; `rekey` is a manifest field, not a feature. `StoreFeature.supported` controls what this build can open; it is empty in 3.1–3.2, and 3.3 adds `keyring` together with `connectSession` and the keyring cipher, so wave 0 ends with `[keyring]`. `DeviceInfo` gains `platform`, and `SyncEngine.init` gains `platform: DevicePlatform = .mac`. `RecordSealing` is `storeKey`, `spaceKey` or `unsealed`, and every `RemotePrefix` carries its key depth. Listing allows registered prefixes and their parent roots. `RekeyRunner` stays in sync-security; only its scope rule is written down here. |
| 4 `NoteStore` seams | markdown-storage M1, organise T3 (`editBody`, `OpenEditorRegistry`, `DerivedIndex` registry), plugins (`localNoteChange`), sync-security `NoteMeta.lock`/`isLocked`, linking `NoteStore+Daily` + `DailyLogAppender` + `DailyLogLine` | Search index v2 stays in organise. `DerivedIndex` has the program §7 hooks (`noteChanged`, `noteRemoved`, `metadataChanged`, `rebuild`, and a synchronous `flush`). `OpenEditorRegistry` gains `registerObserver(_:for:)` for read-only surfaces. `editBody` gains `versioning: EditBodyVersioning = .recordCurrent`, and Restore Version goes through it. `localNoteChange` carries `kind: created | edited | deleted`. Lock fields are data only. `DailyLogAppender.append` takes `DailyLogContent` (`.plain` or `.attributed`) and `timestamp: Bool = true`. Daily has no UI, no fallback provider, and sits behind `DailyNotes.isAvailable`, which is false. |
| 5 `NoteItAPI` + registries + embeds | automation T1, T17 (and the T5 `URLCommand` parser) | §10 renames (`capabilities`, no `plugin` client kind, new error codes). `LocalAPIRouteRegistry` gains `removeCapability(_:)`. Automation's `AppIdentity` additions go into the existing `NoteItSync.AppIdentity`, not a new type. `URLCommand` gets `note`/`noteTitle` and `changesNotes` (replacing `changesExistingNote`). The embeds table skips rows whose source isn't built. `NoteLink` is pulled forward from linking T1 because `URLCommand` needs it. |
| 6 Frozen tables | program §9, capture-plus Task 0 (General tab as a scrolling form) | Code constants and tests only. Hidden tabs and the `NoteCommands` rename cause no visible change. The sidebar order is a constant; the live sidebar is not reordered. The General tab changes layout only. Task 6.6 updates `docs/roadmap.md`. |

## Conventions for every task

- **Branch and commit.** Work on `feature/foundations`. Commit messages use Conventional Commits (`feat(core): …`, `refactor(app): …`, `test(sync): …`, `build: …`). Commit after each task. Never amend.
- **Toolchain prefix.** Every `swift` command is run as `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift …`. In this plan, `swift test` and `swift build` always carry that prefix.
- **Green after every task.** A task is done only when all of these pass:
  - `swift build 2>&1 | tail -3` prints `Build complete!`;
  - `swift test 2>&1 | tail -5` reports `with 0 failures`;
  - `swift build -c release 2>&1 | tail -3` prints `Build complete!`.

  Every task's Verify line runs its own filter first and then this full gate.
- **No behaviour change.** Wave 0 adds no menu items, sidebar rows, settings tabs, shortcuts, toolbar items, routes a user can reach, or file formats. New `SidebarSelection` cases show an empty list and no row is ever created for them. New settings tabs are hidden. The sidebar keeps its current order. The General tab gets the same rows in a scrolling form (Task 6.5), and Restore Version in an open note becomes one Undo step (Task 4.5); these are the only visible differences. New stores keep `formatVersion` 1, no `features`, RTFD bodies.
- **Moves keep names.** When a type moves from the app into a module, it keeps its name and its Codable keys. It gains `public` and an explicit `public init` with the same parameter order and defaults as the synthesized one. Every app call site keeps compiling through `@_exported import NoteItCore` in `Sources/NoteIt/App/CoreExports.swift`. Nothing in the app is renamed except `RecentlyDeletedCommands` → `NoteCommands` (Task 6.4).
- **Portable targets.** `NoteItCore`, `NoteItDoc`, `NoteItDocTestSupport`, `NoteItSync` and `NoteItAPI` import only Foundation, CryptoKit, CommonCrypto, Security and each other. `ImportHygieneTests` enforces it. The iOS check per portable target is:

  ```
  xcodebuild -scheme <Target> -destination 'generic/platform=iOS Simulator' build -quiet
  ```

  It is expected to print no `error:` lines. Run it in tasks that add or move files in a portable target.
- **Fixture data.** Fixture JSON lives under `fixtures/golden/` at the repo root and is read from tests through `#filePath`. Tests never write fixtures unless `NOTEIT_WRITE_VECTORS=1` is set.
- **Self-test data dirs.** The sync self-test runs as `NOTEIT_DATA_DIR=.selftest/<name> NOTEIT_SYNC_SELFTEST=1 swift run NoteIt 2>&1 | tail -1`. It prints `PASS all checks`. `.selftest/` is git-ignored.
- **Style.** No `#Preview` blocks. Comments only where a rule isn't obvious from the code. Every new public seam has a doc comment that names its owner plan.
- **Frozen means frozen.** Signatures under "Frozen interfaces" are the contract for wave 1. A task may add members, but it may not rename or retype a frozen one. Changing a frozen signature needs a program doc change first.

## Order and parallelism

```
Step 1  [serial]   1.1 → 1.2 → 1.3 → 1.4
           │
           ├── Step 2 [serial after 1]   2.1 → 2.2 → 2.3 → 2.4
           │      └── Step 3 [serial after step 2]   3.1 → 3.2 → 3.3 → 3.4 → 3.5
           │             └── Step 4 [after step 3]   4.1 → {4.2, 4.3};  4.3 → {4.4, 4.5};  4.5 → 4.6
           ├── Step 5 [parallel with 2–4, after 1]   5.3 → {5.1, 5.4};  5.1 → 5.2;  5.5 independent
           └── Step 6 [parallel with 2–5, after 1]   6.1, 6.2, 6.3, 6.4, 6.5 independent of each other
Task 6.6 [last]   after every other task is merged
```

- Steps 2, 3 and 4 run in series because each one uses the previous one's work:
  - `BodyEncoding.noteItDocV1` names the `NoteItDoc` container;
  - `BodyCodec` uses `NoteItDocAppKit`;
  - step 3 reads and extends the golden vectors from 2.4;
  - `NoteLock` is added to the `ownedCodingKeys` that 3.5 creates.
- Steps 5 and 6 touch only `Package.swift` (5.1), new files, `LinkPolicy.swift` (5.3), `scripts/build_app.sh`, `Settings/`, `Hotkeys/` and `App/`. Their shared edits with step 2 are `Package.swift`, where a new target entry is added next to another one, and `LinkPolicy.swift`, which 5.3 tightens (see Task 5.3).
- Task 5.3 builds in `NoteItCore`; its only other edit is `LinkPolicy.swift`. The `SidebarSelection` cases and their §9 order test land in Task 1.1, because the enum moves there and every `switch` over it must compile. Step 6 only cross-checks them (Task 6.3).
- Wave 1 starts once all of wave 0 is merged (program, Delivery order).

## File structure

```
Package.swift                                   # MODIFY: platforms, products, new targets (1.1, 2.1–2.3, 5.1)
docs/roadmap.md                                 # MODIFY 6.6: wave 0 done
fixtures/golden/                                # NEW: shared JSON vectors, read by Swift and TypeScript tests
  doc-validate.json                             #   2.2
  pbkdf2.json, aesgcm.json, manifest.json       #   2.4 (manifest.json gains keyring cases in 3.2)
  envelopes.json, planner.json                  #   2.4
  store-snapshot.json, engine-scenarios.json    #   2.4
  manifest-features.json                        #   3.4
  layout-keys.json                              #   3.5: key grammar, depth table, list prefixes, rekey actions
scripts/build_app.sh                            # MODIFY 5.5: EMBEDS table, inside-out signing
Sources/
  NoteItCore/                                   # NEW (Foundation only)
    Models/Notebook.swift                       #   1.1: moved from NoteIt/Model/Models.swift
    Models/NoteMeta.swift                       #   1.1: moved; + lock/isLocked (4.3)
    Models/NoteLock.swift                       #   4.3
    Models/SidebarSelection.swift               #   1.1: moved; + today, tasks, smartFolder(UUID); SidebarLibraryRow
    Models/NotebookPalette.swift                #   1.1: moved; literal hexes
    Models/CodingKeyNames.swift                 #   3.5: ownedCodingKeys for RawMetaOverlay
    Text/TextFold.swift                         #   1.2: fold (was NoteStore.fold)
    Text/FuzzyMatcher.swift                     #   1.2: moved from NoteIt/Palette
    Library/LibraryFile.swift                   #   1.3: LibraryFile + PartialLibrary
    Library/LibraryCoding.swift                 #   1.3: encoder, decoder, salvage
    Library/TrashPolicy.swift                   #   1.3: retention, purgeDate, isExpired, deletionSummary
    Library/LibraryQuery.swift                  #   1.4: notes(for:search:) as a pure function
    Capture/CaptureTitle.swift                  #   1.3: title from the first line
    Daily/DailyNoteTitle.swift                  #   4.6: DailyTitleFormat, DayKey, DailyNoteTitle
    Daily/DailyLogLine.swift                    #   4.6
    Daily/DailyNotes.swift                      #   4.6: the isAvailable gate (false in wave 0)
    NoteLink.swift                              #   5.3 (shape owned by linking)
    URLCommand.swift                            #   5.3 (shape owned by automation); AppendPosition
  NoteItDoc/                                    # NEW 2.1 (Foundation only)
    DocSchema.swift, DocNode.swift, Mark.swift, JSONValue.swift
    BodyContainer.swift, Attachment.swift
    DocValidation.swift, LinkPolicy.swift
    BlockSentinels.swift, BlockKind.swift       #   BlockKind and the sentinels moved from NoteIt/Editor
    CodeLanguage.swift                          #   moved from NoteIt/Editor/SyntaxHighlighter.swift
    AttachmentLimit.swift                       #   2.1 (from web-app Task 0.6)
    ImagePolicy.swift                           #   2.1: pure enum; NoteItDocAppKit applies it
  NoteItDocAppKit/                              # NEW 2.3 (AppKit; macOS only)
    DocConverter.swift, DocConverter+Export.swift, DocConverter+Import.swift
    DocStyleProvider.swift, ImageNormalizer.swift   # ImageNormalizer applies NoteItDoc.ImagePolicy
  NoteItSync/
    Migration/AppIdentity.swift                 #   MODIFY 5.1: automation's three constants (urlScheme, keychain services)
    Model/Manifest.swift                        #   MODIFY 3.1: features, keyring, rekey
    Model/SyncTypes.swift                       #   MODIFY 3.1: DevicePlatform; DeviceInfo platform, appVersion, supportedFeatures, rekeyAck; RemoteEnvelope Equatable
    Model/SyncState.swift                       #   MODIFY 3.1: keyID, PendingBody, pendingBodyVersions
    Model/RawMetaOverlay.swift                  #   NEW 3.5
    Crypto/Keyring.swift                        #   NEW 3.2: Keyring, Rekey, KeyIdentity, StoreCredential
    Crypto/KeyDerivation.swift                  #   MODIFY 3.2: normalized
    Engine/SyncEngine.swift                     #   MODIFY 3.1, 3.3: SyncError cases, version gate, session init
    Engine/StoreSession.swift                   #   NEW 3.1 (StoreFeature, StoreSessionKind), 3.3 (StoreSession, ref)
    Engine/SyncEngine+Session.swift             #   NEW 3.3: connectSession, refreshedSession
    Engine/SyncEngine+Features.swift            #   NEW 3.4: updateManifest, updateRekey, devicesBlocking, ensureFeature
    Engine/RemoteLayout.swift                   #   MODIFY 3.5: prefix registry with depth and sealing, key grammar
    Engine/RekeyScope.swift                     #   NEW 3.1 (RekeyBlocker), 3.5 (RekeyScope)
  NoteItAPI/                                    # NEW 5.1 (Foundation, plus Network for automation's server)
    Wire/*.swift                                #   5.1: automation's frozen wire types (AppIdentity stays in NoteItSync)
    Server/HTTPMessage.swift                    #   5.1: HTTPHeaders, HTTPRequest, HTTPResponse
    CLIVersion.swift                            #   5.1: the CLI's version, from the enclosing app's Info.plist
    Server/RouteMatch.swift, Server/OriginDecision.swift      # 5.2
    Server/ClientRegistry.swift                 #   5.2: ClientRecord only (automation adds the rest)
    Server/LocalAPIContext.swift, Server/LocalAPIRouteRegistry.swift  # 5.2
  NoteItCLI/main.swift                          # NEW 5.1: --version stub and CLIExit; not bundled yet
  NoteIt/
    App/CoreExports.swift                       #   NEW 1.1: @_exported imports of the portable targets
    App/NoteCommands.swift                      #   RENAMED 6.4 from RecentlyDeletedCommands.swift
    App/PlannedMenuShortcuts.swift              #   NEW 6.1
    Model/Models.swift                          #   MODIFY 1.1: keeps the AppKit and SwiftUI color helpers
    Model/NoteStore.swift                       #   MODIFY 1.2–1.4, 3.5 (purge deletes raw meta after the library save), 4.1 (persistNow), 4.3, 4.4, 4.5 (localNoteChange posts)
    Model/NoteStore+Sync.swift                  #   MODIFY 3.5: raw meta on apply and export
    Model/NoteStore+RawMeta.swift               #   NEW 3.5
    Model/NoteBodyStorage.swift                 #   NEW 4.1
    Model/RTFDBodyStorage.swift                 #   NEW 4.1
    Model/NoteStore+BodyExtras.swift            #   NEW 4.1: bodyExtras and the two-phase RTFD body-extras sidecar
    Model/BodyCodec.swift                       #   NEW 4.2
    Model/DerivedIndex.swift                    #   NEW 4.4
    Model/NoteStore+BodyEdits.swift             #   NEW 4.5: editBody (undo restores text and extras), EditBodyVersioning, localNoteChange
    Model/VersionHistory.swift                  #   MODIFY 4.5: versions keep extras; restoreVersion goes through editBody
    Model/NoteStore+Daily.swift                 #   NEW 4.6
    Model/DailyLogAppender.swift                #   NEW 4.6
    Editor/EditorStyles.swift                   #   MODIFY 2.1: BlockKind and sentinels now come from NoteItDoc; 2.3: drops noteItCodeLanguageID off code
    Editor/CodeStyler.swift                     #   MODIFY 2.3: setLanguage also sets noteItCodeLanguageID
    Editor/SyntaxHighlighter.swift              #   MODIFY 2.1: CodeLanguage now comes from NoteItDoc
    Editor/AppDocStyleProvider.swift            #   NEW 2.3
    Editor/OpenEditorRegistry.swift             #   NEW 4.5: editors and read-only observers
    Editor/RichTextEditor.swift                 #   MODIFY 4.5: registers its text view
    Sync/SyncController.swift                   #   MODIFY 3.1, 3.3: new errors, connectSession
    Automation/URLScheme/URLRouteRegistry.swift #   NEW 5.4
    Hotkeys/HotkeyOrder.swift                   #   NEW 6.2
    Hotkeys/HotkeyAction.swift                  #   MODIFY 6.2: hotkeyID and init?(hotkeyID:) via HotkeyOrder
    Settings/SettingsView.swift                 #   MODIFY 6.3: 10 tabs, 5 available
    Settings/GeneralSettingsView.swift          #   MODIFY 6.5: scrolling grouped Form, GeneralSettingsSection order, GeneralSettingsLayout
    Settings/Preferences.swift                  #   MODIFY 4.6: daily-note keys
Tests/
  Support/NoteItDocTestSupport/                 # NEW 2.2 (Foundation only; test-only target)
    RandomDocGenerator.swift, GoldenFixtures.swift
  NoteItCoreTests/                              # NEW 1.1
    ImportHygieneTests.swift, ModelCodingTests.swift, SidebarOrderTests.swift   # 1.1
    FuzzyMatcherTests.swift (moved), TextFoldTests.swift                        # 1.2
    LibraryCodingTests.swift, TrashPolicyTests.swift, CaptureTitleTests.swift  # 1.3
    LibraryQueryTests.swift                                                     # 1.4
    NoteLockTests.swift                                                         # 4.3
    DailyNoteTitleTests.swift, DailyLogLineTests.swift                          # 4.6
    NoteLinkTests.swift, URLCommandTests.swift                                  # 5.3
  NoteItDocTests/                               # NEW 2.1
    DocSchemaTests.swift, BodyContainerTests.swift, DocValidationTests.swift    # 2.1
    AttachmentLimitTests.swift, ImagePolicyTests.swift                          # 2.1
    GoldenDocTests.swift                                                        # 2.2
  NoteItDocAppKitTests/                         # NEW 2.3
    DocConverterRoundTripTests.swift, ConverterCodeBlockTests.swift, ImageNormalizerTests.swift
  NoteItSyncTests/
    GoldenVectorTests.swift, Support/VectorIO.swift                 # 2.4
    ManifestFeatureTests.swift, KeyringTests.swift                  # 3.1, 3.2
    StoreSessionTests.swift, EnsureFeatureTests.swift               # 3.3, 3.4
    RemoteLayoutRegistryTests.swift, RawMetaOverlayTests.swift      # 3.5
  NoteItAPITests/                               # NEW 5.1
    WireTypeTests.swift, CLIVersionTests.swift                      # 5.1
    LocalAPIRouteRegistryTests.swift                                # 5.2
  NoteItTests/
    RawMetaStoreTests.swift                                         # 3.5
    PurgeAuxFilesTests.swift                                        # 3.5 (extended in 4.1, 4.5)
    BodyStorageContract.swift, RTFDBodyStorageTests.swift          # 4.1 (BodyStorageContract is a helper, not a test case)
    BodyExtrasTests.swift                                           # 4.1
    CodeLanguageIDTests.swift                                       # 2.3
    BodyCodecTests.swift, DerivedIndexRegistryTests.swift           # 4.2, 4.4
    BodyEditTests.swift, OpenEditorObserverTests.swift              # 4.5
    LocalNoteChangeTests.swift, DailyNoteStoreTests.swift           # 4.5, 4.6
    URLRouteRegistryTests.swift                                     # 5.4
    MenuShortcutDefaultsTests.swift, HotkeyActionTests.swift        # 6.1, 6.2
    SettingsTabTests.swift, NoteCommandsTests.swift                 # 6.3, 6.4
    GeneralSettingsSectionTests.swift                               # 6.5
```

## Frozen interfaces

These are the seams wave 1 builds on. Where another plan owns a shape, the comment says so and wave 0 builds it exactly as that plan's Frozen interfaces section writes it. If the two differ, the program doc wins, then the owner plan's text. Everything in a portable target is `public` and `Sendable`. Everything in the app target is internal and `@MainActor` unless noted.

### NoteItCore (step 1, plus 4.3, 4.6, 5.3)

```swift
// Models/Notebook.swift: moved unchanged (keys, order, defaults). organise adds `parent: UUID?` later
// (in the revision fields only when set); the API DTO field is `parentID`.
public struct Notebook: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID; public var name: String; public var symbol: String; public var colorHex: String
    public var sortIndex: Int; public var revision: UUID?; public var modifiedAt: Date?
    public init(id: UUID = UUID(), name: String, symbol: String, colorHex: String, sortIndex: Int,
                revision: UUID? = nil, modifiedAt: Date? = nil)
}

// Models/NoteMeta.swift: moved unchanged; lock added in Task 4.3.
public struct NoteMeta: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID; public var notebookID: UUID?; public var title: String; public var preview: String
    public var isPinned: Bool; public var createdAt: Date; public var updatedAt: Date; public var tags: [String]
    public var revision: UUID?; public var conflictSource: String?; public var conflictOriginalID: UUID?
    public var deletedAt: Date?
    public var lock: NoteLock?                               // Task 4.3; data only, owned by sync-security
    public var isLocked: Bool { get }                        // lock != nil
    public var displayTitle: String { get }                  // "New Note" when title is empty (moved from Models.swift)
    public init(/* existing memberwise order and defaults */ lock: NoteLock? = nil)
}
public struct NoteLock: Codable, Hashable, Sendable { public var keyID: String; public var sealedID: UUID
    public init(keyID: String, sealedID: UUID) }

// Models/SidebarSelection.swift
public enum SidebarSelection: Hashable, Sendable {
    case allNotes, pinned, recent, conflicts, recentlyDeleted, notebook(UUID)
    case tag(String)                                         // the tag path; a flat tag is a one-segment path
    case today                                               // linking; empty list until linking ships
    case tasks                                               // organise; empty list until organise ships
    case smartFolder(UUID)                                   // organise; empty list until organise ships
}
/// Program §9 sidebar order for the fixed library rows. Wave 0 doesn't reorder the live sidebar; each
/// owner places its row by this list when it adds one.
public enum SidebarLibraryRow: String, CaseIterable, Sendable {
    case allNotes, today, tasks, pinned, recent, conflicts, recentlyDeleted
}

// Models/NotebookPalette.swift
public enum NotebookPalette { public static let colors: [String]; public static let symbols: [String] }   // literal hex strings

// Models/CodingKeyNames.swift (Task 3.5): the keys this build writes, for RawMetaOverlay ownedKeys.
extension NoteMeta { public static let ownedCodingKeys: Set<String> }
extension Notebook { public static let ownedCodingKeys: Set<String> }

// Text/TextFold.swift and Text/FuzzyMatcher.swift
public enum TextFold { public static func fold(_ s: String) -> String }   // the body of today's NoteStore.fold
public struct FuzzyMatch: Equatable, Sendable { public let score: Int; public let matchedIndices: [Int]; public init(score: Int, matchedIndices: [Int]) }   // stored types as today
public struct FuzzyQuery: Sendable { public init(_ text: String); public var isEmpty: Bool { get } }   // other members as today
public enum FuzzyMatcher {                                // today's API made public, scoring unchanged
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch?
    public static func match(_ query: FuzzyQuery, in candidate: String) -> FuzzyMatch?
    public static func evaluate(_ query: FuzzyQuery, in candidate: String) -> (match: FuzzyMatch, isExact: Bool)?
    public static func foldedCodes<S: StringProtocol>(_ string: S) -> [UInt32]
}

// Library/LibraryFile.swift, LibraryCoding.swift, TrashPolicy.swift
public struct LibraryFile: Codable, Sendable {
    public var version: Int; public var notebooks: [Notebook]; public var notes: [NoteMeta]
    /// 3.5: local only, never synced. The `RecordPayload.revision` of the last remote meta applied to each record,
    /// saved in the same library write as the applied record. nil (omitted) when nothing has been applied.
    public var appliedRemoteRevisions: AppliedRemoteRevisions?
}
/// 3.5; keys are uppercase uuidString. One map per RawMetaKind kept in library.json. A later raw-meta kind keeps
/// its map in its own data-folder file, saved in the same write as its records, and adds no field here.
public struct AppliedRemoteRevisions: Codable, Sendable, Equatable {
    public var notes: [String: UUID]; public var notebooks: [String: UUID]
}
public struct PartialLibrary: Decodable, Sendable { public var notebooks: [Notebook]?; public var notes: [NoteMeta]? }   // salvage decode, unchanged
public enum LibraryCoding {
    public static let encoder: JSONEncoder                   // prettyPrinted + sortedKeys, iso8601 (today's NoteStore.encoder)
    public static let decoder: JSONDecoder                   // iso8601
    public static func decode(_ data: Data) throws -> LibraryFile
    public static func salvage(_ data: Data) -> PartialLibrary?   // today's partial decode
}
public enum TrashPolicy {
    public static let retention: TimeInterval                // 30 days, today's recentlyDeletedRetention
    public static func purgeDate(deletedAt: Date) -> Date
    public static func isExpired(deletedAt: Date, now: Date) -> Bool
    public static func deletionSummary(deletedAt: Date, now: Date) -> String   // today's NoteStore.deletionSummary text
}

// Library/LibraryQuery.swift
public enum LibraryQuery {
    public static let recentInterval: TimeInterval           // 7 days
    /// The single filter/sort/search for every SidebarSelection case (Mac list, organise, phone).
    /// `indexedText` returns a note's folded search text from the caller's index, or nil to fall back to
    /// TextFold.fold(title + "\n" + preview). Every folded search term must occur in it.
    public static func notes(_ all: [NoteMeta], for selection: SidebarSelection?, search: String, now: Date,
                             indexedText: (UUID) -> String?) -> [NoteMeta]
    public static func count(_ all: [NoteMeta], for selection: SidebarSelection, now: Date) -> Int
}

// Capture/CaptureTitle.swift
public enum CaptureTitle {
    public static let maxLength = 60; public static let scanLimit = 4_096
    public static func firstLine(of text: String) -> String?  // first non-empty line within scanLimit (today's private firstLine)
    public static func singleLine(_ text: String?) -> String? // whitespace collapsed, nil when empty
    public static func truncated(_ title: String) -> String   // at most maxLength characters, word boundary + "…" (today's truncatedTitle)
}

// Daily/DailyNoteTitle.swift and Daily/DailyLogLine.swift (Task 4.6; linking owns behaviour)
public enum DailyTitleFormat: String, CaseIterable, Codable, Sendable { case iso, long, weekdayLong }
public struct DayKey: Hashable, Comparable, Codable, Sendable {
    public var year: Int; public var month: Int; public var day: Int
    public init(year: Int, month: Int, day: Int)
    public init(_ date: Date, calendar: Calendar)
    public func date(calendar: Calendar, hour: Int = 0) -> Date?
}
public enum DailyNoteTitle {
    /// iso "2026-10-19", long "19 October 2026", weekdayLong "Monday, 19 October 2026" (month and weekday in `locale`).
    public static func title(for day: DayKey, format: DailyTitleFormat, locale: Locale) -> String
    /// Parses `title` in every `DailyTitleFormat` (all of `allCases`, not just the chosen one), so a note titled
    /// under an earlier format is still found after the user switches; nil when no format matches.
    public static func parse(_ title: String, locale: Locale) -> DayKey?
}
public enum DailyLogLine {
    public static let maxTextLength = 2_000
    /// "- HH:mm text" (timestamp true) or "- text" (timestamp false), 24-hour, en_US_POSIX. Newlines and tabs
    /// become spaces, runs collapse, trimmed, capped at maxTextLength characters; nil when nothing is left.
    public static func format(text: String, at date: Date, timeZone: TimeZone, timestamp: Bool = true) -> String?
    /// "- HH:mm " or "- ": what DailyLogAppender puts before attributed content.
    public static func prefix(at date: Date, timeZone: TimeZone, timestamp: Bool = true) -> String
}
/// Program §5 gate. While false: Append to Today is unavailable, the daily API routes return
/// 501 not_implemented, and the daily CLI commands and the `daily` and `append?daily=` URL hosts are
/// unavailable. Linking changes the literal to true in the task that ships the daily-note UI.
public enum DailyNotes { public static let isAvailable = false }

// NoteLink.swift (Task 5.3; shape owned by linking, frozen there)
public enum NoteLink: Equatable, Hashable, Sendable {
    case note(id: UUID, heading: String?)
    case unresolved(title: String, heading: String?)
    public static let maxTextLength = 120
    public init?(url: URL)
    public var url: URL { get }
    public var heading: String? { get }
    public func withHeading(_ heading: String?) -> NoteLink
}
public struct LinkQuery: Equatable, Sendable { public var title: String; public var heading: String?; public var alias: String?
    public init(_ raw: String) }                                    // text typed after "[[" (linking)

// URLCommand.swift (Task 5.3; shape owned by automation, frozen there: XCallback, URLCommandError,
// URLCommand with note/noteTitle/new/shareInbox/append/open/search/daily/settings/registered,
// AppendTarget, OpenTarget, reservedHosts, settingsTabs, maxTextBytes, changesNotes, parse, callbackURL).
// changesNotes replaces changesExistingNote: true for new and append (id, title, daily); false for shareInbox,
// which is exempt from confirmation, and for every command that only opens or shows something.
// AppendPosition moves here from automation's wire types so NoteItCore doesn't depend on NoteItAPI;
// NoteItAPI re-exports it with `public typealias AppendPosition = NoteItCore.AppendPosition`.
public enum AppendPosition: String, Codable, Sendable { case end, start }
```

### NoteItDoc, NoteItDocAppKit, NoteItDocTestSupport (step 2)

```swift
// NoteItDoc: Foundation only, depends on NoteItCore. Mirrors @noteit/doc (web-app plan); the TS file is the reference
// for node and mark JSON.
public enum Align: String, Codable, Sendable { case left, center, right, justify }
public enum Mark: Codable, Hashable, Sendable {
    case bold, italic, underline, strike, code
    case link(href: String), textColor(String), highlight(String), fontSize(delta: Int)
}
public enum Inline: Codable, Hashable, Sendable {
    case text(String, marks: [Mark]), hardBreak
    case image(sha: String, name: String, mime: String, width: Double?)
    case attachment(sha: String, name: String, mime: String)
}
public enum ListKind: String, Codable, Sendable { case bullet, ordered, task }
public indirect enum DocNode: Codable, Equatable, Sendable {
    case doc([DocNode])
    case paragraph(align: Align?, indent: Int?, content: [Inline])
    case heading(level: Int, align: Align?, indent: Int?, content: [Inline])
    case codeBlock(align: Align?, language: String?, content: [Inline])     // language kept, never edited (markdown-storage §3.12)
    case blockquote(indent: Int?, content: [DocNode])
    case horizontalRule
    case listItem(kind: ListKind, level: Int, number: Int?, checked: Bool?, align: Align?, content: [Inline])
    case table(columnWidths: [Double]?, rows: [[TableCell]])
    case unknown(type: String, json: Data)                                    // kept byte-for-byte; makes the doc read-only
}
public struct TableCell: Codable, Equatable, Sendable { public var header: Bool; public var content: [DocNode] }
public struct Attachment: Codable, Equatable, Sendable { public var mime: String; public var name: String; public var data: Data }
public struct BodyContainer: Codable, Equatable, Sendable {
    public static let format = "noteit-doc"; public static let currentVersion = 1
    public static let fileExtension = "noteitdoc"            // standalone, self-contained container files (attachments inside)
    public var format: String; public var version: Int; public var doc: DocNode
    public var attachments: [String: Attachment]             // key: lowercase hex SHA-256 of data
    public var frontMatter: String?                          // kept, never shown (markdown-storage §3.12)
    public var extra: [String: JSONValue]                    // unknown top-level keys, re-encoded unchanged
    public init(doc: DocNode, attachments: [String: Attachment] = [:], frontMatter: String? = nil)
    public var extras: ContainerExtras { get set }           // frontMatter and extra, read or replaced together
    public func encoded() throws -> Data                     // sortedKeys, the byte form golden vectors use
    public static func decode(_ data: Data) throws -> BodyContainer
}
/// The container fields that the editor's NSAttributedString can't hold. BodyCodec hands them out on read and takes
/// them back on write, so they survive read → edit → write. frontMatter has BodyContainer.frontMatter's type.
public struct ContainerExtras: Equatable, Sendable {
    public var frontMatter: String?
    public var extra: [String: JSONValue]                    // unknown top-level keys
    public static let empty: ContainerExtras                 // nil, [:]
    public init(frontMatter: String? = nil, extra: [String: JSONValue] = [:])
}
/// Numbers are lossless: `number` holds the original token (for example "9007199254740993" or "1.50"), checked
/// against the JSON number grammar on decode and written back verbatim. Never converted through Double.
public enum JSONValue: Codable, Equatable, Sendable { case null, bool(Bool), number(String), string(String), array([JSONValue]), object([String: JSONValue]) }
extension JSONValue {
    /// The same scanner and verbatim token writer BodyContainer uses, for other JSON files (the body-extras sidecar, 4.1).
    public func encoded() throws -> Data                     // sortedKeys, numbers written as their token
    public static func decode(_ data: Data) throws -> JSONValue
}
public enum DocValidation: Equatable, Sendable {
    case valid, readOnly(reason: String)
    public static func validate(_ c: BodyContainer) -> DocValidation
}
public enum LinkPolicy {
    public static let schemes: [String]                     // ["http", "https", "mailto", "tel", "noteit"]; same list as TS LINK_SCHEMES
    public static func allows(_ href: String) -> Bool
}
public enum BlockSentinels {                                 // moved from EditorStyle; values unchanged
    public static let body: Double, code: Double, quote: Double, divider: Double, title: Double, heading: Double, subheading: Double
}
public enum BlockKind: String, CaseIterable, Identifiable, Sendable {   // moved from EditorStyles.swift
    case title, heading, subheading, body, code, quote, divider
    public var id: String { rawValue }
}
public enum CodeLanguage: Int, CaseIterable, Identifiable, Sendable { /* moved unchanged from SyntaxHighlighter.swift */ }
/// Pure policy value; NoteItDocAppKit's ImageNormalizer applies it, so NoteItDoc has no ImageIO code.
public enum ImagePolicy: String, Codable, Sendable { case normalize, keepOriginal }   // normalize: TIFF/BMP → PNG, HEIC → JPEG 0.9
public enum AttachmentLimit {                                // shape owned by the web-app plan (Task 0.6)
    public static let maxBytes = 26_214_400                  // 25 MB per attachment, same as TS MAX_ATTACHMENT_BYTES
    public static func allows(byteCount: Int) -> Bool        // byteCount <= maxBytes
    public static func tooLargeMessage(name: String) -> String // "“<name>” is too large to add. Attachments can be up to 25 MB."
}

// NoteItDocAppKit: macOS only, depends on NoteItDoc. Shapes owned by the web-app plan.
public protocol DocStyleProvider {
    var baseFontSize: CGFloat { get }
    func font(for block: BlockKind, size: CGFloat) -> NSFont
    func monospacedFont(size: CGFloat) -> NSFont
}
public enum DocConverter {
    public static func export(_ text: NSAttributedString, styles: DocStyleProvider, imagePolicy: ImagePolicy = .normalize) throws -> BodyContainer
    public static func importDocument(_ body: BodyContainer, styles: DocStyleProvider) throws -> NSAttributedString
}
public enum ImageNormalizer { public static func normalized(_ data: Data, mime: String, policy: ImagePolicy) -> (data: Data, mime: String) }
extension NSAttributedString.Key {
    /// A code paragraph's `codeBlock.language` identifier as written, known to `CodeLanguage` or not (Task 2.3).
    /// Value: String. The only paragraph attribute NoteItDocAppKit adds.
    public static let noteItCodeLanguageID: NSAttributedString.Key
}

// NoteItDocTestSupport: test-only library at Tests/Support/NoteItDocTestSupport, Foundation only.
/// Default: every node except .unknown, so output validates as .valid and round-trips through the AppKit
/// converter. includeUnknown: true also emits .unknown nodes; only NoteItDoc codec and validator tests use it.
public struct RandomDocGenerator { public init(seed: UInt64, includeUnknown: Bool = false); public mutating func next() -> BodyContainer }
public enum GoldenFixtures {
    public static var directory: URL { get }                 // <repo>/fixtures/golden, from #filePath
    public static func load<T: Decodable>(_ name: String, as: T.Type) throws -> T
    public static func write<T: Encodable>(_ value: T, to name: String) throws   // only when NOTEIT_WRITE_VECTORS=1
}
```

### NoteItSync (step 3)

Built as sync-security's Frozen interfaces section "NoteItSync: manifest, keyring, sessions (foundations step 3)" writes them. That covers:

- `Manifest` (with the `features`, `keyring` and `rekey` fields), `StoreFeature`, `StoreSessionKind`, `BodyEncoding`, `StoreSession` and `StoreSessionRef`;
- `Keyring`, `Rekey`, `KeyIdentity`, `StoreCredential` and `KeyDerivation.normalized`;
- `RawMetaOverlay`, `RecordSealing`, `RemotePrefix` and the `RemoteLayout` registry;
- `DeviceInfo.appVersion`, `supportedFeatures` and `rekeyAck`;
- `SyncState.keyID`;
- the new `SyncError` cases, `FeatureBlocker` and `RekeyBlocker`;
- `SyncEngine.maxFormatVersion`, `connectSession`, `refreshedSession`, `updateManifest`, `updateRekey`, `devicesBlocking(_:backend:session:currentDeviceID:)`, `ensureFeature(_:backend:session:currentDeviceID:confirm:)` with its `FeatureAddition` result, and the session-based `init`.

Program §4 decides these points, and wave 0 builds them this way even where sync-security's text still differs:

```swift
// Engine/StoreSession.swift: four features. `rekey` is a manifest field (Manifest.rekey), never a feature.
public enum StoreFeature: String, Sendable, CaseIterable {
    case noteItDoc = "noteit-doc"                 // web-app
    case keyring = "keyring"                      // sync-security
    case lockedNotes = "locked-notes"             // sync-security; requires noteItDoc
    case noteItSpace = "noteit-space"             // sharing; space sessions only
    public static let known: Set<String>          // all raw values
    /// Features this build reads. connectSession refuses a store with a feature outside `supported`
    /// (unsupportedFeature), and DeviceInfo.supportedFeatures is this set, sorted.
    /// Empty in Tasks 3.1–3.2. Task 3.3 adds .keyring in the same change as connectSession and the keyring
    /// cipher, so wave 0 ends with [.keyring] and a wave 0 build refuses noteit-doc, locked-notes and
    /// noteit-space stores.
    /// web-app adds .noteItDoc together with the Mac body conversion (web-app Tasks 0.4–0.5, wave 3);
    /// sync-security adds .lockedNotes in its locked-notes milestone (M5, wave 3, after web-app 0.4–0.5).
    /// Sharing adds .noteItSpace for space sessions only and owns the space-session acceptance logic; wave 0
    /// builds only this generic check.
    /// Engine gates take an internal `supported:` parameter defaulting to this set, so tests can widen it.
    public static let supported: Set<StoreFeature>
    /// Features that must be present before this one: lockedNotes → [noteItDoc]; others → [].
    public var requires: [StoreFeature] { get }
}

// Model/SyncTypes.swift
public enum DevicePlatform: String, Codable, Sendable, CaseIterable { case mac, ios, web }
public struct DeviceInfo { /* existing */
    public var platform: String?                  // DevicePlatform raw value; nil for older apps; unknown values kept
    public var appVersion: String?
    public var supportedFeatures: [String]?       // StoreFeature raw values this app reads; nil counts as none.
                                                  // Written from Task 3.3 on; nil before that.
    public var rekeyAck: String?                  // the rekey id (Rekey.toKeyID) this device acknowledged
}

// Engine/SyncEngine.swift (Task 3.3): the session-based init. The engine writes `platform.rawValue` into its
// device record; the phone passes .ios.
public actor SyncEngine { /* existing */
    public init(backend: StorageBackend, session: StoreSessionRef, local: SyncLocalStore, stateURL: URL,
                deviceID: String, deviceName: String, appVersion: String? = nil, platform: DevicePlatform = .mac)
}

// Engine/StoreSession.swift (Task 3.3), the same declaration as sync-security's Frozen interfaces.
public struct StoreSession: Sendable {
    public let kind: StoreSessionKind
    public let manifest: Manifest
    public let manifestETag: String               // unquoted
    public let cipher: SyncCipher
    public let keyID: String?                     // nil for unencrypted stores
    public var features: Set<StoreFeature>
    /// The `supported` set passed to connectSession. refreshedSession, updateManifest and updateRekey check
    /// against it and copy it into every session they return.
    public let supported: Set<StoreFeature>
    /// The unwrapped keyring data key: set for a keyring session (opened with .passphrase or .dataKey, or just
    /// created); nil for v1, keyring-pending, plain and passed-cipher sessions. SyncController saves it to
    /// Keychain `syncDataKey` after a passphrase connect. A session derived with the same keyID keeps it;
    /// changePassphrase and RekeyRunner (.personal) set it on the sessions they return.
    public let dataKey: SymmetricKey?
    public var formatVersion: Int { manifest.formatVersion }
    public var bodyEncoding: BodyEncoding { features.contains(.noteItDoc) ? .noteItDocV1 : .rtfd }   // never formatVersion
}

// Engine/SyncEngine+Session.swift (Task 3.3). The three trailing parameters have defaults, so wave 0 callers
// pass none of them and get today's behaviour (a new store is a featureless v1 manifest). `deviceName` has no
// default: every caller passes its device name (SyncController passes the one it gives SyncEngine.init).
extension SyncEngine {
    /// deviceName: written as Keyring.changedBy (through Keyring.make) when this call creates a keyring store;
    ///   creating one with an empty deviceName throws invalidManifest and writes nothing. Unused otherwise. The
    ///   legacy connect and connectReportingCreation wrappers pass "" (they never create keyring stores).
    /// initialFeatures: written into the first manifest only when createIfMissing creates a new store (program §4
    ///   rule 4, creation); ignored for an existing store. web-app Task 0.4 passes [.noteItDoc] (plus .keyring
    ///   for an encrypted keyring store).
    /// supported: the features this session accepts, kept as StoreSession.supported. Space sessions pass
    ///   StoreFeature.supported ∪ [.noteItSpace].
    /// cipher: when non-nil, the session uses it instead of building the legacy, keyring or passthrough cipher;
    ///   sharing passes its SpaceCipher.
    public static func connectSession(backend: StorageBackend, kind: StoreSessionKind, credential: StoreCredential?,
                                      deviceName: String, createIfMissing: Bool, encrypted: Bool,
                                      initialFeatures: Set<StoreFeature> = [],
                                      supported: Set<StoreFeature> = StoreFeature.supported,
                                      cipher: (any SyncCipher)? = nil) async throws -> (session: StoreSession, created: Bool)
}

// Engine/SyncEngine+Features.swift (Task 3.4). These are static, so they see no engine state, and StoreSession
// carries no device ID. The caller passes its own device ID (the one it gives SyncEngine.init) as
// currentDeviceID, so this device's own record never blocks, even when it is stale.
/// What ensureFeature did. lateBlockers: devices that block the feature but were not in the list `confirm`
/// saw, because their records appeared between the device check and the manifest write (program §4 rule 4:
/// the device list is a warning, not a fence). The caller shows them once as a notice. Empty when the
/// feature was already set.
public struct FeatureAddition: Sendable {
    public let session: StoreSession
    public let lateBlockers: [FeatureBlocker]
}
extension SyncEngine {
    /// Rejects a manifest whose `rekey` field is set (rekeyInProgress). Starting a rekey (setting the field)
    /// goes through here.
    public static func updateManifest(backend: StorageBackend, session: StoreSession,
                                      _ change: @Sendable (inout Manifest) throws -> Void) async throws -> StoreSession
    /// The only writer allowed while `rekey` is set (sync-security's heartbeat and finish). Every attempt,
    /// retries included, requires manifest.rekey?.toKeyID == expectedRekeyToKeyID, else it throws
    /// manifestChangedConcurrently and writes nothing. `change` may update or clear that `rekey` and the
    /// fields that move with it (keyring, encryption, and rekey's previousKeyring and previousEncryption), and
    /// nothing else.
    public static func updateRekey(backend: StorageBackend, session: StoreSession, expectedRekeyToKeyID: String,
                                   _ change: @Sendable (inout Manifest) throws -> Void) async throws -> StoreSession
    public static func devicesBlocking(_ feature: StoreFeature, backend: StorageBackend, session: StoreSession,
                                       currentDeviceID: String) async throws -> [FeatureBlocker]
    public static func ensureFeature(_ feature: StoreFeature, backend: StorageBackend, session: StoreSession,
                                     currentDeviceID: String,
                                     confirm: @Sendable ([FeatureBlocker]) async -> Bool) async throws -> FeatureAddition
}

// Engine/RemoteLayout.swift (program §4 rules 6 and 8)
/// storeKey: sealed with the session's key (the personal store key, or the space key in a space session).
/// spaceKey: objects sealed with a space key inside a personal store.
/// unsealed: signed logs, HPKE key files and the canary; RekeyRunner never re-seals them.
public enum RecordSealing: Sendable, Equatable { case storeKey, spaceKey, unsealed }
public struct RemotePrefix: Sendable, Equatable {
    public let path: String                       // full key prefix, e.g. "inkwell/v1/notes/"
    public let depth: Int                         // segments after `path`; "inkwell/v1/notes/<UUID>.meta" is 1
    public let sealing: RecordSealing
    public let owner: String                      // sub-project slug
}
extension RemoteLayout {
    public static let prefixes: [RemotePrefix]    // one literal list; wave 0: notebooks/, notes/, tombstones/, devices/
    public static func prefix(for key: String) -> RemotePrefix?   // longest matching row whose depth equals the key's
    public static let manifestKey: String         // manifest(); excluded from rekey
    // canaryPrefix ("inkwell/.canary/") already exists; keys under it are "inkwell/.canary/<UUID>", depth 1,
    // and are treated as .unsealed.
    /// Program §4 rule 8: every segment matches [A-Za-z0-9._-]+ and is not "." or ".."; a segment whose
    /// part before the first "." is a UUID must be the uppercase canonical form; the key is manifestKey, a
    /// canary key, or sits under a registered prefix at exactly the depth of a row with that path (two rows
    /// may share a path with different depths).
    public static func isValidKey(_ key: String) -> Bool
    /// True for a registered prefix path, canaryPrefix, or a parent root of either (every shorter prefix that
    /// ends at a "/", such as "inkwell/v1/" and "inkwell/"), so legacy clients (the 0.2.x engine, rclone) keep
    /// listing. The web server refuses other list requests, including "".
    public static func isListablePrefix(_ prefix: String) -> Bool
}
```

Wave 0 also adds:

```swift
/// SyncError.rekeyBlocked needs RekeyBlocker, so the enum is created in wave 0 with sync-security's cases
/// (Engine/SyncEngine+Rekey.swift is sync-security's; wave 0 puts the enum in Engine/RekeyScope.swift).
public enum RekeyBlocker: Sendable, Equatable {
    case notIdle, pendingBodyVersions(Int), storageCheckFailed(String), unknownPrefix(String), devicesNotSynced([String])
}
/// The rekey scope rule (program §4 rule 7), written down so every RemoteLayout row is checked against it.
/// RekeyRunner (sync-security) lists every key under the store root. A key whose prefix has the sealing
/// being rekeyed is re-sealed (.storeKey for a rekey of the session's key, .spaceKey when a space key changes
/// for objects in a personal store); manifestKey, canary keys, .unsealed rows and rows with the other sealing
/// are skipped; a key with no registered prefix blocks the rekey (RekeyBlocker.unknownPrefix).
/// `rekeying` is never .unsealed.
public enum RekeyScope {
    public static func action(for key: String, rekeying: RecordSealing = .storeKey,
                              prefixes: [RemotePrefix] = RemoteLayout.prefixes) -> Action
    public enum Action: Equatable, Sendable { case reseal, skip, block }
}

// Model/SyncState.swift (Task 3.1). Moved from web-app Task 0.4 with its shape, plus Sendable because SyncState is
// Sendable. Declared and persisted in wave 0, never written: web-app Task 0.4 writes it (versioned doc-body publish)
// and sync-security Task 4.3 reads its count (RekeyBlocker.pendingBodyVersions). A state file without the key decodes
// it as [:]. RemoteEnvelope gains Equatable (Model/SyncTypes.swift) because PendingBody holds one.
public struct PendingBody: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case uploading, committing, inDoubt }   // the sealed body bytes live in PendingBodies/<ID>.<VERSION>
    public var version: UUID; public var tag: String; public var phase: Phase; public var envelope: RemoteEnvelope
}
public struct SyncState { /* existing, keyID */
    public var pendingBodyVersions: [UUID: PendingBody] = [:]   // the one uncommitted or in-doubt doc-body version per note (separate map keeps old state files decodable)
}
```

### NoteItAPI (step 5)

All of automation's Frozen interfaces for `NoteItAPI/Wire/*` and `NoteItAPI/Server/HTTPMessage.swift` are built exactly as written there:

- `APIScope`, `BodyFormatDTO` and `ClientKind` (no `plugin` case);
- every DTO and request type, including `PingDTO.capabilities` and `NoteSummaryDTO.locked`;
- `APIErrorCode`, including `badRequest`, `readOnly`, `revisionMismatch`, `editorRequired`, `noteLocked`, `notImplemented`, `notAvailable` and `notReady` with the program §10 statuses, plus `APIErrorBody`. `APIErrorCode` is declared `String, Codable, Sendable, Error`, so it can be the failure type of `Result` (as in `SearchModeHandler`) and can be thrown;
- `HighlightDTO` (`{field, ranges: [[start, length]]}`, UTF-16) and `TagNodeDTO` with `totalCount`;
- `APIJSON`, `DiscoveryFile` and `APIToken`;
- `HTTPMethod`, `RouteID`, `RouteBody`, `RouteBucket`, `RouteSpec` (including its `public init(id:method:pattern:scope:body:bucket:maxBodyBytes:summary:)`) and `APIRoutes`;
- `HTTPHeaders`, `HTTPRequest` and `HTTPResponse`.

Automation's three `AppIdentity` constants (`urlScheme`, `localAPIKeychainService`, `cliKeychainService`) are added to the existing public `AppIdentity` in `Sources/NoteItSync/Migration/AppIdentity.swift`, which `scripts/build_app.sh` reads. `NoteItAPI` creates no `AppIdentity` type of its own; it and `NoteItCLI` `import NoteItSync` and use that one. `NoteItSync` depends on no other target, so this adds no cycle.

The registry and the context types it names are built in wave 0 with these shapes:

```swift
// NoteItAPI/Server/RouteMatch.swift, OriginDecision.swift, ClientRegistry.swift (ClientRecord): data only; automation adds behaviour
public struct RouteMatch: Sendable { public let spec: RouteSpec; public let params: [String: String] }
public enum OriginDecision: Equatable, Sendable { case native, extensionOrigin(String), rejected }
public struct ClientRecord: Codable, Sendable, Equatable { public var id: UUID; public var name: String; public var kind: ClientKind
    public var scopes: [APIScope]; public var origin: String?; public var tokenHash: String; public var tokenHint: String; public var createdAt: Date }
public struct LocalAPIContext: Sendable { public let request: HTTPRequest; public let route: RouteMatch
    public let client: ClientRecord?; public let origin: OriginDecision }

// NoteItAPI/Server/LocalAPIRouteRegistry.swift
public typealias LocalAPIHandler = @Sendable (LocalAPIContext) async -> HTTPResponse
// APIErrorCode: String, Codable, Sendable, Error (automation's wire type), so it can be Result's failure type.
public typealias SearchModeHandler = @Sendable (_ query: SearchQuery, _ context: LocalAPIContext) async -> Result<[SearchResultDTO], APIErrorCode>
public struct SearchQuery: Sendable { public var q: String; public var notebook: String?; public var tag: String?; public var limit: Int }
public final class LocalAPIRouteRegistry: @unchecked Sendable {        // NSLock-protected
    public static let shared: LocalAPIRouteRegistry
    public init()                                                          // tests use their own instance
    public func register(_ spec: RouteSpec, handler: @escaping LocalAPIHandler)   // traps: path conflict with APIRoutes.all or a registered route,
                                                                               // duplicate id, id not "<slug>.<name>", nil scope
    public func registerSearchMode(_ name: String, handler: @escaping SearchModeHandler)   // traps: "keyword", duplicate, not kebab-case
    public func addCapability(_ name: String)                              // traps: not kebab-case; duplicates ignored
    public func removeCapability(_ name: String)                           // idempotent: removing an absent name does nothing
    public var routes: [RouteSpec] { get }
    public var searchModes: [String] { get }                               // sorted
    public var capabilities: [String] { get }                              // sorted; the current set, which GET /v1/ping lists
    public func handler(for id: String) -> LocalAPIHandler?
    public func searchMode(_ name: String) -> SearchModeHandler?
    public func validate() -> [String]                                     // the trap conditions as messages, for tests
}

// NoteItAPI/CLIVersion.swift (5.1). AppIdentity has no version, and the version only exists in the app's
// Info.plist: scripts/build_app.sh writes CFBundleShortVersionString from $NOTEIT_VERSION (default 0.1.0).
// The CLI ships at <App>.app/Contents/Helpers/noteit (automation's embeds row), so it reads that file.
public enum CLIVersion {
    public static let unbundled = "dev"
    /// Resolves symlinks in executableURL. When it is <X>.app/Contents/Helpers/<name>, returns
    /// CFBundleShortVersionString from <X>.app/Contents/Info.plist; otherwise, or when the file or key is
    /// missing, returns `unbundled` (swift run, tests).
    public static func current(executableURL: URL? = Bundle.main.executableURL) -> String
}

// NoteItCLI/main.swift: prints "noteit \(CLIVersion.current())" for --version, exits CLIExit.usage otherwise.
enum CLIExit: Int32 { case ok = 0, error = 1, usage = 2, unreachable = 3, unauthorized = 4, notFound = 5, conflict = 6 }
```

### App target seams (steps 2, 3, 4, 5, 6)

```swift
// Editor/AppDocStyleProvider.swift (2.3)
struct AppDocStyleProvider: DocStyleProvider { static let shared: AppDocStyleProvider }   // fonts from EditorStyle

// Model/NoteStore+RawMeta.swift (3.5): the Mac's copy of the last decrypted remote JSON per record, with one
// lifecycle for every record kind that keeps raw meta (Task 3.5 lists what a later kind adds).
// Files: <rootURL>/sync-meta-raw/<kind.rawValue>/<UUID>.json, one folder per record kind, so records of different
// kinds with the same UUID never share a file.
/// rawValue is the folder name. Later kinds add a case: organise `smartFolders = "smart-folders"`, surfaces-polish
/// `boards`. The switches in appliedRemoteRevision and isDurablyListed have no default, so a new case doesn't
/// compile until it supplies both arms.
enum RawMetaKind: String, CaseIterable, Sendable { case notes, notebooks }
/// The file's content. `sourceRevision` is the `RecordPayload.revision` of the remote meta in `meta` (the revision
/// the engine records as `SyncState.Base.revision` when it applies that payload); `meta` is the decrypted bytes.
struct RawMeta: Codable, Equatable, Sendable { var sourceRevision: UUID; var meta: Data }
extension NoteStore {
    /// The revision of the last remote payload applied to the record, from that kind's own applied-revision map
    /// (notes: `LibraryFile.appliedRemoteRevisions.notes`, notebooks: `.notebooks`; a later kind's map lives in its
    /// own data-folder file). One map per kind, so kinds never collide. nil for a local-only record.
    func appliedRemoteRevision(for id: UUID, kind: RawMetaKind) -> UUID?
    /// The raw meta only when its `sourceRevision` equals `appliedRemoteRevision(for:kind:)`; otherwise nil, as if
    /// there were no file. The file stays until the next successful apply of that record replaces it.
    func lastRemoteMeta(for id: UUID, kind: RawMetaKind) -> Data?
    /// nil removes. Apply writes it before the record is applied; a throw skips that record's apply this pass.
    /// A removed record's file is not removed here (see queueRawMetaDeletion).
    func setLastRemoteMeta(_ raw: RawMeta?, for id: UUID, kind: RawMetaKind) throws
    /// Deferred deletion for a removed record of any kind except notes. Queues (kind, id), persisted with the
    /// tombstones; the pending-trash pass (trashPendingBodies, after a successful save) deletes the file once
    /// `isDurablyListed` is false, and keeps it queued when the delete throws. A purged note's file instead rides
    /// on pendingTrash and is deleted with the body's .trash move, after library.json no longer lists the note.
    func queueRawMetaDeletion(_ id: UUID, kind: RawMetaKind)
    /// Whether the kind's last successfully saved file still lists the record (notes and notebooks: library.json).
    func isDurablyListed(_ id: UUID, kind: RawMetaKind) -> Bool
}

// Model/NoteBodyStorage.swift (4.1); markdown-storage adds MarkdownBodyStorage, sync-security the sealed-file methods.
enum LibraryFormatKind: String, Codable, Sendable { case rtfd, markdown }
/// extras: the container fields kept beside the text (ContainerExtras). RTFDBodyStorage always reads .empty and ignores
/// extras on write; on an RTFD store NoteStore keeps them in the body-extras sidecar instead (NoteStore+BodyExtras.swift).
struct StoredBody { var text: NSAttributedString; var readOnlyReason: String? = nil; var extras: ContainerExtras = .empty }
extension StoredBody {
    /// readOnlyReason of an RTFD note whose body-extras sidecar exists but can't be read or decoded (4.1).
    static let bodyExtrasUnreadable: String
}
protocol NoteBodyStorage: AnyObject, Sendable {
    var kind: LibraryFormatKind { get }
    var contentRootURL: URL { get }                           // RTFD: <rootURL>/notes
    func idsOnDisk() -> [UUID]
    func read(_ id: UUID) throws -> StoredBody                // throws CocoaError(.fileReadNoSuchFile) when missing
    func write(_ text: NSAttributedString, extras: ContainerExtras, for note: NoteMeta, notebook: Notebook?) throws
    func writeMetadataOnly(for note: NoteMeta, notebook: Notebook?) throws   // RTFD: no-op
    func prepareTemp(_ text: NSAttributedString, extras: ContainerExtras, for id: UUID) throws -> URL // safe off the main actor
    func installTemp(_ temp: URL, for note: NoteMeta, notebook: Notebook?) throws
    func moveToTrash(_ id: UUID) throws                        // RTFD: <rootURL>/.trash/<id>-<timestamp>.rtfd
    func recover(_ id: UUID) throws -> StoredBody?             // the newest trashed copy, if any
    func removePermanently(_ id: UUID) throws
    func revisionInputURL(for id: UUID) -> URL?                // what contentRevisions hashes; RTFD: the .rtfd package
    func fileURL(for id: UUID) -> URL                          // RTFD: today's bodyURL(for:)
    func recoveryCopy(_ text: NSAttributedString, for id: UUID, in directory: URL) throws -> URL
    func renameNotebook(_ notebook: Notebook, from oldName: String) throws   // RTFD: no-op
    func removeNotebook(_ notebook: Notebook) throws                         // RTFD: no-op
}
final class RTFDBodyStorage: NoteBodyStorage, @unchecked Sendable {
    init(rootURL: URL)
    /// Lowercase hex SHA-256 over the package's regular files, sorted by relative path, each as its UTF-8 path,
    /// a 0 byte, its 8-byte big-endian length and its bytes. Stable for the same package on disk; the sidecar's and
    /// Version History's bodySHA256.
    static func packageDigest(at url: URL) throws -> String
}
extension NoteStore {
    var bodyStorage: NoteBodyStorage { get }                  // RTFDBodyStorage(rootURL:) in wave 0
    /// The extras of each loaded body, keyed by note ID. Set from every body read (from the file, or on an RTFD store
    /// from the sidecar) and from sync apply once its body is installed (a failed apply leaves it unchanged);
    /// passed to every body write (editor save, updateBody, editBody, sync apply, which passes the incoming extras);
    /// replaced by editBody's non-nil `extras` in the same write; dropped when the note is purged.
    var bodyExtras: [UUID: ContainerExtras] { get }           // internal(set) — written only via setBodyExtras(_:for:) in NoteStore+BodyExtras.swift and by NoteStore+BodyEdits.swift
    func setBodyExtras(_ extras: ContainerExtras?, for id: UUID)   // nil removes the entry
}

// Model/NoteStore.swift (4.1). For callers that delete or mark the source of a capture (share-inbox item,
// screenshot file, mail message) once the note is safe on disk (program §6).
enum PersistNowError: Error, Equatable { case noteMissing, writeBlocked, bodyNotSaved, libraryNotSaved }
@MainActor extension NoteStore {
    /// Synchronously writes this note's pending body (through flush's per-note step, so on an RTFD store with its
    /// two-phase sidecar) and then library.json, and returns only after both are installed by atomic rename.
    /// Throws PersistNowError on any failure; the note then stays pending and the next flush retries it, as today.
    /// Other notes, the search index and pending trash moves are left to the scheduled flush.
    func persistNow(_ id: UUID) throws
}

// Model/NoteStore+BodyExtras.swift (4.1): only when bodyStorage.kind == .rtfd. An .rtfd package holds no extras and keeps
// only known code languages (the code-language tab stop), so NoteStore keeps both in
// <rootURL>/body-extras/<UUID>.json, never in a Markdown content folder. .noteItDoc and Markdown bodies never use it.
// File: {"current": Entry, "previous": Entry?}, where Entry is
// {"bodySHA256": String, "extras": {"frontMatter": String?, "extra": {…}}, "codeLanguageIDs": [String?]},
// written and read through JSONValue.encoded()/decode, so numbers keep their tokens. codeLanguageIDs has one entry
// per code paragraph (one codeBlock each, Task 2.3) in document order: its noteItCodeLanguageID at write time, or
// null. bodySHA256: RTFDBodyStorage.packageDigest of the .rtfd package the entry belongs to. Two-phase write:
// (1) current = the new body's entry, previous = the entry for the body now on disk; (2) the body is installed;
// (3) the file is rewritten without previous, or deleted when current isEmpty. A failed step 1 fails the body
// write. Read uses the entry whose bodySHA256 matches the package, else current. Purging the note deletes the file
// only in trashPendingBodies, with the body's .trash move, once library.json no longer lists the note (3.5, 4.1).
// Version History keeps one Entry
// (not the two-entry file) beside every new version as <version>.extras.json, also when it isEmpty (4.5).
struct BodyExtrasEntry: Equatable, Sendable {
    var bodySHA256: String
    var extras: ContainerExtras
    var codeLanguageIDs: [String?]
    var isEmpty: Bool { get }                                  // extras == .empty and every ID is nil
}
struct BodyExtrasSidecar: Equatable, Sendable {
    var current: BodyExtrasEntry
    var previous: BodyExtrasEntry?                             // set only between steps 1 and 3
    func entry(forBodySHA256 digest: String) -> BodyExtrasEntry   // the matching entry, else current
}

// Model/BodyCodec.swift (4.2): the one body codec type, with no registry. Wave 0 has two cases: rtfd (the editor's
// NSAttributedString as RTFD libraries store it, an .rtfd package) and noteItDoc (a self-contained .noteitdoc file).
// The per-format API is instance methods that switch over self. markdown-storage adds `case markdown` in wave 1 by
// editing this enum in this file and adding a branch to each switch; that branch calls NoteItMarkdown. Its
// library-only helpers (profiles, front matter, wiki links) go in an extension as static functions.
enum BodyCodec: String, CaseIterable, Sendable {
    case rtfd
    case noteItDoc
    var fileExtension: String { get }                                               // "rtfd", "noteitdoc"
    func read(at url: URL) throws -> StoredBody                                      // switch self; rtfd: extras .empty
    func write(_ text: NSAttributedString, extras: ContainerExtras = .empty, to url: URL) throws
                                                                                    // switch self; noteItDoc: one file, attachments
                                                                                    // inside, extras in the container; rtfd ignores extras
    func data(of text: NSAttributedString, extras: ContainerExtras = .empty) throws -> Data
                                                                                    // switch self; the bytes write(_:extras:to:) stores
                                                                                    // (rtfd: the package's flat-file serialization)
    // Format-independent: they work on the editor's NSAttributedString, so every case shares them
    static func plainText(of text: NSAttributedString) -> String
    static func html(of text: NSAttributedString, title: String) -> String          // HTMLWriter
    // noteit-doc container, used by the noteItDoc branches and by sync's body encoding
    static func noteItDoc(of text: NSAttributedString, extras: ContainerExtras = .empty,
                          imagePolicy: ImagePolicy = .normalize) throws -> BodyContainer   // container.extras == extras
    static func attributedString(from container: BodyContainer) throws -> StoredBody      // extras: container.extras
    static func semanticallyEqual(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool   // equal noteit-doc exports
}

// Model/DerivedIndex.swift, Model/NoteStore+BodyEdits.swift, Editor/OpenEditorRegistry.swift (4.4, 4.5)
// Shapes owned by organise (Frozen interfaces › From foundations).
// Hooks are program §7's.
@MainActor protocol DerivedIndex: AnyObject {
    var indexID: String { get }
    func noteChanged(_ note: NoteMeta, body: NSAttributedString)     // body changed or note created; also on Remove Lock; never for locked notes
    func noteRemoved(_ noteID: UUID)                                 // deleted for good; also when a note is locked
    func metadataChanged(_ note: NoteMeta)                           // metadata only (pin, move, tags without a body change,
                                                                     // Recently Deleted and restore from it); no body, never with noteChanged
    func rebuild(notes: [NoteMeta], body: @escaping (UUID) -> NSAttributedString?) async
    func flush()                                                     // synchronous
}
extension Notification.Name {
    /// The one extra NoteStore hook (program §7). Posted for local actions only, never for a change that arrives
    /// through sync. object: the NoteStore; userInfo["noteID"]: UUID; userInfo["kind"]: LocalNoteChangeKind.
    /// created: a local path adds a note (createNote and the paths built on it; sync's importConflictCopy calls
    /// createNote with postsLocalChange: false, so a conflict copy posts nothing). edited: updateBody stores a
    /// changed body (editor save, editBody, Restore Version). deleted: a local action moves a note to Recently
    /// Deleted. Plugins build noteCreated, noteEdited and noteDeleted on it.
    static let localNoteChange: Notification.Name
}
@MainActor extension NoteStore {
    /// Existing method; 4.5 adds the last parameter. Only importConflictCopy passes false.
    func createNote(in notebookID: UUID?, initial: NSAttributedString? = nil, postsLocalChange: Bool = true) -> NoteMeta
}
enum LocalNoteChangeKind: String, Sendable { case created, edited, deleted }
/// versionNotSaved: with .recordCurrent, history.record returned nil, so editBody changed nothing.
enum BodyEditError: Error, Equatable { case noteMissing, inTrash, locked, writeBlocked, taskChanged, versionNotSaved }
/// recordCurrent: editBody records the note's current body in Version History exactly once before a change;
/// if that fails it throws versionNotSaved and changes nothing.
/// none: no version (for callers whose change is not worth a version). Callers never record one themselves.
enum EditBodyVersioning: Sendable { case recordCurrent, none }
@MainActor extension NoteStore {
    /// The one way code outside the editor changes a body, Restore Version included (program §6). Open note:
    /// first every open editor commits its pending edits in registration order, the active one last (its text
    /// wins); then with .recordCurrent records the current body once, edits the most recent NoteItTextView's text
    /// storage as one undoable change named `actionName`, saves it, and pushes the saved body to every other
    /// open editor for the note, which reloads it as it does an external change (the edit is not added to their
    /// undo stacks). Closed note: hands over pending edits, with .recordCurrent records the current body once,
    /// applies `edit` to a copy, updateBody, flush, sets externallyUpdatedNoteID.
    /// An edit that changes nothing (same text, and `extras` nil or equal to bodyExtras[id]) records nothing.
    /// extras: passed only by NoteStore's own code (Restore Version); feature callers leave it nil. nil keeps
    /// bodyExtras[id]; a value replaces it in the same body write. On the open path, Undo of a call that changed
    /// the extras restores the earlier text and extras and saves them in one body write; Redo reapplies both.
    func editBody(_ id: UUID, actionName: String, versioning: EditBodyVersioning = .recordCurrent,
                  extras: ContainerExtras? = nil,
                  _ edit: (NSMutableAttributedString) throws -> Void) throws
    /// Registered once per store open; there is no unregister. A feature that can be turned off keeps its
    /// index registered and dormant (program §7).
    func registerDerivedIndex(_ index: DerivedIndex)                 // traps on a duplicate indexID
    /// Re-sends one note to every index: noteChanged when unlocked, noteRemoved when locked.
    /// sync-security calls it after Lock Note and Remove Lock.
    func refreshDerivedIndexes(for id: UUID)
    func canRegisterDerivedIndex(_ indexID: String) -> Bool
    var derivedIndexes: [DerivedIndex] { get }
}
@MainActor final class OpenEditorRegistry {
    static let shared: OpenEditorRegistry
    /// Keeps every registered view, weakly, per note: several windows can show the same note.
    func register(_ view: NoteItTextView, for noteID: UUID)
    func unregister(_ view: NoteItTextView)
    /// Called when a registered view becomes first responder, so textView(for:) returns the view the user
    /// used last.
    func markActive(_ view: NoteItTextView)
    /// The most recently active (else most recently registered) editor for the note; editBody's open path
    /// edits this one. Editors only; never an observer.
    func textView(for noteID: UUID) -> NoteItTextView?
    func textViews(for noteID: UUID) -> [NoteItTextView]             // every live editor for the note, most recent first
    typealias Observer = @MainActor (NSAttributedString) -> Void       // receives a copy of the current body
    /// Read-only surfaces (cheat sheets, previews) mirror a note's body. Kept apart from editors, so
    /// textView(for:) never returns one and editBody never edits one. Returns a token for removeObserver.
    @discardableResult func registerObserver(_ observer: @escaping Observer, for noteID: UUID) -> UUID
    func removeObserver(_ token: UUID)
}

// Model/NoteStore+Daily.swift, Model/DailyLogAppender.swift (4.6). Behaviour owned by linking §10.
extension NoteStore {
    func dailyNotesNotebookID(createIfMissing: Bool) -> UUID?
    func dailyNote(for date: Date, createIfMissing: Bool) throws -> NoteMeta?
}
@MainActor enum DailyLogAppender {
    /// Appends one entry as the last paragraph of that day's note, through editBody. .plain text goes through
    /// DailyLogLine.format; .attributed content follows DailyLogLine.prefix and keeps its formatting. Callers
    /// that accept Markdown parse it with the existing Markdown importer first and pass .attributed.
    @discardableResult
    static func append(_ content: DailyLogContent, timestamp: Bool = true, to date: Date, in store: NoteStore,
                       now: Date = Date()) throws -> NoteMeta
}
enum DailyLogContent { case plain(String); case attributed(NSAttributedString) }
enum DailyLogError: Error, Equatable { case emptyText }
// PrefKey additions: dailyNotesNotebookID (UUID string), dailyNoteTitleFormat (DailyTitleFormat raw, default iso).

// Automation/URLScheme/URLRouteRegistry.swift (5.4). Dispatch is automation's (URLSchemeHandler).
@MainActor final class URLRouteRegistry {
    static let shared: URLRouteRegistry
    typealias Handler = @MainActor (URL) -> Void                     // the whole URL, fragment included
    func register(host: String, handler: @escaping Handler)          // traps: reserved host, duplicate, uppercase
    func handler(for host: String) -> Handler?
    var hosts: [String] { get }
}

// Frozen tables (step 6)
enum PlannedMenuShortcuts { struct Row { let command: String; let owner: String; let shortcut: MenuShortcut? }
    static let rows: [Row] }                                         // program §9; owners delete their row when they add the case
enum HotkeyOrder { static let rawValues: [String]                  // the 14 §9 raw values in order
    static func hotkeyID(for rawValue: String) -> UInt32?            // 1-based position; HotkeyAction.hotkeyID reads it
    static func rawValue(for hotkeyID: UInt32) -> String? }          // the reverse; HotkeyAction.init?(hotkeyID:) reads it
extension SettingsView.Tab { var isAvailable: Bool { get } }        // false for data, sharing, smart, integrations, plugins
struct NoteCommands: Commands { /* RecentlyDeletedCommands, renamed */ static let order: [String] }   // §9 note group order
enum GeneralSettingsSection: String, CaseIterable {                // the General tab's section order (Task 6.5)
    case appearance, startup, capture, emailIn, reminders, cheatSheet, updates
                                                                     // emailIn: capture-plus; reminders: organise; cheatSheet: surfaces-polish
    var isAvailable: Bool { get }                                    // false for emailIn, reminders and cheatSheet until their owners ship them
}
```

## Tasks

Markers: **[S]** means serial — start only after the task before it in its step is merged. **[P]** means it may run at the same time as other [P] tasks, under the conditions in "Order and parallelism". `swift test` and `swift build` below always carry the `DEVELOPER_DIR` prefix from Conventions. "Full gate" means the three commands listed there.

### Step 1: NoteItCore

#### Task 1.1: Package platforms, `NoteItCore` target and the models [S]

Moved from mobile Task 0.1. It adds the program §9 `SidebarSelection` cases.

**Files:**
- Modify: `Package.swift`, `Sources/NoteIt/Model/Models.swift`, `Sources/NoteIt/Design/Tokens.swift`, `Sources/NoteIt/Model/NoteStore.swift` (`notes(for:search:)`, `count(for:)`, `createNoteInCurrentContext`), `Sources/NoteIt/Views/NoteListView.swift` (title and empty-state switches), plus any other exhaustive `switch` over `SidebarSelection` the compiler reports
- Create: `Sources/NoteItCore/Models/{Notebook,NoteMeta,SidebarSelection,NotebookPalette}.swift`, `Sources/NoteIt/App/CoreExports.swift`, `Tests/NoteItCoreTests/{ImportHygieneTests,ModelCodingTests,SidebarOrderTests}.swift`

- [ ] `Package.swift`:
  - Set `platforms: [.macOS(.v14), .iOS(.v17)]`.
  - Add products: `.library(name: "NoteItCore", targets: ["NoteItCore"])` and `.library(name: "NoteItSync", targets: ["NoteItSync"])`. The `NoteIt` executable product stays.
  - Add target `NoteItCore` (path `Sources/NoteItCore`, no dependencies).
  - Add test target `NoteItCoreTests` (depends on `NoteItCore`).
  - Add `NoteItCore` to the dependencies of `NoteIt` and `NoteItTests`.
  - Sparkle stays a dependency of `NoteIt` only.
- [ ] Move `Notebook`, `NoteMeta`, `SidebarSelection` and `NotebookPalette` from `Models.swift` into `NoteItCore`, as frozen above:
  - Add `Sendable`, `public` and explicit `public init`s with the synthesized parameter order and defaults.
  - Keep the `Codable` keys and conformances exactly as they are.
  - Move `NoteMeta.displayTitle` with them.
  - `Models.swift` keeps `Notebook.color`, `Color(hex:)` and `NSColor(hex:)`.
- [ ] `NotebookPalette.colors` holds the ten hex string literals now in `Tokens.Hex.notebookPalette`. `Tokens.Hex.notebookPalette` becomes `NotebookPalette.colors`, so there is one source.
- [ ] In this task `CoreExports.swift` holds only `@_exported import NoteItCore` (Task 2.1 adds `NoteItDoc`). No other app file changes its imports.
- [ ] `SidebarSelection` gains `.today`, `.tasks` and `.smartFolder(UUID)`. `.tag(String)` keeps its payload, which is documented as a tag path. Add `SidebarLibraryRow` in the §9 order.
- [ ] Handle the new cases in every app switch, with no user-visible effect:
  - `notes(for:search:)` returns `[]` and `count(for:)` returns `0`.
  - `createNoteInCurrentContext` treats them like `.allNotes`.
  - `NoteListView` titles are "Today", "Tasks" and "Smart Folder", with the generic empty state.
  - No sidebar row, menu item or command selects them.
- [ ] `ImportHygieneTests` finds the repo root from `#filePath` and scans every `.swift` file under these folders that exist: `Sources/NoteItCore`, `Sources/NoteItDoc`, `Tests/Support/NoteItDocTestSupport`, `Sources/NoteItSync` and `Sources/NoteItAPI`.
  - It fails on `import AppKit`, `Cocoa`, `SwiftUI`, `UIKit` or `Carbon`, and on `canImport(AppKit)` or `os(macOS)`. The failure message names the file and the line text.
  - A second test asserts that `Sources/NoteItCore` and `Sources/NoteItSync` exist, so the scan can't silently pass on a moved folder.
- [ ] `ModelCodingTests`:
  - A `NoteMeta` JSON literal with every key, and one with only the required keys, both decode.
  - Re-encoding with `.sortedKeys` and iso8601 gives the same key set.
  - The same two checks run for `Notebook`.
  - `displayTitle` of an empty title is "New Note".
- [ ] `SidebarOrderTests`: `SidebarLibraryRow.allCases` equals the §9 order, and every case except `smartFolder`/`notebook`/`tag` has a row.

**Tests:** the new `NoteItCoreTests` above. `RecentlyDeletedTests` and every other existing test are unchanged and pass.

**Verify:**
- `swift test --filter NoteItCoreTests 2>&1 | tail -5` → `Executed 7 tests, with 0 failures` (or more).
- `xcodebuild -scheme NoteItCore -destination 'generic/platform=iOS Simulator' build -quiet` → no `error:` lines.
- Full gate.

**Commit:** `refactor(core): extract models into NoteItCore`

#### Task 1.2: `TextFold` and `FuzzyMatcher` [S]

Moved from organise T1.

**Files:**
- Create: `Sources/NoteItCore/Text/{TextFold,FuzzyMatcher}.swift`, `Tests/NoteItCoreTests/TextFoldTests.swift`
- Move: `Sources/NoteIt/Palette/FuzzyMatcher.swift` → `Sources/NoteItCore/Text/FuzzyMatcher.swift`; `Tests/NoteItTests/FuzzyMatcherTests.swift` → `Tests/NoteItCoreTests/FuzzyMatcherTests.swift`
- Modify: `Sources/NoteIt/Model/NoteStore.swift` (`fold`)

- [ ] Move the body of `NoteStore.fold` into `TextFold.fold`. `NoteStore.fold` stays as a one-line `nonisolated static` forwarder, because callers in `Palette/` and `NoteStore` use it.
- [ ] Move `FuzzyMatch`, `FuzzyQuery` and `FuzzyMatcher` unchanged except for `public` on the types and on every member the app uses (`FuzzyMatch.score`, `matchedIndices` and a public memberwise init; `FuzzyQuery.init(_:)` and `isEmpty`; the matcher's entry points), as frozen above. Anything in them that calls `NoteStore.fold` now calls `TextFold.fold`.
- [ ] In the moved `FuzzyMatcherTests`, replace `@testable import NoteIt` with `@testable import NoteItCore`. The test bodies don't change.
- [ ] `TextFoldTests`: case and diacritic folding ("Éclair" → "eclair"), width folding, and an empty string. Each expected value is the output of today's `NoteStore.fold`, captured before the move.

**Tests:** `FuzzyMatcherTests` (moved), `TextFoldTests`. `PaletteRankerTests` is unchanged.

**Verify:**
- `swift test --filter "FuzzyMatcherTests|TextFoldTests|PaletteRankerTests" 2>&1 | tail -5` → `with 0 failures`.
- iOS `xcodebuild` for `NoteItCore` → no errors.
- Full gate.

**Commit:** `refactor(core): move folding and fuzzy matching into NoteItCore`

#### Task 1.3: `LibraryFile`, `LibraryCoding`, `TrashPolicy`, `CaptureTitle` [S]

Moved from mobile Task 0.2.

**Files:**
- Create: `Sources/NoteItCore/Library/{LibraryFile,LibraryCoding,TrashPolicy}.swift`, `Sources/NoteItCore/Capture/CaptureTitle.swift`, `Tests/NoteItCoreTests/{LibraryCodingTests,TrashPolicyTests,CaptureTitleTests}.swift`
- Modify: `Sources/NoteIt/Model/NoteStore.swift` (private `LibraryFile`, `PartialLibrary`, `encoder`, `decoder`), `Sources/NoteIt/Model/NoteStore+Trash.swift`, `Sources/NoteIt/Capture/CaptureFormatter.swift`

- [ ] Move `LibraryFile` and `PartialLibrary` out of `NoteStore` (public, same keys) and delete the private copies.
- [ ] `LibraryCoding.encoder`/`decoder` are today's `NoteStore.encoder`/`decoder`. `NoteStore.encoder`/`decoder` become forwarders, because `NoteStore+Sync` and others use them.
- [ ] `LibraryCoding.decode` and `salvage` hold the existing full and partial decode paths from `load()`.
- [ ] `TrashPolicy.retention` replaces the value of `NoteStore.recentlyDeletedRetention`, which forwards to it.
  - `purgeDate(of:)` calls `TrashPolicy.purgeDate`.
  - `purgeExpiredDeletedNotes(now:)` calls `isExpired`.
  - `NoteStore.deletionSummary` forwards to `TrashPolicy.deletionSummary`.
- [ ] `CaptureTitle` takes `firstLine(of:)`, `singleLine(_:)` and `truncatedTitle(_:)` from `CaptureFormatter`, with the same bodies and limits. `CaptureFormatter` calls them and keeps `maxTitleLength`/`titleScanLimit` as forwarders.
- [ ] `LibraryCodingTests`:
  - A `library.json` literal round-trips byte-for-byte through `LibraryCoding`.
  - A truncated file salvages its notebooks.
  - Unknown top-level keys don't stop decoding.
- [ ] `TrashPolicyTests`: the strings for 0, 1, 3, 29 and 31 days, matching the current `deletionSummary` output, plus `isExpired` at exactly 30 days.
- [ ] `CaptureTitleTests`: a blank first line, a line longer than 60 characters cut at a word boundary, and text longer than 4,096 characters.

**Tests:** the three new suites. `CaptureFormatterTests` and `RecentlyDeletedTests` are unchanged.

**Verify:**
- `swift test --filter "LibraryCodingTests|TrashPolicyTests|CaptureTitleTests|CaptureFormatterTests|RecentlyDeletedTests" 2>&1 | tail -5` → `with 0 failures`.
- `NOTEIT_DATA_DIR=.selftest/core NOTEIT_SYNC_SELFTEST=1 swift run NoteIt 2>&1 | tail -1` → `PASS all checks` (library.json written by `LibraryCoding` still syncs).
- Full gate.

**Commit:** `refactor(core): move library coding, trash policy and capture title into NoteItCore`

#### Task 1.4: `LibraryQuery` [S]

Moved from mobile Task 0.3.

**Files:**
- Create: `Sources/NoteItCore/Library/LibraryQuery.swift`, `Tests/NoteItCoreTests/LibraryQueryTests.swift`
- Modify: `Sources/NoteIt/Model/NoteStore.swift` (`notes(for:search:)`, `count(for:)`, `recentInterval`)

- [ ] Move the filter, search and sort of `NoteStore.notes(for:search:)` into `LibraryQuery.notes(_:for:search:now:indexedText:)`, which covers every `SidebarSelection` case. The new cases return `[]` until their owners change them.
- [ ] `NoteStore.notes(for:search:)` becomes `LibraryQuery.notes(notes, for: selection, search: search, now: Date(), indexedText: { searchIndex[$0] })`. `count(for:)` uses `LibraryQuery.count`. `NoteStore.recentInterval` forwards to `LibraryQuery.recentInterval`.
- [ ] `LibraryQueryTests` covers each case:
  - pinned-first then `updatedAt` descending;
  - Recently Deleted by `deletedAt` descending;
  - `.recent` at exactly 7 days;
  - `.conflicts` requires `conflictSource`;
  - a tag;
  - a notebook;
  - search where every term must match, with diacritics;
  - `indexedText` overriding the title and preview;
  - `.today`/`.tasks`/`.smartFolder` empty;
  - deleted notes never shown outside Recently Deleted.

**Tests:** `LibraryQueryTests`. The existing list tests (`RecentlyDeletedTests`, `PaletteModelTests`) are unchanged.

**Verify:**
- `swift test --filter "LibraryQueryTests|RecentlyDeletedTests|PaletteModelTests" 2>&1 | tail -5` → `with 0 failures`.
- iOS `xcodebuild` for `NoteItCore` → no errors.
- Full gate.

**Commit:** `refactor(core): one LibraryQuery for every sidebar selection`

### Step 2: NoteItDoc

#### Task 2.1: `NoteItDoc` schema, container and validation [S]

Moved from web-app Task 0.1, plus the `AttachmentLimit` type from web-app Task 0.6. It adds the markdown-storage §3.12 asks and the `noteit:` allowlist.

**Files:**
- Modify: `Package.swift`, `Sources/NoteIt/Editor/EditorStyles.swift` (`EditorStyle` sentinels and `BlockKind`), `Sources/NoteIt/Editor/SyntaxHighlighter.swift` (`CodeLanguage`)
- Create: `Sources/NoteItDoc/{DocSchema,DocNode,Mark,JSONValue,BodyContainer,Attachment,DocValidation,LinkPolicy,BlockSentinels,BlockKind,CodeLanguage,AttachmentLimit,ImagePolicy}.swift`, `Tests/NoteItDocTests/{DocSchemaTests,BodyContainerTests,DocValidationTests,AttachmentLimitTests,ImagePolicyTests}.swift`

- [ ] `Package.swift`:
  - Add `.library(name: "NoteItDoc", targets: ["NoteItDoc"])`.
  - Add target `NoteItDoc` (depends on `NoteItCore`).
  - Add test target `NoteItDocTests` (depends on `NoteItDoc`).
  - Add `NoteItDoc` to the dependencies of `NoteIt` and `NoteItTests`.
  - Add `@_exported import NoteItDoc` to `CoreExports.swift`.
- [ ] Write the types as frozen. The JSON shape matches the `@noteit/doc` TypeScript types in the web-app plan field for field:
  - `type` discriminators and `attrs` objects;
  - `marks` omitted when empty;
  - `content` omitted when empty, where the TS type marks it optional.
- [ ] `BodyContainer`:
  - Decodes unknown top-level keys into `extra` and writes them back.
  - `JSONValue.number` keeps the number's original token. `decode(_:)` reads `extra` values with NoteItDoc's own small JSON scanner, because `JSONDecoder` and `JSONSerialization` turn numbers into `Double`; the scanner checks each token against the JSON number grammar. `encoded()` writes the token back verbatim. Through plain `Codable` (a container nested in other JSON), `number` goes through `Decimal`, which keeps up to 38 significant digits but not the spelling.
  - `frontMatter` is optional and kept.
  - `ContainerExtras` (in `BodyContainer.swift`) is frozen. `BodyContainer.extras` reads `frontMatter` and `extra` together and sets both.
  - `JSONValue.encoded()` and `JSONValue.decode(_:)` expose the same scanner and token writer for a whole JSON document, so other files (the RTFD body-extras sidecar, Task 4.1) keep numbers exactly.
  - `encoded()` uses `.sortedKeys` and `.withoutEscapingSlashes`; `Attachment.data` is base64.
  - An unknown node `type` decodes to `.unknown(type:json:)`, which re-encodes the same bytes.
- [ ] `DocValidation.validate` returns `.readOnly(reason:)` for any of these:
  - an unknown node;
  - `format != "noteit-doc"` or `version > 1`;
  - a heading level outside 1–3;
  - a list `level` outside 0–8;
  - a colour that doesn't match `^#[0-9A-Fa-f]{6}$`;
  - a `fontSize` delta outside the [8, 96] range;
  - an attachment key that isn't the SHA-256 of its data;
  - a link whose `LinkPolicy.allows` is false.
- [ ] `LinkPolicy.schemes` is `["http", "https", "mailto", "tel", "noteit"]`. A `noteit:` href is allowed only when `NoteLink(url:)` or `URLCommand.parse` accepts it. Until Task 5.3 lands, the check is "scheme is noteit and host is note".
- [ ] Move the seven sentinel values (`bodySentinel` through `subheadingSentinel`) into `BlockSentinels` as `Double`. `EditorStyle` keeps its names as `CGFloat(BlockSentinels.x)`.
- [ ] Add `ImagePolicy` as frozen: a pure `String`-backed enum with no ImageIO or AppKit code. `NoteItDocAppKit` applies it (Task 2.3).
- [ ] Add `AttachmentLimit` as frozen. Nothing in the app calls it in wave 0; web-app Task 0.6 keeps the editor's insert, paste and drop checks and `PassphraseHint`.
- [ ] Move `BlockKind` (with `displayName` and `menuCases`) and `CodeLanguage` (with `identifier`, `displayName`, `shortName` and every other Foundation-only member) into `NoteItDoc`, unchanged and made public. Anything that uses AppKit stays in the app as an extension.
- [ ] Tests:
  - every node and mark round-trips from a JSON literal;
  - `codeBlock.language` round-trips;
  - `frontMatter` and an unknown top-level key survive a re-encode;
  - setting `extras` on a container replaces `frontMatter` and `extra` and leaves `doc` and `attachments` unchanged;
  - an unknown key holding `9007199254740993` (above 2^53), `1.50` and `-0` re-encodes with the same tokens, and a non-number token such as `01` or `NaN` fails to decode; the same holds for `JSONValue.decode` then `encoded()` of an object holding those numbers;
  - an unknown node gives `.readOnly`;
  - the colour regex;
  - level bounds;
  - `noteit://note/<UUID>`, `noteit://note/<UUID>?heading=Intro` and `noteit://note?title=Plan` are valid;
  - `javascript:alert(1)` and `data:text/html,x` are read-only;
  - `CodeLanguage(rawValue:)` is unchanged for 1…21;
  - `ImagePolicyTests`: `normalize` and `keepOriginal` round-trip through JSON by raw value;
  - `AttachmentLimitTests`: `maxBytes == 26_214_400`, `allows(byteCount:)` is true at exactly that size and false one byte over, and `tooLargeMessage(name: "Scan.tiff")` equals the web-app spec §3.2 string.

**Verify:**
- `swift test --filter NoteItDocTests 2>&1 | tail -5` → `with 0 failures` (includes `AttachmentLimitTests` and `ImagePolicyTests`).
- `xcodebuild -scheme NoteItDoc -destination 'generic/platform=iOS Simulator' build -quiet` → no errors.
- Full gate. `CodeStylingTests` and `MarkdownReaderTests` still pass.

**Commit:** `feat(doc): NoteItDoc schema, container and validation`

#### Task 2.2: `NoteItDocTestSupport` and doc fixtures [S]

Moved from web-app Task 0.1 (test support) and mobile Task 0.5 (the iOS build).

**Files:**
- Modify: `Package.swift`
- Create: `Tests/Support/NoteItDocTestSupport/{RandomDocGenerator,GoldenFixtures}.swift`, `fixtures/golden/doc-validate.json`, `Tests/NoteItDocTests/GoldenDocTests.swift`

- [ ] `Package.swift`: add target `NoteItDocTestSupport` (path `Tests/Support/NoteItDocTestSupport`, depends on `NoteItDoc`). Add it to `NoteItDocTests`. It is not a product.
- [ ] `RandomDocGenerator(seed:includeUnknown:)` uses a SplitMix64 seeded generator. The same seed and mode always produce the same container.
  - By default (`includeUnknown: false`) it covers every node except `.unknown`, and every mark, attribute, nesting rule and attachment kind in the schema. Its output always validates as `.valid` and can round-trip through the AppKit converter (task 2.3), which cannot represent a read-only unknown node.
  - With `includeUnknown: true` it also emits `.unknown(type:json:)` nodes, with made-up type names and JSON content. Only `NoteItDoc` codec and validator tests use this mode; converter tests never do.
- [ ] `GoldenFixtures`:
  - `directory` is `<repo>/fixtures/golden`, found from `#filePath`.
  - `load` decodes the file `{ "generator", "version": 1, "cases": [...] }`.
  - `write` throws unless `NOTEIT_WRITE_VECTORS=1`.
- [ ] `fixtures/golden/doc-validate.json` is hand-written with `generator: "spec"`, in the web-app golden schema `{name, container, expect}`. It holds:
  - one valid case per allowed scheme;
  - the three `noteit:` forms;
  - `javascript:` and `data:` as read-only;
  - an unknown node;
  - an unknown top-level key;
  - `frontMatter`.
- [ ] There is no TypeScript code in the repo yet. Program §2 step 2's TypeScript half is met through this file: `@noteit/doc`'s validator, written by web-app, must pass every case in `doc-validate.json`. The noteit-link cases are fixed here, so the two validators cannot drift.
- [ ] `GoldenDocTests`:
  - every case in `doc-validate.json` gives its `expect`;
  - 500 seeds of the default `RandomDocGenerator` each pass `encoded()` → `decode` → equal, and validate as `.valid`;
  - 500 seeds with `includeUnknown: true` each pass `encoded()` → `decode` → equal and re-encode to the same bytes, and validate as `.readOnly` exactly when the container holds an `.unknown` node (else `.valid`);
  - `.unknown` on its own: a hand-built container with one unknown node inside a `blockquote`'s content and one at the top level decodes both to `.unknown(type:json:)`, re-encodes the same bytes and validates as `.readOnly`. `.unknown` is a `DocNode`, so it never appears in a paragraph's inline content and there is no inline case.
- [ ] `ImportHygieneTests` now also scans `Tests/Support/NoteItDocTestSupport` (the folder exists).

**Verify:**
- `swift test --filter "GoldenDocTests|ImportHygieneTests" 2>&1 | tail -5` → `with 0 failures`.
- `xcodebuild -scheme NoteItDocTestSupport -destination 'generic/platform=iOS Simulator' build -quiet` → no errors.
- Full gate.

**Commit:** `test(doc): doc test support and validation vectors`

#### Task 2.3: `NoteItDocAppKit` converter [S]

Moved from web-app Task 0.2.

**Files:**
- Modify: `Package.swift`, `Sources/NoteIt/Editor/CodeStyler.swift` (`setLanguage(_:forBlockAt:)`), `Sources/NoteIt/Editor/EditorStyles.swift` (the block-kind change drops `noteItCodeLanguageID` when a paragraph stops being code)
- Create: `Sources/NoteItDocAppKit/{DocStyleProvider,ImageNormalizer,DocConverter,DocConverter+Export,DocConverter+Import}.swift`, `Sources/NoteIt/Editor/AppDocStyleProvider.swift`, `Tests/NoteItDocAppKitTests/{DocConverterRoundTripTests,ConverterCodeBlockTests,ImageNormalizerTests}.swift`, `Tests/NoteItTests/CodeLanguageIDTests.swift`

- [ ] `Package.swift`:
  - Add target `NoteItDocAppKit` (depends on `NoteItDoc`; macOS only, as AppKit is imported). No product.
  - Add test target `NoteItDocAppKitTests` (depends on `NoteItDocAppKit` and `NoteItDocTestSupport`).
  - Add `NoteItDocAppKit` to the dependencies of `NoteIt` and `NoteItTests`.
- [ ] The converter reads and writes the editor's paragraph model through the same attributes `EditorStyle` uses: sentinels from `BlockSentinels`, list styles, checkboxes, the code language attribute and links. It does not import the app.
  - Where it needs a value that lives on `EditorStyle` (list indent steps, marker text), the value moves to `NoteItDocAppKit` as a public constant and `EditorStyle` forwards to it. The checkbox glyphs are the exception: they move to `NoteItCore` as `public enum ChecklistMarkers { public static let unchecked = "☐"; public static let checked = "☑" }` (file `Sources/NoteItCore/Text/ChecklistMarkers.swift`), and `NoteItDocAppKit` and `EditorStyle.uncheckedBox`/`checkedBox` both read it, so organise's `TaskParser` uses the same constants without depending on AppKit.
  - This step adds exactly one new paragraph attribute: `NSAttributedString.Key.noteItCodeLanguageID` (value `String`), a public constant in `NoteItDocAppKit`. It holds a code paragraph's `codeBlock.language` identifier as written, known or not, so an identifier that `CodeLanguage` doesn't know survives editing. No other attribute is added.
- [ ] `export(_:styles:imagePolicy:)` follows the web-app spec rules:
  - one `codeBlock` per native code paragraph. Its `language` is the paragraph's `noteItCodeLanguageID` when present, else the identifier of the known `CodeLanguage` from the existing code-language tab stop (`EditorStyle.codeLanguage(of:)`), else nil;
  - checked-item style is never exported as marks;
  - image rules per `NoteItDoc.ImagePolicy`, applied by `ImageNormalizer` (`.normalize`: TIFF/BMP → PNG, HEIC → JPEG 0.9; `.keepOriginal`: bytes as they are). `ImagePolicy` itself is not redeclared here.
- [ ] `importDocument` builds the same attributes the editor would. When `codeBlock.language` is non-nil (known or not) it sets `noteItCodeLanguageID` to it on the code paragraph; when `CodeLanguage(identifier:)` also resolves, it sets the existing code-language tab stop (`EditorStyle.setCodeLanguage`) too. An unknown language is shown as plain and kept in `noteItCodeLanguageID`.
- [ ] The editor keeps `noteItCodeLanguageID` on code paragraphs as an ordinary paragraph attribute, so typing attributes carry it into new text in the paragraph:
  - choosing a language in the editor UI (`CodeStyler.setLanguage(_:forBlockAt:)`) overwrites both: the tab stop, and `noteItCodeLanguageID` set to that language's identifier (removed for Automatic);
  - turning a paragraph out of code (the `FormatCommand` block-kind path through `EditorStyle`) removes both.
- [ ] `AppDocStyleProvider` returns the app's fonts from `EditorStyle` (`bodyAttributes`, heading fonts, monospaced).
- [ ] Tests:
  - doc → NSAS → doc is exact for 500 seeds of the default `RandomDocGenerator` (no `.unknown` nodes; `includeUnknown` is never used here);
  - NSAS → doc → NSAS is semantically equal, using an internal test-only comparer of paragraphs, runs and attributes, for one fixture per `FormatCommand` row in `ConverterCodeBlockTests`;
  - `codeBlock.language` survives, for a known identifier (`swift`) and an unknown one (`zig-nightly`): import → edit → export gives the same `language`. `ConverterCodeBlockTests.testLanguageSurvivesEdit` edits by inserting one character into the code paragraph with the attributes of the character before it; `CodeLanguageIDTests.testLanguageSurvivesTyping` (app target) types one character into a `NoteItTextView`. `CodeLanguageIDTests` also checks that choosing Python through `CodeStyler.setLanguage(_:forBlockAt:)` exports `python`, and that turning the paragraph into body text exports no `codeBlock` and leaves no `noteItCodeLanguageID` in the text;
  - the `ImagePolicy` byte rules on a 1×1 TIFF and a HEIC sample.

**Verify:**
- `swift test --filter "NoteItDocAppKitTests|CodeLanguageIDTests" 2>&1 | tail -5` → `with 0 failures`.
- Full gate. `EditorColumnLayoutTests`, `CodeStylingTests` and `FindReplaceTests` still pass: the editor's existing attributes are unchanged, and `noteItCodeLanguageID` is the only one added.

**Commit:** `feat(doc): NoteItDocAppKit converter with image policy`

#### Task 2.4: Golden vectors for the existing format [S]

Moved from web-app Task 0.3.

**Files:**
- Create: `Tests/NoteItSyncTests/GoldenVectorTests.swift`, `Tests/NoteItSyncTests/Support/VectorIO.swift`, and in `fixtures/golden/`: `pbkdf2.json`, `aesgcm.json`, `manifest.json`, `envelopes.json`, `planner.json`, `store-snapshot.json`, `engine-scenarios.json`
- Modify: `Package.swift` (`NoteItSyncTests` gains `NoteItDocTestSupport` for `GoldenFixtures`)

- [ ] `VectorIO` wraps `GoldenFixtures`: it writes when `NOTEIT_WRITE_VECTORS=1` is set, and otherwise loads the file and compares.
- [ ] Generate every file with the web-app plan's case shapes ("Golden vector file schemas"), using the current engine:
  - PBKDF2 at 210,000 iterations plus edge salts;
  - AES-GCM with the negative `tamper` cases;
  - v1 manifests (plain, encrypted, wrong passphrase, `formatVersion` 3 → `unsupportedFormat`, which stays true after step 3);
  - note, notebook, tombstone and device envelopes, including `\/` escapes and ISO dates;
  - the full planner product;
  - one store snapshot;
  - the ten base engine scenarios on `InMemoryBackend`.
- [ ] Commit the generated files. A test run without the variable must pass using only those files.

**Verify:**
- `NOTEIT_WRITE_VECTORS=1 swift test --filter GoldenVectorTests 2>&1 | tail -3` (once) writes the files.
- `swift test --filter GoldenVectorTests 2>&1 | tail -5` → `with 0 failures`.
- `git status --short fixtures` is clean after the second run.
- Full gate.

**Commit:** `test(sync): golden vectors for the v1 store format`

### Step 3: NoteItSync store sessions

Moved from sync-security M0 (Tasks 0.1 and 0.2), its Task 4.1 (the keyring value types `connectSession` needs), and the session half of web-app Task 0.4.

sync-security's M0 lists the tests this step must include. They are named below under the task that adds them. New stores stay v1, and nothing in wave 0 calls `ensureFeature` outside tests.

#### Task 3.1: Manifest fields, `StoreFeature`, version gate, device and state fields [S]

**Files:**
- Modify: `Sources/NoteItSync/Model/{Manifest,SyncTypes,SyncState}.swift`, `Sources/NoteItSync/Engine/SyncEngine.swift` (`SyncError`, `openExisting`, `writeDeviceRecordIfDue`, `RemoteIndex`), `Sources/NoteIt/Sync/SyncController.swift` (private static `inspect`, `handle(_:)`, static `describe(_:)`), `Sources/NoteIt/Settings/SyncSettingsView.swift` (any `SyncError` switch)
- Create: `Sources/NoteItSync/Engine/StoreSession.swift` (only `StoreFeature` and `StoreSessionKind` in this task), `Sources/NoteItSync/Engine/RekeyScope.swift` (only `RekeyBlocker` in this task), `Tests/NoteItSyncTests/ManifestFeatureTests.swift`

- [ ] `Manifest` gains `features`, `keyring` and `rekey`, all optional. `rekey` is a manifest field and never appears in `features`. `Keyring` and `Rekey` are stubbed as empty `Codable` structs here and filled in by Task 3.2; nothing creates them in this task.
  - The `init` gains the three parameters with `nil` defaults.
  - `features` is encoded sorted, through a custom `encode(to:)` that sorts before writing and omits nil values.
  - Encoding with `SyncEngine.encode` (`.sortedKeys`) gives the same bytes as before for a v1 manifest.
- [ ] `StoreFeature` has the four §4 names (`noteit-doc`, `keyring`, `locked-notes`, `noteit-space`), `known`, `requires`, and `supported`, which is empty in this task and in 3.2: this build can't open a keyring store yet, so it doesn't claim to. Task 3.3 adds `keyring` in the same change that adds `connectSession` and the keyring cipher. `noteit-doc`, `locked-notes` and `noteit-space` stay outside `supported` until their readers ship: web-app adds `noteit-doc` with the Mac body conversion (its Tasks 0.4–0.5, wave 3), sync-security adds `locked-notes` in its milestone M5 (wave 3, after web-app 0.4–0.5) and sharing adds `noteit-space`.
- [ ] `SyncEngine.maxFormatVersion = 2`. `openExisting` and `SyncController.inspect` share one gate, `SyncEngine.checkOpenable(_ manifest: Manifest, supported: Set<StoreFeature> = StoreFeature.supported) throws` (`public`, because `SyncController` is in the app target; used by both). It throws:
  - `unsupportedFormat(v)` when `v > maxFormatVersion`;
  - `unsupportedFeature(name)` for a name outside `known`, or for a known name outside `supported`;
  - `invalidManifest("features without formatVersion 2")` when `features` is non-empty and `formatVersion != 2`;
  - `invalidManifest("locked-notes without noteit-doc")` when a feature is present without everything in its `requires`.

  `inspect` maps these errors to `.unsupported`, as it does today for a higher format version.
- [ ] `SyncError` gains the frozen cases. `RekeyBlocker` is created in `RekeyScope.swift` because `rekeyBlocked` needs it.
  - `SyncController.handle`/`describe` and `SyncSettingsView` map every new case.
  - `unsupportedFeature` uses the same text as `unsupportedFormat` ("This sync store was created by a newer version of NoteIt…").
  - Every other new case uses a plain sentence naming the case. Each is replaced by its owner's UI text, and none can occur in wave 0.
- [ ] `DeviceInfo` gains `platform`, `appVersion`, `supportedFeatures` and `rekeyAck`, all optional, with the `init` defaulting them to nil.
  - `DevicePlatform` (`mac`, `ios`, `web`) is added next to `DeviceInfo`. `DeviceInfo.platform` stays a `String?`, so an unknown value from a newer app decodes and survives.
  - `writeDeviceRecordIfDue` writes `platform: "mac"` (Task 3.3 makes it the engine's `platform.rawValue`) and `appVersion` (from a new `appVersion: String?` the engine is given; nil until Task 3.3 passes it). It leaves `supportedFeatures` out while `supported` is empty; from Task 3.3 on it writes `StoreFeature.supported` sorted. `rekeyAck` stays nil; sync-security writes it.
  - A record without `supportedFeatures` is read as supporting no features (Task 3.4).
  - `SyncState` gains `keyID: String?`.
- [ ] `SyncState` gains `pendingBodyVersions: [UUID: PendingBody]`, with the `PendingBody` type next to it in `SyncState.swift`, both exactly as in Frozen interfaces (moved from web-app Task 0.4). `RemoteEnvelope` gains `Equatable`, because `PendingBody` stores one and `SyncState` is `Equatable`.
  - `CodingKeys` gains `pendingBodyVersions`, the memberwise `init` gains it with a `[:]` default, and `init(from:)` decodes it with `decodeIfPresent … ?? [:]` like the other keys, so a state file from an older build decodes with an empty map and keeps its other fields. `save(to:)` writes it.
  - Nothing reads or writes an entry in wave 0, and no `PendingBodies/` file is created. web-app Task 0.4 writes entries and the sealed bytes; sync-security Task 4.3 passes `pendingBodyVersions.count` to `RekeyRunner` as its `pendingBodyVersions` precondition.
- [ ] `RemoteIndex` ignores keys under `inkwell/v1/keys/`. They are not notes, notebooks, tombstones or devices.
- [ ] Tests:
  - `testV1ManifestRoundTripsUnchanged` (bytes of a stored v1 fixture from `fixtures/golden/manifest.json`);
  - `testRefusesVersion3`;
  - `testRefusesUnknownFeature`;
  - `testRefusesKnownButUnsupportedFeature` (with the default `supported`, all four known features are refused, `keyring` included; with `supported: [.keyring]` passed in, `keyring` opens and the other three are still refused);
  - `testFeaturesWithoutVersion2AreInvalid`;
  - `testLockedNotesWithoutNoteItDocIsInvalid`;
  - `testRekeyIsNotAFeature` (`features: ["rekey"]` is `unsupportedFeature("rekey")`; a `rekey` field decodes);
  - `testDeviceInfoWithoutNewFieldsDecodes`;
  - `testSyncStateWithoutKeyIDDecodes`;
  - `testSyncStateWithoutPendingBodyVersionsDecodes` (state JSON written by today's `SyncState`, without the key, decodes with empty `pendingBodyVersions` and its bases, tombstones and `pendingPushes` intact);
  - `testPendingBodyVersionsRoundTrip` (a state with one entry per `Phase`, each holding an envelope, goes through `save(to:)` and `load(from:)` and is equal to the original);
  - `testKeysFolderIgnoredByIndex`;
  - `testDeviceRecordOmitsSupportedFeaturesBeforeSessions` (`platform == "mac"`, no `supportedFeatures` key).

**Verify:**
- `swift test --filter "ManifestFeatureTests|SyncEngineTests|GoldenVectorTests" 2>&1 | tail -5` → `with 0 failures`.
- iOS `xcodebuild` for `NoteItSync` → no errors.
- `NOTEIT_DATA_DIR=.selftest/s31 NOTEIT_SYNC_SELFTEST=1 swift run NoteIt 2>&1 | tail -1` → `PASS all checks`.
- Full gate.

**Commit:** `feat(sync): manifest features and version gate`

#### Task 3.2: `Keyring`, `Rekey`, `KeyIdentity`, `StoreCredential` [S]

Moved from sync-security Task 4.1.

**Files:**
- Create: `Sources/NoteItSync/Crypto/Keyring.swift`, `Tests/NoteItSyncTests/KeyringTests.swift`
- Modify: `Sources/NoteItSync/Crypto/KeyDerivation.swift` (`normalized`), `Sources/NoteItSync/Model/Manifest.swift` (remove the stubs)

- [ ] `Rekey` includes sync-security's two optional fields `previousKeyring: Keyring?` and `previousEncryption: Manifest.Encryption?`. Wave 0 never sets them, but declares them so a wave 0 or wave 1 build that rewrites the manifest during another device's rekey keeps them. Test: `testRekeyPreviousFieldsRoundTrip` (a manifest whose `rekey` has both fields decodes and re-encodes with them intact).
- [ ] Implement the frozen types. `Keyring.make` wraps a caller-supplied 32-byte key:
  - When `normalized(p)` is empty, `make` and `rewrapped` throw `SyncError.passphraseRequired`, the error the existing encrypted create path already throws for an empty passphrase (`SyncEngine.connectReportingCreation`), before deriving or wrapping anything. This covers store creation (3.3) and sync-security's `changePassphrase` new passphrase, which both go through `make` or `rewrapped`.
  - The key-encryption key comes from `KeyDerivation.deriveKey(passphrase: normalized(p), salt:, iterations:)`.
  - It is sealed with AES-GCM with aad `keyring/<keyID>`.
  - `unwrap` maps an authentication failure to `wrongPassphrase`.
  - Iterations outside `SyncEngine.iterationRange` are `invalidManifest`.
- [ ] `KeyIdentity.keyID` is `SHA256("noteit-key-id" || key)`, with the first 8 bytes written as lowercase hex.
- [ ] `KeyIdentity.legacyKeyID` is `SHA256("noteit-legacy-key" || salt || iterations as 4-byte big-endian || keyCheck)`, truncated the same way.
- [ ] `normalized` applies NFC (`precomposedStringWithCanonicalMapping`), per program §4 rule 12. Keyring stores (and, later, lock keys) normalise; the legacy v1 key path does not call it and keeps the passphrase's raw UTF-8 bytes, so existing v1 stores still open.
- [ ] Tests:
  - make then unwrap gives the same key;
  - a wrong passphrase gives `wrongPassphrase`;
  - NFC and NFD forms of "Café" both unwrap a keyring;
  - `testV1PassphraseKeepsRawBytes`: a v1 store created with the NFD form opens with the NFD form and gives `wrongPassphrase` with the NFC form;
  - `rewrapped` keeps `keyID`;
  - `make` and `rewrapped` with `""` throw `passphraseRequired`;
  - `legacyKeyID` is stable for a fixed `Manifest.Encryption`;
  - the `Rekey.staleAfter` boundary.
- [ ] Add `keyring` cases to `fixtures/golden/manifest.json` through `VectorIO` (NFC and non-NFC passphrases, `expect: "ok"` with `keyID`). `expect` describes the manifest and its unwrapped key, not what this build opens: `supported` is still empty here, so `GoldenVectorTests` checks these cases with `Keyring.unwrap` and with `checkOpenable(_:supported: [.keyring])`.

**Verify:**
- `swift test --filter "KeyringTests|GoldenVectorTests" 2>&1 | tail -5` → `with 0 failures`.
- Full gate.

**Commit:** `feat(sync): keyring value types`

#### Task 3.3: `StoreSession`, `connectSession`, `refreshedSession`, session-based engine [S]

Moved from sync-security Task 0.2 and the session half of web-app Task 0.4.

**Files:**
- Modify: `Sources/NoteItSync/Engine/StoreSession.swift`, `Sources/NoteItSync/Engine/SyncEngine.swift` (`init`, `connect`, the pass entry point, every use of `cipher`), `Sources/NoteItSync/Engine/SyncEngine+Cipher.swift`, `Sources/NoteIt/Sync/SyncController.swift` (`Session`, `ensureSession`), `Sources/NoteIt/Sync/Keychain.swift`
- Create: `Sources/NoteItSync/Engine/SyncEngine+Session.swift`, `Tests/NoteItSyncTests/StoreSessionTests.swift`

- [ ] `StoreSession`, `BodyEncoding` and `StoreSessionRef` are built as frozen, including `StoreSession.supported` and `StoreSession.dataKey`. `StoreSessionRef` is protected by an `NSLock`.
- [ ] `StoreFeature.supported` becomes `[.keyring]` in this task, in the same commit as `connectSession` and the keyring cipher below, so no build claims `keyring` before it can open a keyring store. From here on, device records write `supportedFeatures` (`["keyring"]`).
- [ ] `connectSession(backend:kind:credential:deviceName:createIfMissing:encrypted:initialFeatures:supported:cipher:)`. `deviceName` is required; the last three parameters default to `[]`, `StoreFeature.supported` and `nil`, so wave 0 callers pass none of them:
  - It reads the manifest and its ETag, unquoted, and runs `checkOpenable` against `supported`.
  - It builds the cipher, unless `cipher` is non-nil, in which case the session uses the passed cipher (sharing passes its `SpaceCipher`) and builds none:
    - v1 encrypted: today's `openExisting` path; `keyID` is `legacyKeyID`.
    - keyring: `.passphrase` → `unwrap`, `.dataKey` → it must match `keyring.keyID`, else `wrongPassphrase`. The session's `dataKey` is that key. Every other kind of session below (v1, keyring pending, plain, passed cipher) has `dataKey` nil.
    - keyring pending: `features` contains `keyring`, but there is no `keyring` object and the legacy `encryption` block is still there. This is a valid intermediate state (a passphrase change or rekey added the feature and stopped before writing the keyring). It opens through the v1 encrypted path, and `keyID` is `legacyKeyID`. sync-security's `changePassphrase` and `RekeyRunner` `.personal` finish it.
    - `features` contains `keyring` with neither a `keyring` object nor an `encryption` block: `invalidManifest`, nothing written.
    - plain: `PassthroughCipher`; `keyID` is nil.
  - When the manifest is missing and `createIfMissing` is set, it creates the store as `connect` does today, and writes `initialFeatures` into that first manifest (program §4 rule 4, creation): sorted, with `formatVersion: 2` when the set is non-empty. It throws `invalidManifest` and writes nothing when the set breaks a `requires` rule or holds a feature outside `supported`. With the default `[]` the new store is a featureless v1 manifest, as today. `initialFeatures` is ignored when the store already exists.
  - Creating an encrypted store whose `initialFeatures` holds `.keyring` with an empty passphrase (length 0 after NFC normalisation) throws `passphraseRequired`, as the v1 path does, before it generates or wraps any key; nothing is written.
  - Creating an encrypted store whose `initialFeatures` holds `.keyring` with an empty `deviceName` throws `invalidManifest` before it generates or wraps any key; nothing is written.
  - Creating an encrypted store whose `initialFeatures` holds `.keyring`: it generates a random 32-byte data key, wraps it with `Keyring.make(dataKey:passphrase:deviceName:now:)` with the passed `deviceName` (which becomes `keyring.changedBy`; `Keyring.make` NFC-normalises the passphrase, per program §4 rule 12), writes the result as the manifest's `keyring` and writes no legacy `encryption` field. The session it returns uses the keyring cipher for that data key, with `keyID` set to `keyring.keyID` and `dataKey` set to the new key, exactly as if the store had been opened with the passphrase. The credential must be `.passphrase`. `.keyring` with `encrypted: false` throws `invalidManifest` and writes nothing.
  - Creating an encrypted store without `.keyring` in `initialFeatures` is the legacy v1 path, as today: an `encryption` field, no `keyring`, and the raw passphrase bytes. web-app Task 0.4 passes `[.noteItDoc]` (plus `.keyring` for an encrypted keyring store).
  - With a non-nil `cipher`, `credential` may be nil and `encrypted` must be true (`encrypted: false` with a cipher throws `invalidManifest`). Creating a store with a passed cipher writes an `encryption` block whose key check is sealed with the passed cipher, and no `keyring`. Opening with a passed cipher never checks a credential, but must open the manifest's key check with the passed cipher; if that fails it throws `wrongPassphrase`, writes nothing and returns no session (sharing maps this to its stale-space-key handling). Ordinary Sync pointed at such a store still fails safely: its passphrase can't open that key check, and a personal session refuses `noteit-space` anyway. Test: `testPassedCipherKeyCheckRoundTrip` (create with a passed cipher, then reopen with the same cipher succeeds; reopening with another cipher throws `wrongPassphrase`, returns no session and writes nothing).
  - The only feature check is the generic one, `checkOpenable` against `supported`. A `.library` session with the default `supported` refuses `noteit-space`. Sharing passes `StoreFeature.supported ∪ [.noteItSpace]` for space sessions and owns the space-session acceptance logic; wave 0 adds no space-specific check.
  - `connect` and `connectReportingCreation` remain as wrappers, so existing tests compile. They pass `deviceName: ""`; they never create keyring stores, so the name is never used.
  - The session keeps the `supported` set as `StoreSession.supported`, and a passed cipher, so `refreshedSession`, `updateManifest` and `updateRekey` check against `session.supported` and copy it into the session they return, and a refresh with an unchanged key ID keeps the same cipher and `dataKey`.
- [ ] `refreshedSession`:
  - same `keyID` and no foreign `rekey` → the new session, checked against `current.supported`, with the same `supported`, passed cipher and `dataKey`;
  - a foreign `rekey` younger than `Rekey.staleAfter` → `rekeyInProgress(deviceName:)`;
  - an older one → `rekeyIncomplete(done: 0, total: 0)` (sync-security fills in the real counts);
  - another `keyID` → `keyChanged(byDevice: keyring.changedBy)`.
- [ ] Engine changes:
  - `SyncEngine.init(backend:session:local:stateURL:deviceID:deviceName:appVersion:platform:)` stores the `StoreSessionRef`. `platform: DevicePlatform` defaults to `.mac`; the device record writes `platform.rawValue`, so the phone (mobile) passes `.ios` without another init.
  - The old `init(backend:cipher:…)` becomes a convenience that wraps a plain v1 session.
  - Every seal and open reads `session.current.cipher`.
  - At the start of each pass, `backend.get(RemoteLayout.manifest())` gives an ETag; if it differs from the session's, `refreshedSession` runs and the ref is replaced. `SyncState.keyID` is set from the session.
- [ ] `SyncController`:
  - `Session` gains `store: StoreSessionRef`.
  - `ensureSession` calls `connectSession` with `.dataKey` from `Keychain` (new account `syncDataKey`) when present, otherwise `.passphrase`, and with `deviceName` set to the name it gives `SyncEngine.init`. After a passphrase connect, it saves `session.dataKey` to `syncDataKey` when it is non-nil (a keyring store); a v1 or plain session saves nothing.
  - The engine gets `appVersion` from `Bundle.main` `CFBundleShortVersionString`.
  - The device-rename path rebuilds the engine with the same ref.
- [ ] Tests:
  - `testConnectV1ReturnsLegacyKeyID`;
  - `testConnectPlainHasNoKeyID`;
  - `testDataKeyCredentialMustMatch`;
  - `testNewStoreIsV1WithoutFeatures`;
  - `testInitialFeaturesOnlyOnCreation` (`createIfMissing` with `initialFeatures: [.noteItDoc]` and a widened `supported` writes a v2 manifest with `["noteit-doc"]`; the same call against an existing v1 store leaves it byte-for-byte unchanged; `[.lockedNotes]` alone throws `invalidManifest` and writes nothing);
  - `testPassedCipherIsUsed` (with `cipher:` set, records sealed through the session open with that cipher and no legacy, keyring or passthrough cipher is built);
  - `testCreateKeyringStore` (`createIfMissing` with `encrypted: true` and `initialFeatures: [.keyring]`: the manifest has `keyring` and `features: ["keyring"]` and no `encryption`; a record written through the returned session is read back after a fresh `connectSession` with the same passphrase, and its `keyID` matches);
  - `testKeyringCreateRejectsEmptyPassphrase` (`createIfMissing` with `encrypted: true`, `initialFeatures: [.keyring]` and `.passphrase("")` throws `passphraseRequired`; the backend stays empty and no session is returned);
  - `testKeyringCreateRequiresDeviceName` (the same create with `deviceName: ""` throws `invalidManifest`, the backend stays empty and no session is returned; with `deviceName: "Test Mac"` the manifest's `keyring.changedBy` is `"Test Mac"`);
  - `testSessionDataKey` (a created keyring store's session, and sessions opened on it with `.passphrase` and with `.dataKey`, all carry the same `dataKey`, whose `KeyIdentity.keyID` is the session's `keyID`; v1, keyring-pending, plain and passed-cipher sessions have `dataKey` nil);
  - `testConnectKeyringStoreWithDefaultSupported` (a keyring store opens with the default `supported`, which is now `[.keyring]`);
  - `testKeyringPendingOpensAsV1` (`features: ["keyring"]`, no `keyring`, a v1 `encryption` block: opens with the v1 passphrase, `keyID` is `legacyKeyID`, nothing written);
  - `testKeyringFeatureWithoutAnyKeyIsInvalid` (`features: ["keyring"]` with neither `keyring` nor `encryption` throws `invalidManifest` and writes nothing);
  - `testLibrarySessionRefusesSpaceFeature` (refused by the generic check with the default `supported`; the same store opens when `supported` is `StoreFeature.supported ∪ [.noteItSpace]`);
  - `testRefreshKeepsSessionWhenOnlyETagChanged` (the refreshed session keeps `supported` and `dataKey`; a space-style session opened with `StoreFeature.supported ∪ [.noteItSpace]` still accepts `noteit-space` after the refresh);
  - `testRefreshThrowsKeyChanged`;
  - `testRefreshThrowsRekeyInProgress`;
  - `testStaleRekeyReportsIncomplete`;
  - `testRunningEngineSeesNewFeature` (a manifest change between passes reaches `session.current.features`);
  - `testBodyEncodingFollowsFeatureNotVersion` (`formatVersion` 2 with only `keyring` → `.rtfd`; a `StoreSession` built directly with `noteit-doc`, not through `connectSession`, → `.noteItDocV1`);
  - `testDeviceWritesSupportedFeatures` (`["keyring"]`, with `appVersion`);
  - `testDevicePlatformDefaultsToMac` (an engine built without `platform:` writes `"mac"`);
  - `testDevicePlatformFromInit` (an engine built with `.ios` writes `"ios"`).

**Verify:**
- `swift test --filter "StoreSessionTests|SyncEngineTests|SyncPlannerTests|GoldenVectorTests" 2>&1 | tail -5` → `with 0 failures`.
- `NOTEIT_DATA_DIR=.selftest/s33 NOTEIT_SYNC_SELFTEST=1 swift run NoteIt 2>&1 | tail -1` → `PASS all checks`.
- Full gate.

**Commit:** `feat(sync): store sessions`

#### Task 3.4: `updateManifest`, `updateRekey`, `devicesBlocking`, `ensureFeature` [S]

**Files:**
- Create: `Sources/NoteItSync/Engine/SyncEngine+Features.swift`, `Tests/NoteItSyncTests/EnsureFeatureTests.swift`, `fixtures/golden/manifest-features.json`

- [ ] `updateManifest(backend:session:_:)`:
  - It reads the raw manifest JSON object, decodes `Manifest`, and applies `change`.
  - It writes back only the keys `Manifest` owns, so unknown keys survive.
  - It sets `formatVersion = 2` whenever `features` is non-empty, and writes `features` sorted.
  - It writes with `PUT If-Match: <etag>`.
  - On `preconditionFailed` it re-reads the manifest and checks it again before re-applying `change` (program §4 rule 3). The same checks run on the first read:
    - the `rekey` field is unset, else `rekeyInProgress(deviceName:)`;
    - the key ID matches the session's, else `keyChanged(byDevice:)`;
    - the manifest still suits the session kind, and `checkOpenable` passes with `session.supported` (features known and supported, `requires` met), else `manifestChangedConcurrently`.

    It never replays `change` onto a manifest that fails a check, and writes nothing in that case. It retries up to 3 times and then throws `manifestChangedConcurrently`.
  - It returns a new session from the written manifest, with the same `supported`, passed cipher and `dataKey` (the key ID is unchanged).
  - Because it refuses any manifest with `rekey` set, it can start a rekey (set the field) but never update or clear one; that is `updateRekey`'s job.
- [ ] `updateRekey(backend:session:expectedRekeyToKeyID:_:)`, the only writer allowed while `rekey` is set (sync-security's heartbeat and finish use it):
  - It shares `updateManifest`'s read, raw-key-preserving write, `If-Match`, 3 retries and `formatVersion` rule.
  - On the first read and on every retry it requires `manifest.rekey?.toKeyID == expectedRekeyToKeyID`, plus the session-kind and `supported`/`requires` checks above; otherwise it throws `manifestChangedConcurrently` and writes nothing. It does not check the key ID against the session's, because finishing a rekey changes it.
  - `change` may update or clear `rekey` and the fields that move with it (`keyring`, `encryption`, and `rekey`'s own `previousKeyring` and `previousEncryption`). If it changes any other manifest key, the call throws `invalidManifest` and writes nothing.
  - It returns a new session from the written manifest with the same `supported`. When the key ID is unchanged it also keeps the passed cipher and `dataKey`; when the write changed the key ID (a rekey finish) `dataKey` is nil, and sync-security's `RekeyRunner` returns a session with the new cipher and, for `.personal`, `dataKey` set to the new key.
- [ ] `devicesBlocking(_:backend:session:currentDeviceID:)` lists everything under `devices/` (in a space store that includes `<member-id>/<UUID>.json` records) and returns a `FeatureBlocker` for each device whose `deviceID` is not `currentDeviceID` and whose `supportedFeatures` lacks the feature or anything in its `requires`. A record without `supportedFeatures` counts as supporting no features, whatever its `platform`. `deviceID` is compared as an opaque string, so a space device ID `<member-id>/<UUID>` works. The record with `deviceID == currentDeviceID` is always skipped, even when it is stale (written before Task 3.3, so without `supportedFeatures`), because this device is the one adding the feature.
- [ ] `ensureFeature(_:backend:session:currentDeviceID:confirm:)` passes `currentDeviceID` on to `devicesBlocking`, returns a `FeatureAddition`, and:
  - Returns the session unchanged, with no `lateBlockers`, if the feature is already set.
  - Throws `unsupportedFeature(raw)` when the feature or anything in its `requires` is outside `supported` (internal parameter, default `StoreFeature.supported`): a build never adds a feature it can't read. In wave 0 this refuses every feature except `keyring`; the tests below pass a wider set to cover the `noteit-doc` and `locked-notes` paths.
  - Throws `rekeyInProgress` while the `rekey` manifest field is set.
  - Adds everything in `feature.requires` first, in the same manifest write: `ensureFeature(.lockedNotes, …)` on a store without `noteit-doc` adds both, and the blocker list covers both.
  - Calls `confirm` only when the blocker list is non-empty; `false` throws `featureDeclined(raw)` and writes nothing.
  - Then calls `updateManifest` to insert the feature.
  - If a 412 re-read already shows the feature with the same `keyID`, it adopts that manifest.
  - The device list is a warning, not a fence (program §4 rule 4): a device can write its record between the check and the manifest write. After a successful write, `ensureFeature` lists devices again and returns every blocker that was not in the list `confirm` saw as `lateBlockers`. It never undoes the write. The caller shows them once as a notice.
- [ ] `manifest-features.json` uses the web-app case shape. Its `expect` values describe manifest validity with every known feature supported, not what a wave 0 build opens. Its cases:
  - v1;
  - v2 with only `keyring`;
  - v2 with `noteit-doc`;
  - `keyring` + `noteit-doc` + `locked-notes`;
  - `locked-notes` without `noteit-doc` (`invalidManifest`);
  - the `rekey` field set (no `rekey` entry in `features`);
  - unknown extra keys kept in `upgradedManifestJSON`.
- [ ] Tests:
  - `testUpdateManifestKeepsUnknownKeys`;
  - `testUpdateUsesSessionSupported` (a store with `noteit-space`, opened with `supported: StoreFeature.supported ∪ [.noteItSpace]`: `updateManifest`, including a 412 retry, and `updateRekey` succeed without any `supported` argument, and the sessions they return have the same `supported` and `dataKey`);
  - `testUpdateManifestRetriesOn412` (an `InMemoryBackend` that changes the manifest once between read and write);
  - `testUpdateManifestGivesUpAfterThreeConflicts`;
  - `testRetryStopsWhenRekeyStarts` (another device sets `rekey` between the first read and the retry: `ensureFeature` throws `rekeyInProgress` and the stored manifest is unchanged);
  - `testRetryStopsWhenKeyChanges` (another device rewraps to a new key ID before the retry: `keyChanged`, manifest unchanged);
  - `testRetryStopsOnUnsupportedFeature` (another device adds a feature outside `supported` before the retry: `manifestChangedConcurrently`, manifest unchanged);
  - `testAnyFeatureImpliesVersion2`;
  - `testEnsureFeatureAsksOnlyWhenBlocked`;
  - `testEnsureFeatureDeclinedWritesNothing`;
  - `testEnsureFeatureRefusedDuringRekey`;
  - `testEnsureFeatureRefusesUnsupported` (`noteit-doc` with the default `supported` throws and writes nothing);
  - `testLockedNotesAddsNoteItDocFirst`;
  - `testDeviceWithoutSupportedFeaturesBlocks`;
  - `testOwnStaleDeviceRecordDoesNotBlock` (the store has this device's own record without `supportedFeatures` and no other device: `devicesBlocking` with that `currentDeviceID` returns nothing, and `ensureFeature` never calls `confirm`; the same record under another device ID blocks);
  - `testEnsureFeatureIdempotent`;
  - `testDeviceAppearingDuringWriteIsReportedAfter` (a backend that adds another device's record without `supportedFeatures` after the device check and before the manifest write: the write succeeds, `confirm` was not called, and `lateBlockers` names that device);
  - `testUpdateManifestRefusesWhileRekeySet` (`rekeyInProgress`, manifest unchanged);
  - `testUpdateRekeyHeartbeatAndFinish` (with a matching `expectedRekeyToKeyID` it updates `rekey.updatedAt`, then clears `rekey` and swaps `keyring` in one write);
  - `testUpdateRekeyStopsWhenRekeyChanges` (another device replaces `rekey` with a different `toKeyID`, or clears it, before the retry: `manifestChangedConcurrently`, manifest unchanged);
  - `testUpdateRekeyRefusesOtherKeys` (a `change` that also edits `features` throws `invalidManifest` and writes nothing);
  - the `manifest-features.json` vectors.

**Verify:**
- `swift test --filter "EnsureFeatureTests|GoldenVectorTests" 2>&1 | tail -5` → `with 0 failures`.
- Full gate.

**Commit:** `feat(sync): read-modify-write manifest and ensureFeature`

#### Task 3.5: `RemoteLayout` registry, `RekeyScope`, `RawMetaOverlay` and the Mac's raw meta [S]

**Files:**
- Modify: `Sources/NoteItSync/Engine/RemoteLayout.swift`, `Sources/NoteItSync/Engine/RekeyScope.swift`, `Sources/NoteItCore/Library/LibraryFile.swift` (`appliedRemoteRevisions`), `Sources/NoteIt/Model/NoteStore+Sync.swift` (`exportPlan`, `applyRemote`/`decodeMeta`, notebook apply, purge), `Sources/NoteIt/Model/NoteStore.swift` (`trashPendingBodies` deletes the purged records' raw files), `Sources/NoteIt/Sync/NoteStoreSyncAdapter.swift`
- Create: `Sources/NoteItSync/Model/RawMetaOverlay.swift`, `Sources/NoteItCore/Models/CodingKeyNames.swift`, `Sources/NoteIt/Model/NoteStore+RawMeta.swift`, `Tests/NoteItSyncTests/{RemoteLayoutRegistryTests,RawMetaOverlayTests}.swift`, `Tests/NoteItTests/{RawMetaStoreTests,PurgeAuxFilesTests}.swift`, `fixtures/golden/layout-keys.json`

- [ ] `RemoteLayout.prefixes` is one literal list, with four rows in wave 0. Each row has `depth: 1`, `sealing: .storeKey` and `owner: "core"`:

  | Prefix | Depth | Sealing | Example key |
  |---|---|---|---|
  | `inkwell/v1/notebooks/` | 1 | `.storeKey` | `inkwell/v1/notebooks/<UUID>.json` |
  | `inkwell/v1/notes/` | 1 | `.storeKey` | `inkwell/v1/notes/<UUID>.meta`, `inkwell/v1/notes/<UUID>.body` |
  | `inkwell/v1/tombstones/` | 1 | `.storeKey` | `inkwell/v1/tombstones/<UUID>.json` |
  | `inkwell/v1/devices/` | 1 | `.storeKey` | `inkwell/v1/devices/<UUID>.json` |

  Outside the table: `manifestKey` (`manifest()`, never sealed) and `inkwell/.canary/<UUID>` (depth 1 under `canaryPrefix`, treated as `.unsealed`). Each sub-project that adds a prefix adds its row with depth and sealing, plus vectors in `layout-keys.json`.
  - The three sealing kinds follow program §4 rule 6. `.storeKey` means sealed with the session's key: the personal store key, or the space key in a space session. `.spaceKey` is for space-key objects inside a personal store. `.unsealed` is for signed logs, HPKE key files and the canary; they are never re-sealed. Wave 0 has no `.spaceKey` or `.unsealed` rows.
  - `prefix(for:)` returns the longest matching row whose depth equals the key's.
  - `prefix(for:)` and `isValidKey(_:)` take an internal `prefixes:` parameter defaulting to `RemoteLayout.prefixes`, as `RekeyScope` does, so tests can add rows.
  - The existing builder functions stay.
- [ ] Key grammar (program §4 rule 8), as `isValidKey(_:)` and `isListablePrefix(_:)`:
  - every segment matches `[A-Za-z0-9._-]+` and is not `.` or `..`;
  - a segment whose part before the first `.` parses as a UUID must be the uppercase canonical form;
  - the key is `manifestKey`, a canary key, or sits under a registered prefix at exactly the depth of a row with that path (two rows may share a path with different depths);
  - a list request must name a registered prefix path, `canaryPrefix`, or a parent root of one: any shorter prefix that ends at a `/`, such as `inkwell/v1/` and `inkwell/`. Legacy clients (the 0.2.x engine, rclone) list from those roots and keep working. `""` and prefixes that don't end in `/` are refused.

  The builders already produce uppercase `uuidString`, and device IDs are uppercase UUIDs (`SyncConfiguration.stableDeviceID`). In space stores the device ID is `<member-id>/<UUID>` (sharing spec §4.1). Nothing in foundations parses a device ID as a UUID: `deviceID`, `currentDeviceID` and `FeatureBlocker` treat it as an opaque string, so space sessions accept that form.
- [ ] `RekeyScope.action(for:rekeying:prefixes:)`, with `rekeying` defaulting to `.storeKey` and `prefixes` to `RemoteLayout.prefixes`, returns:
  - `.skip` for `manifestKey` and canary keys;
  - `.skip` for any `.unsealed` row, whatever is being rekeyed;
  - `.reseal` for a row whose sealing equals `rekeying`;
  - `.skip` for a row with the other key sealing (`.spaceKey` rows during a `.storeKey` rekey, and the reverse);
  - `.block` for any other key in the store, under `inkwell/` or not.

  `rekeying: .unsealed` is a programming error (`preconditionFailure`). Its doc comment states the program §4 rule 7 scope rule. `RekeyRunner`, the `rekeyAck` fence and the runner's tests stay in sync-security.
- [ ] `layout-keys.json` (`generator: "spec"`) is the web server's test vector file. It has two lists:
  - `keys`: `{key, valid, prefix, action}` cases: one valid key per row and for the manifest and canary; a lowercase UUID; a `.` and a `..` segment; an empty segment (`//`); a character outside the set (space, `%`, `+`); a key one level too deep (not under `devices/`, where sharing adds a depth-2 row on the same path) and one too shallow; an unregistered prefix (`valid: false`, `action: "block"`).
  - `listPrefixes`: `{prefix, allowed}` cases: each registered prefix and `canaryPrefix` allowed; the parent roots `inkwell/v1/` and `inkwell/` allowed; `""`, `inkwell/v2/`, `inkwell/v1/notes` (no trailing `/`) and `other/` refused.
- [ ] `RemoteLayoutRegistryTests`:
  - `testEveryListedPrefixIsRegistered`: every key the builders produce has a row and is valid;
  - `testKeyGrammar` and `testListPrefixes`: the `layout-keys.json` vectors pass;
  - `testRekeyScope`: an unknown prefix is `.block`; manifest and canary are `.skip`; a `.spaceKey` row passed through `prefixes` is `.skip` for a `.storeKey` rekey and `.reseal` for a `.spaceKey` rekey; an `.unsealed` row passed through `prefixes` is `.skip` for both;
  - `testSamePathDifferentDepthRows`: with the sharing row `inkwell/v1/devices/` (depth 2) passed through `prefixes` beside the wave 0 depth-1 row, the personal key `inkwell/v1/devices/<UUID>.json` and the space key `inkwell/v1/devices/<member-id>/<UUID>.json` are both valid, and `prefix(for:)` returns the depth-1 row for the first and the depth-2 row for the second;
  - `testLegacyListRootsAllowed`: `isListablePrefix("inkwell/v1/")` and `isListablePrefix("inkwell/")` are true, and `""` is false.
- [ ] `RawMetaOverlay.merged(with:ownedKeys:)` produces:
  - keys in `ownedKeys` from `encoded` (absent when absent there, so a cleared optional is removed);
  - all other keys from `lastDecrypted`;
  - `encoded` unchanged when `lastDecrypted` is nil.

  The output is `.sortedKeys` with the same date strategy as `NoteStore.encoder`.
- [ ] `NoteMeta.ownedCodingKeys` and `Notebook.ownedCodingKeys` hold the coding-key names of every stored property. A test in `ModelCodingTests` compares each set with the keys of an encoded value with every optional set.
- [ ] On the Mac:
  - `NoteStore+RawMeta` keeps the last decrypted note JSON in `<rootURL>/sync-meta-raw/notes/<UUID>.json` and notebook JSON in `<rootURL>/sync-meta-raw/notebooks/<UUID>.json`. The folder is namespaced by `RawMetaKind` (`sync-meta-raw/<rawValue>/`), so records of different kinds never share a file even when their UUIDs are equal. Any later kind that keeps raw meta gets its own subfolder (the per-kind contract below). `sync-meta-raw/` is in `NoteStore.rootURL` (the data folder), never in a Markdown library's content folder; it is the foundations row of the program §7 file table.
  - Each file is a `RawMeta`: the decrypted meta bytes and their `sourceRevision`, the `RecordPayload.revision` of the payload they came from. That is the revision the engine records as applied (`SyncState.Base.revision`, set in `adopt`).
  - The apply path stores it, through `decodeMeta` and the notebook apply, with `setLastRemoteMeta`, which `throws`. The raw file is written before the record is applied. If the write throws, that record's apply is skipped for this pass: it is not marked applied, and the next pass retries it.
  - A successful apply sets the record's `appliedRemoteRevisions` entry to `payload.revision`, in the same library save as the applied record. Local edits and this Mac's own pushes don't change it: the meta this Mac pushes was merged from that raw file, so the file still describes the remote's unknown keys.
  - A raw file whose `sourceRevision` differs from the record's `appliedRemoteRevisions` entry (or with no entry) is never merged. That happens when the raw write succeeded but the apply was skipped or failed. `lastRemoteMeta` returns nil for it, so the record exports as if there were no raw file, and the next successful apply of that record replaces it. The write order stays raw first; the binding is what makes it safe.
  - `exportPlan` merges every note and notebook meta through `RawMetaOverlay`, with `lastDecrypted: lastRemoteMeta(for:kind:)`, before sealing.
  - Purging a note (the private `removeNotes` loop: Delete Now, Empty Recently Deleted, the automatic purge, remote removal) drops its `appliedRemoteRevisions` entry in the purge's library save and deletes nothing on disk. `removeNotes` already queues the ID in `pendingTrash`; `trashPendingBodies` deletes `sync-meta-raw/notes/<UUID>.json` in the same pass as the body's `.trash` move. That pass runs from `flush` and `persistRemoteApply` only once the library save has succeeded (`libraryDirty` is false), and an ID leaves `pendingTrash` only when the saved `library.json` doesn't list it. So a failed library save deletes no file: the raw file and the body stay, and a new `NoteStore` on the same root lists the note again and merges its raw meta. If the file delete throws, the error is logged and the ID stays in `pendingTrash` (persisted with the tombstones), so the next flush retries it. A deleted notebook's raw file follows the same rule through the generic queue: the notebook delete drops its `appliedRemoteRevisions` entry in its library save and calls `queueRawMetaDeletion(_:kind: .notebooks)`; the queue (keyed by kind, persisted with the tombstones) is drained in that pass, which also runs when only this queue is non-empty, deleting each file once `isDurablyListed(_:kind:)` is false (for notebooks: the saved `library.json` no longer lists it); an entry stays queued when the delete throws. This is the rule for every per-record file foundations adds in the data folder; Tasks 4.1 and 4.5 apply it to the body-extras sidecar and to Version History.
  - Local-only notes have no file and export as today.
- [ ] Per-kind contract. `notes` and `notebooks` are built this way, and a later kind that keeps raw meta (organise's `smartFolders = "smart-folders"`, surfaces-polish's `boards`) uses the same `NoteStore+RawMeta` functions and adds exactly:
  1. a `RawMetaKind` case whose `rawValue` is its subfolder of `sync-meta-raw/`, and that folder's row in the program §7 file table;
  2. its applied-revision map, `[String: UUID]` keyed by uppercase `uuidString`, local only and never synced, kept in the kind's own data-folder file and saved in the same atomic write as the applied record. A kind stored as one file per record may instead keep that record's applied revision (`UUID?`) inside the record's own file, which meets the same rule. A successful apply sets the entry to `payload.revision`; local edits and this Mac's own pushes don't change it; the save that removes the record drops it. Its arm in `appliedRemoteRevision(for:kind:)` reads that map;
  3. its arm in `isDurablyListed(_:kind:)`, answered from the last successfully saved copy of that file;
  4. on apply, `setLastRemoteMeta(RawMeta(sourceRevision: payload.revision, meta: decrypted), for:kind:)` before the record is applied; a throw skips that record's apply this pass and leaves its entry unchanged;
  5. on export, `RawMetaOverlay(lastDecrypted: lastRemoteMeta(for:kind:)).merged(with: encoded, ownedKeys: <Model>.ownedCodingKeys)` before sealing, with the model's `ownedCodingKeys` in `Models/CodingKeyNames.swift` and its `ModelCodingTests` check;
  6. on removal (local delete or remote deletion), `queueRawMetaDeletion(_:kind:)` after the removing save is queued; the file is never deleted directly;
  7. its own copies of the four lifecycle tests below: an unknown key survives a local edit, an unapplied raw file is not merged, a failed save keeps the file and a successful one deletes it, and the relaunch test (a new `NoteStore` on the same root, then a local edit, still exports the unknown key).
  Nothing else in foundations changes for a new kind.
- [ ] Tests:
  - `testRawMetaOverlayKeepsUnknownFields`;
  - `testClearedOptionalIsRemoved`;
  - `testNewRecordIsEncodedUnchanged`;
  - `RawMetaStoreTests`: apply a remote meta with an extra key `"futureField"`, edit the title locally, export, and the sealed plaintext still has `futureField`;
  - an existing note without a raw file exports the same bytes as before;
  - `RawMetaStoreTests.testRawMetaKindsDoNotCollide`: a note and a notebook with the same UUID, each applied with a different unknown key (`"noteFuture"` and `"notebookFuture"`), get separate files under `notes/` and `notebooks/`; after a local edit of each, the exported note keeps only `noteFuture` and the exported notebook keeps only `notebookFuture`, applying the notebook leaves the note's `appliedRemoteRevision` unchanged and the reverse, and purging the note leaves the notebook's file in place;
  - `RawMetaStoreTests.testUnappliedRawMetaNotMerged`: apply revision R1 with `"futureField": 1`; then write the raw file for R2 with `"futureField": 2` and make the apply fail (the adapter refuses it because the local note changed). The note's `appliedRemoteRevisions` entry stays R1, so the raw file's `sourceRevision` doesn't match. A local title edit then exports with no `futureField` at all, the same bytes as a note without a raw file. After the next successful apply of R3 with `"futureField": 3`, a local edit exports `"futureField": 3`;
  - `RawMetaStoreTests.testRawMetaSurvivesRelaunch`: apply a remote note and a remote notebook, each with `"futureField"`, and flush; a new `NoteStore` on the same root reads the applied revisions from `library.json`, and after a local edit of each the exports still have `futureField`;
  - `RawMetaStoreTests.testKindFolders`: for every `RawMetaKind.allCases`, the file goes to `sync-meta-raw/<rawValue>/<UUID>.json`, and the raw values are distinct, non-empty and match `[a-z-]+`, so a later kind is checked as soon as it adds its case;
  - `RawMetaStoreTests.testRawMetaSurvivesOwnPush`: apply a remote note with `"futureField"`, edit and push it, then edit again; the second export still has `futureField`, because a push doesn't change the `appliedRemoteRevisions` entry;
  - `RawMetaStoreTests.testRawMetaWriteFailureSkipsApply`: with the raw folder made unwritable, applying a remote note meta leaves the note unchanged and not marked applied; after the folder is writable again, the next pass writes the raw file and applies the record. With the delete failing, a purge still purges the note, logs, keeps the ID in `pendingTrash`, and the next flush removes the leftover raw file;
  - `PurgeAuxFilesTests.testFailedLibrarySaveKeepsAuxFiles`: a note applied from a remote meta with `"futureField"` (so it has a raw file) is purged with Delete Now while `library.json` is replaced by a directory, so the library save fails. After `flush()` the raw file and the `.rtfd` package are still in place and nothing is in `.trash/`. With the saved `library.json` put back, a new `NoteStore` on the same root lists the note, and a local edit exports `futureField`;
  - `PurgeAuxFilesTests.testAuxFilesRemovedAfterDurableDelete`: the same purge with a working library. Right after `removeNotes`, before `flush`, the raw file still exists. After `flush()`, `library.json` doesn't list the note, the body is in `.trash/` and the raw file is gone. A deleted notebook's raw file likewise survives a failed library save and is gone after a successful one.

**Verify:**
- `swift test --filter "RemoteLayoutRegistryTests|RawMetaOverlayTests|RawMetaStoreTests|PurgeAuxFilesTests|ModelCodingTests|SyncEngineTests" 2>&1 | tail -5` → `with 0 failures`.
- `NOTEIT_DATA_DIR=.selftest/s35 NOTEIT_SYNC_SELFTEST=1 swift run NoteIt 2>&1 | tail -1` → `PASS all checks`.
- Full gate.

**Commit:** `feat(sync): remote layout registry and raw meta overlay`

### Step 4: `NoteStore` seams

Moved here:
- markdown-storage M1 (`NoteBodyStorage`, `BodyCodec`);
- organise T3 (`editBody`, `OpenEditorRegistry` and the `DerivedIndex` registry; search index v2 stays in organise);
- the `localNoteChange` notification that plugins observe;
- the sync-security lock fields;
- the linking daily-note helpers and the `DailyNotes.isAvailable` gate.

Task 4.1 is serial and must be done first, because it touches every body read and write. After it, 4.2 (which also needs 2.3) and 4.3 can run in parallel. 4.4 and 4.5 need 4.3 (they check `isLocked`), and 4.6 needs 4.5 (it calls `editBody`).

#### Task 4.1: `NoteBodyStorage` and `RTFDBodyStorage` [S]

**Files:**
- Create: `Sources/NoteIt/Model/{NoteBodyStorage,RTFDBodyStorage,NoteStore+BodyExtras}.swift`, `Tests/NoteItTests/{BodyStorageContract,RTFDBodyStorageTests,BodyExtrasTests,PersistNowTests}.swift`; modify `Tests/NoteItTests/PurgeAuxFilesTests.swift` (Task 3.5)
- Modify: `Sources/NoteIt/Model/NoteStore.swift`. The following become calls on `bodyStorage`:
  - `bodyURL(for:)`, `readBody(at:)` and the private `bodyIDsOnDisk`;
  - `writeBody`, `writeTempBody` and `installBody`;
  - `writeRecoveryCopy` and `trashPendingBodies`;
  - `contentRevisions` (`RevisionInput.bodyURL` from `revisionInputURL(for:)`);
  - `exportBodySource`;
  - `flush`, whose per-note body write becomes one private step that `persistNow` also uses.

  Also modify `Sources/NoteIt/Model/{NoteStore+Trash,NoteStore+Sync,VersionHistory}.swift` where they build a body path.

- [ ] Move the body file code out of `NoteStore` into `RTFDBodyStorage` unchanged. The static `NoteStore.readBody`, `writeTempBody` and `installBody` stay as thin forwards to `RTFDBodyStorage`, because `VersionHistory`, `ExportTests` and `VersionHistoryTests` call them; they are not removed in wave 0. That covers the package layout, the `.trash/<id>-<timestamp>.rtfd` naming, the file-wrapper reads and writes, the atomic temp-then-replace install, and the recovery copy format.
  - `NoteStore` creates `RTFDBodyStorage(rootURL:)` in `init` and keeps it as `bodyStorage`.
  - `bodyURL(for:)` stays as a one-line forward to `fileURL(for:)`, so callers outside the model (export, Quick Look, self-tests) keep compiling.
  - The `notebook:` parameters are unused by RTFD and are passed through so the Markdown storage can use them.
- [ ] `NoteStore.bodyExtras`: the extras of each loaded body, by note ID, always filled from disk.
  - Every body read through `bodyStorage.read` (load, `body(for:)`, `recover`) stores `StoredBody.extras` in `bodyExtras[id]`. On an RTFD store those extras come from the sidecar (next item).
  - Every body write passes `bodyExtras[id] ?? .empty` as `extras`: the editor save and `updateBody` (`writeBody`, `writeTempBody`), and `editBody` (Task 4.5) because it goes through `updateBody` (a non-nil `extras` given to `editBody` replaces `bodyExtras[id]` before that write). Sync apply (`prepareRemoteNote`/`applyPreparedRemoteNote`) stages the incoming body's extras (`.empty` for an RTFD body) and writes with them, passed directly rather than through `bodyExtras`. It assigns them to `bodyExtras[id]` only after the body is installed (on an RTFD store, after step 2 of the sidecar write below); when the apply fails at any step, `bodyExtras[id]` keeps its old value.
  - The private `removeNotes` loop (Delete Now, Empty Recently Deleted, the automatic purge, remote removal) drops `bodyExtras[id]`.
  - `RTFDBodyStorage` reads `.empty` and ignores `extras` on write, so the `.rtfd` packages are byte-identical to before.
- [ ] The body-extras sidecar (`NoteStore+BodyExtras.swift`), used only when `bodyStorage.kind == .rtfd`. An `.rtfd` package can't hold extras or unknown language IDs (the code-language tab stop keeps known languages only), so `NoteStore` keeps them in `<rootURL>/body-extras/<UUID>.json`:
  - Shape: `{"current": Entry, "previous": Entry?}` with Entry `{"bodySHA256": "…", "extras": {"frontMatter": …, "extra": {…}}, "codeLanguageIDs": [String?]}` (`BodyExtrasSidecar` and `BodyExtrasEntry`), built and parsed as a `JSONValue` (`encoded()`/`decode`), so numbers keep their tokens. `previous` is omitted when there is none. `codeLanguageIDs` has one entry per code paragraph (one `codeBlock` each, Task 2.3) in document order: the paragraph's `noteItCodeLanguageID` at write time, or `null`. `bodySHA256` is `RTFDBodyStorage.packageDigest(at:)` of the package the entry belongs to: on a write, of the temp package from `prepareTemp`, which `installTemp` moves into place unchanged; on a read, of the installed package.
  - Every body write of the note (`writeBody`, `installBody` after `writeTempBody`, sync apply) goes through `prepareTemp`, then three steps:
    1. Write the sidecar atomically (a temp file in `body-extras/`, then rename) with `current` = the new entry and `previous` = the entry for the body now on disk. That is the existing sidecar's entry whose `bodySHA256` equals `packageDigest` of the installed package; an empty entry with that digest when there is a package but no sidecar; and none when there is no package or no entry matches. When there is no sidecar and the new entry `isEmpty`, this step and step 3 write nothing.
    2. `installTemp` the body.
    3. Rewrite the sidecar atomically with `previous` removed, or delete it when `current` `isEmpty`. Empty new extras never delete the file before step 2.
  - A failed step 1 fails the whole body write: it throws before the body is touched, and the temp package is removed. The editor keeps its unsaved text and the note stays dirty, as for any failed save; sync apply skips that record this pass, as for any failed apply. A failed step 2 leaves the step 1 file, which still reads the old body with `previous`; the write throws as today. A failed step 3 is logged and doesn't fail the write: `current` matches the new body, and the next write replaces the file. There is no separate retry of the sidecar.
  - An internal test hook, `bodyWriteInterruption: BodyWriteStep?` (`.afterSidecarStage`, `.afterBodyInstall`), stops a write after that step and throws, leaving the files as a crash there would.
  - Every `.rtfd` read (load, `body(for:)`, `recover`) loads the sidecar when it exists:
    - Missing: `.empty` with no IDs. This is the normal case for a note without extras.
    - Present but unreadable or undecodable: the read sets `StoredBody.readOnlyReason` to `StoredBody.bodyExtrasUnreadable` and logs it. `NoteStore` blocks writes to the note the way it does today for an unreadable body (`isBodyWriteBlocked` is true, the editor and `editBody` refuse it, and the reason shows in the editor's load-error banner like other read-only reasons). Nothing is deleted or overwritten: the sidecar and the body stay as they are.
    - Readable: the read takes `entry(forBodySHA256: packageDigest(at:))`: the entry that matches the package, else `current`, and logs when neither matches (the `.rtfd` was changed outside `NoteStore`). Its extras go into `StoredBody.extras` and `bodyExtras[id]`. A crash after step 1 therefore reads the old body with `previous`, and a crash after step 2 the new body with `current`.
    - The entry's IDs are set as `noteItCodeLanguageID` on the code paragraphs by position, only when the text's code-paragraph count equals the entry's count; otherwise all of them are dropped and the mismatch is logged.
  - Purging the note deletes the sidecar together with the body, under Task 3.5's rule: the private `removeNotes` loop deletes nothing on disk, and `trashPendingBodies` deletes `body-extras/<UUID>.json` in the same pass as the body's `.trash` move, only after the library save that drops the note has succeeded and the saved `library.json` no longer lists it. A failed library save leaves the sidecar, so a relaunch that still lists the note reads its extras. A failed delete is logged and the ID stays in `pendingTrash` for the next flush. Moving a note to Recently Deleted keeps the sidecar, so a restored note gets its extras back.
  - `.noteItDoc` bodies (the container holds the extras and each `language`) and Markdown bodies never read or write the sidecar.
- [ ] `persistNow(_:)` (frozen; program §6), for capture paths that remove their source once the note is on disk:
  - It first commits the note's staged editor snapshot (`commitStagedEditorBody(id)`), then checks the note: missing → `noteMissing`; in `bodyWriteBlocked` with a dirty body → `writeBlocked`, writing nothing.
  - When the body is dirty, it runs the same private per-note step as `flush` (`recordSavedBody`, sidecar step 1, body install, sidecar step 3) and, on success, the same bookkeeping (`dirtyBodies`, `failedBodies`, `unversionedLocalBodies`). A failure keeps the note dirty and in `failedBodies`, with flush's recovery-copy rule, logs the cause and throws `bodyNotSaved` before the library is written.
  - Then, when `libraryDirty` or `library.json` is missing, `saveLibrary()`; `false` throws `libraryNotSaved`. The body is saved first, so the library lists the note with its current title and preview.
  - It returns only after both installs (the body's `replaceItemAt`/move and the library's `.atomic` write) have finished. A clean note with a saved library writes nothing.
  - It leaves other dirty notes, the search index, pending trash moves and the local-change announcement to the scheduled `flush`, and doesn't cancel it. Nothing calls it in wave 0; automation and capture-plus are the first callers.
- [ ] `read` throws `CocoaError(.fileReadNoSuchFile)` for a missing note. The load-error path in `NoteStore` keeps its current messages.
- [ ] `BodyStorageContract` is a plain helper, not an `XCTestCase`, so XCTest never runs it on its own: `enum BodyStorageContract { static func runAll(make: (URL) -> NoteBodyStorage, file: StaticString = #filePath, line: UInt = #line) }`, plus one `static func assert…(make:)` per check so a failure names the check. It has at least one check for every member of the frozen `NoteBodyStorage` protocol, and each check names the members it asserts:
  - `assertKind`: `kind` is the same on two storages made for the same root and doesn't change after writes. The exact value is asserted by each concrete test case (`RTFDBodyStorageTests.testKind`: `.rtfd`), so `runAll(make:)` keeps its signature for markdown-storage;
  - `assertContentRoot`: `contentRootURL` is inside the root passed to `make`, and after a `write` the note's `fileURL(for:)` is inside `contentRootURL`;
  - `assertWriteRead`: `write` then `read` gives the same text and a nil `readOnlyReason` (each concrete test case asserts what `read` returns as `extras`, so the helper works for both formats);
  - `assertMissingReadThrows`: `read` of an unknown ID throws `CocoaError(.fileReadNoSuchFile)`;
  - `assertWriteMetadataOnly`: after a `write`, `writeMetadataOnly` with a changed title and notebook leaves `read` giving the same text and `idsOnDisk` unchanged, and on a note never written it throws nothing and creates no body that `read` returns;
  - `assertIDsOnDisk`: `idsOnDisk` lists a note after `write` and drops it after `removePermanently`;
  - `assertTempInstall`: `prepareTemp` + `installTemp` gives the same `read` result as `write`, and the temp URL no longer exists afterwards;
  - `assertTrashRecover`: `moveToTrash` removes the note from `idsOnDisk` and `read` throws; `recover` returns the newest trashed copy, and returns nil for an ID never trashed;
  - `assertRemovePermanently`: after `removePermanently`, `read` throws and `fileURL(for:)` no longer exists on disk;
  - `assertRevisionInput`: `revisionInputURL` exists after a `write`, is stable across identical writes, and is nil (or a missing file) for an unknown ID;
  - `assertFileURL`: `fileURL(for:)` is the same URL on every call for an ID, differs between IDs, and exists on disk after `write`;
  - `assertRecoveryCopy`: `recoveryCopy` writes into the given directory and the result reads back to the same text;
  - `assertNotebookRename`: after writing a note in a notebook, `renameNotebook(_:from:)` throws nothing, and the note still reads back with the same text, is still in `idsOnDisk`, and exists at its current `fileURL(for:)`;
  - `assertNotebookRemove`: `removeNotebook(_:)` on a notebook whose notes were removed with `removePermanently` throws nothing, and a note written in another notebook still reads back with the same text.

  For RTFD the two notebook members are no-ops, and the checks also assert that nothing under `contentRootURL` changes.

  `runAll` calls every `assert…` above. `RTFDBodyStorageTests` is a concrete `XCTestCase` whose test methods call the helper with `RTFDBodyStorage(rootURL:)` (one test method per check, or `testContract` calling `runAll`), plus `testKind` and `testExtrasIgnored` (`write` with a non-empty `extras`, then `read` gives `.empty` and the same file bytes as a write with `.empty`). markdown-storage later adds `MarkdownBodyStorageTests`, another concrete `XCTestCase` that calls the same helper.
- [ ] `BodyExtrasTests`:
  - On a spy storage that wraps `RTFDBodyStorage` but reports `kind` `.markdown` (so the sidecar is off), returns a `frontMatter` and an unknown top-level key as `extras` from `read`, and records the `extras` of every write: after load, an editor save, `updateBody` and a temp write each pass those extras unchanged, also when the edit empties the document; purging the note removes `bodyExtras[id]`.
  - `testRTFDSidecarKeepsExtrasAcrossRelaunch`: on a plain RTFD store, a note is written through sync apply with incoming extras holding a `frontMatter` and an unknown top-level key holding `9007199254740993`; a new `NoteStore` on the same root reads the same extras, with the same token, and an editor save passes them on.
  - `testRTFDSidecarKeepsUnknownLanguage`: a note with a `zig-nightly` and a `swift` code paragraph, saved, then read by a new `NoteStore` on the same root, exports both `language` values.
  - `testSidecarCountMismatchDropsIDs`: after the note is saved, its `.rtfd` is rewritten outside `NoteStore` with one more code paragraph; the next read sets no `noteItCodeLanguageID`, keeps the extras and logs the mismatch.
  - `testSidecarRemovedOnPurge`: purging the note deletes `body-extras/<UUID>.json` in the flush that saves the library, not before; a note whose extras become `.empty` and whose code paragraphs have no ID has no sidecar after its next save, and a successful save leaves a sidecar with no `previous`.
  - `PurgeAuxFilesTests` (Task 3.5) gains the sidecar: in `testFailedLibrarySaveKeepsAuxFiles` the purged note also has a sidecar with a `frontMatter`, which is still in place after the failed save, and the relaunched store reads the note with that `frontMatter`; in `testAuxFilesRemovedAfterDurableDelete` the sidecar still exists before `flush` and is gone after it.
  - `testSidecarWriteFailureLeavesBodyUntouched`: on an RTFD store, with `body-extras/` replaced by a plain file so the sidecar temp can't be created, an editor save of a note with extras throws; the `.rtfd` package is byte-identical to before, the note is still dirty, and the editor still holds the unsaved text.
  - `testUnreadableSidecarBlocksWrites`: a note's sidecar is overwritten with invalid JSON; a new `NoteStore` on the same root reads `readOnlyReason == StoredBody.bodyExtrasUnreadable` and `isBodyWriteBlocked` is true; `updateBody` with changed text followed by `flush()` writes nothing, and the sidecar and the `.rtfd` are byte-identical afterwards. (`editBody`'s refusal is tested in Task 4.5.)
  - `testCrashAfterSidecarStageKeepsOldExtras`: a note with extras A and a `zig-nightly` code paragraph is saved; a save of new text with one more code paragraph and extras B stops with `bodyWriteInterruption = .afterSidecarStage`. The sidecar holds `current` B and `previous` A; a new `NoteStore` reads the old body with extras A and the `zig-nightly` ID.
  - `testCrashAfterBodyInstallKeepsNewExtras`: the same save stops with `.afterBodyInstall`; a new `NoteStore` reads the new body with extras B and its IDs, and the next save leaves a sidecar with no `previous`.
  - `testEmptyExtrasNeverDeleteBeforeInstall`: a note with extras A is saved with `.empty` extras and no IDs. Stopped `.afterSidecarStage`, the sidecar still exists and a new `NoteStore` reads the old body with A; stopped `.afterBodyInstall`, it reads the new body with `.empty`; uninterrupted, no sidecar is left.
  - `testCrashWithoutPriorSidecarKeepsEmptyExtras`: a saved note with no sidecar is saved with extras B and stopped `.afterSidecarStage`; the sidecar's `previous` is an empty entry with the old package's digest, and a new `NoteStore` reads the old body with `.empty` extras.
  - `testUnmatchedSidecarUsesCurrent`: the `.rtfd` is rewritten outside `NoteStore`; the next read uses `current`, logs the mismatch, and drops the IDs when the counts differ.
  - `testSidecarFinishFailureKeepsWrite`: with step 3 made to fail, the save succeeds, the note is clean, and a new `NoteStore` reads the new body with the new extras.
  - `testFailedSyncApplyKeepsExtras`: on a plain RTFD store, a note with extras A gets a sync apply carrying extras B whose body install fails (`bodyWriteInterruption = .afterSidecarStage`); the apply is skipped, `bodyExtras[id]` is still A, and a new `NoteStore` reads A. Without the failure, `bodyExtras[id]` is B after the apply.
- [ ] `PersistNowTests`:
  - `testPersistNowWritesBodyAndLibrary`: on an RTFD store, a note made with `createNote(in:initial:)` and `persistNow` at once is, without any `flush`, listed by a new `NoteStore` on the same root with its title and text. A note whose extras came from a sync apply, then changed with `updateBody` and `persistNow`, reads back with the new text and the same extras, and its sidecar has no `previous`.
  - `testPersistNowCommitsStagedSnapshot`: a snapshot passed to `stageEditorCommit` and not yet committed is the text a new `NoteStore` reads after `persistNow`.
  - `testPersistNowBodyFailureThrows`: with `notes/` replaced by a plain file, `persistNow` throws `bodyNotSaved`, the note stays dirty, and `library.json` is unchanged.
  - `testPersistNowLibraryFailureThrows`: with `library.json` replaced by a directory, `persistNow` throws `libraryNotSaved` after the body is on disk.
  - `persistNow` of an unknown ID throws `noteMissing`; of a write-blocked dirty note throws `writeBlocked` and writes nothing; of a clean note writes nothing (the package and `library.json` modification dates are unchanged); and it leaves another dirty note unwritten.
- [ ] Behaviour checks: `contentRevisions` for an unchanged library gives identical values before and after the refactor (test with a fixture library written by the pre-refactor code: a note with an image attachment and one without).

**Verify:**
- `swift test --filter "RTFDBodyStorageTests|BodyExtrasTests|PersistNowTests|PurgeAuxFilesTests|NoteStoreTests|RecentlyDeletedTests|VersionHistoryTests|SyncAdapterTests" 2>&1 | tail -5` → `with 0 failures`. Use the test classes that exist; `swift test list | grep -i store` shows them.
- `NOTEIT_DATA_DIR=.selftest/s41 NOTEIT_SYNC_SELFTEST=1 swift run NoteIt 2>&1 | tail -1` → `PASS all checks`.
- `NOTEIT_DATA_DIR=.selftest/s41b NOTEIT_STORE_SELFTEST=1 swift run NoteIt` (forced body write failures) logs no inconsistency.
- On a fresh `.selftest/s41c`, run `NOTEIT_STORE_SELFTEST=newnote`, then `NOTEIT_STORE_SELFTEST=quit`. The second log lists the note from the first and one recovery copy, as before the refactor.
- Full gate.

**Commit:** `refactor(store): route body I/O through NoteBodyStorage and add persistNow`

#### Task 4.2: `BodyCodec` [P after 4.1 and 2.3]

**Files:**
- Create: `Sources/NoteIt/Model/BodyCodec.swift`, `Tests/NoteItTests/BodyCodecTests.swift`
- Modify: `NoteStore.plainText(for:)`, `NoteExporter.plainText(_:)` and the HTML export entry point in `Export/NoteExporter.swift`. They call `BodyCodec`, and the old functions stay as forwards.

- [ ] Add the frozen enum, with exactly the cases `rtfd` and `noteItDoc`:
  - `plainText` and `html` wrap today's code (`NoteExporter.plainText`, `HTMLWriter`) without changing output.
  - `noteItDoc(of:extras:imagePolicy:)`/`attributedString(from:)` call `DocConverter` with `AppDocStyleProvider`. `noteItDoc` sets the container's `extras` to the ones passed in; `attributedString(from:)` returns a `StoredBody` whose `extras` are the container's.
  - `read(at:)`, `write(_:extras:to:)`, `data(of:extras:)` and `fileExtension` each `switch self` with no `default:` branch, so adding a case fails to compile until every branch is written. `.rtfd` uses today's RTFD `FileWrapper` code, always reads `extras` as `.empty` and ignores the `extras` passed to a write. `.noteItDoc` uses `BodyContainer.encoded()`/`decode` and keeps `extras` in the container; a `.noteitdoc` file is self-contained: attachments are inside the container, and no sibling files are written or read.
  - `semanticallyEqual` compares the `encoded()` bytes of both exports.
- [ ] Sync's body encoding builds its container with `noteItDoc(of: text, extras: bodyExtras[id] ?? .empty)` before sealing, and applies an incoming container with `attributedString(from:)`, writing with the returned `extras` and storing them in `bodyExtras[id]` only after the body is installed (Task 4.1). In wave 0 sync still sends RTFD bodies, so this is the rule web-app Task 0.4 follows when it adds the `noteit-doc` body encoding.
- [ ] There is no `markdown` case and no codec registry here. markdown-storage adds `case markdown` to this enum in wave 1, with a branch in each switch that calls `NoteItMarkdown`.
- [ ] Tests:
  - `plainText` and `html` give byte-identical output to the pre-change functions for the `MarkdownReaderTests` fixtures;
  - for every case in `BodyCodec.allCases`, `write(_:extras:to:)` then `read(at:)` of a note with every `BlockKind`, a code block in two languages and an image gives a `StoredBody` whose `text` is `semanticallyEqual` (markdown-storage's case is covered by the same loop once it lands);
  - `.noteItDoc.write` of that note into an empty folder leaves exactly one file there, and reading it back after moving it to another folder gives the image;
  - `testExtrasSurviveEdit`: a `.noteitdoc` file with a `frontMatter` and an unknown top-level key holding `9007199254740993` → `read(at:)` → change the text → `write(_:extras:to:)` with the read `extras` → the file still has both, with the same tokens; the same holds when the edit empties the document; `data(of:extras:)` equals the written bytes; `noteItDoc(of:extras:)` then `attributedString(from:)` gives the same `extras`;
  - `testRTFDIgnoresExtras`: `.rtfd` written with non-empty `extras` gives the same bytes as with `.empty` and reads `.empty`;
  - `semanticallyEqual` gives false when one character changes.

**Verify:**
- `swift test --filter "BodyCodecTests|NoteExporterTests|HTMLWriterTests|DocConverterRoundTripTests" 2>&1 | tail -5` → `with 0 failures` (classes that exist).
- Full gate.

**Commit:** `feat(store): BodyCodec`

#### Task 4.3: `NoteLock`, `NoteMeta.lock`, `isLocked` [P after 4.1]

**Files:**
- Create: `Sources/NoteItCore/Models/NoteLock.swift`, `Tests/NoteItCoreTests/NoteLockTests.swift`
- Modify: `Sources/NoteItCore/Models/NoteMeta.swift`, `Sources/NoteItCore/Models/CodingKeyNames.swift` (`lock` is owned), `Sources/NoteIt/Model/NoteStore.swift` (`revisionFields`, or the function that builds `RevisionInput.fields`)

- [ ] `NoteLock` is defined as frozen. `NoteMeta.lock: NoteLock?` defaults to nil, and `isLocked` is `lock != nil`.
  - The encoding omits `lock` when it is nil, so existing `library.json` and sealed metas are byte-identical.
  - The revision fields add `lock` only when it is non-nil.
- [ ] Nothing sets `lock` in wave 0. sync-security adds the behaviour.
- [ ] Tests:
  - a meta without `lock` encodes identically to the pre-change fixture;
  - a meta with `lock` round-trips;
  - `contentRevisions` unchanged for unlocked notes;
  - `ownedCodingKeys` contains `lock`.

**Verify:**
- `swift test --filter "NoteLockTests|ModelCodingTests|RawMetaOverlayTests" 2>&1 | tail -5` → `with 0 failures`.
- iOS `xcodebuild` for `NoteItCore`.
- Full gate.

**Commit:** `feat(core): note lock fields`

#### Task 4.4: `DerivedIndex` registry [P after 4.3]

**Files:**
- Create: `Sources/NoteIt/Model/DerivedIndex.swift`, `Tests/NoteItTests/DerivedIndexRegistryTests.swift`
- Modify: `Sources/NoteIt/Model/NoteStore.swift`, `Sources/NoteIt/Model/NoteStore+Trash.swift`

- [ ] `NoteStore` keeps `derivedIndexes` in registration order. `registerDerivedIndex` traps (`preconditionFailure`) on a duplicate `indexID`. The hooks are program §7's, and every call goes through one private dispatcher:
  - after `createNote`, after `updateBody` stores a body, and after `applyPreparedRemoteNote`: `noteChanged(_:body:)` with the current meta (body changes and creation only);
  - in `togglePin`, `moveNote(_:to:)`, `moveToRecentlyDeleted` and `recover` (and their undo paths): `metadataChanged(_:)` only, once per note, never `noteChanged`. Tags are read from the body today, so a tag change is a body change; a later path that changes tags without a body edit sends `metadataChanged` only;
  - in the private `removeNotes` loop (Delete Now, Empty Recently Deleted, the automatic purge, remote removal): `noteRemoved(_:)`;
  - when `scheduleIndexRebuild` runs: `rebuild(notes:body:)`, with `body` reading through `bodyStorage` off the main actor as the search rebuild does, and returning nil for locked notes;
  - in `flush()`: `flush()`.
- [ ] Locked notes (`isLocked`) never reach `noteChanged`; the dispatcher sends `noteRemoved` instead. `refreshDerivedIndexes(for:)` re-sends one note the same way: `noteRemoved` when it is locked, `noteChanged` when it is not. sync-security calls it after Lock Note (so locking calls `noteRemoved` on every index) and after Remove Lock. A remote apply that turns a note locked takes the same path. `metadataChanged` carries no body and is sent for locked notes too.
- [ ] There is no unregister. An index is registered once each time a store opens. A feature that can be turned off keeps its index registered and dormant: its hooks do nothing while the feature is off, and it schedules its own rebuild when it is turned back on (program §7).
- [ ] The existing `searchIndex` code is untouched. organise moves search onto this registry.
- [ ] No production index is registered in wave 0.
- [ ] Tests use a recording fake index:
  - creating a note, a local edit and a remote apply each give `noteChanged`;
  - pin, move, move to Recently Deleted and recover each give one `metadataChanged` and no `noteChanged`;
  - Delete Now, purge and remote removal give `noteRemoved`;
  - `flush` and a rebuild give `flush` and `rebuild`;
  - a locked note gives `noteRemoved` only, and `refreshDerivedIndexes(for:)` gives `noteRemoved` when locked and `noteChanged` once the lock is cleared;
  - registering the same `indexID` twice traps (tested through `canRegisterDerivedIndex(_:)`, since XCTest cannot catch a trap);
  - with no registered index, the `NoteStore` tests are unchanged.

**Verify:**
- `swift test --filter "DerivedIndexRegistryTests|NoteStoreTests" 2>&1 | tail -5` → `with 0 failures`.
- Full gate.

**Commit:** `feat(store): derived index registry`

#### Task 4.5: `editBody`, `OpenEditorRegistry` and `localNoteChange` [P after 4.3]

**Files:**
- Create: `Sources/NoteIt/Model/NoteStore+BodyEdits.swift`, `Sources/NoteIt/Editor/OpenEditorRegistry.swift`, `Tests/NoteItTests/{BodyEditTests,OpenEditorObserverTests,LocalNoteChangeTests}.swift`
- Modify: `Sources/NoteIt/Editor/RichTextEditor.swift` (`makeNSView`, `updateNSView` where `coordinator.noteID` changes, `dismantleNSView`), `Sources/NoteIt/Editor/NoteItTextView.swift` (`becomeFirstResponder` calls `markActive`), `Sources/NoteIt/Model/NoteStore.swift` (`createNote` and `updateBody` post `localNoteChange`; `createNote` gains `postsLocalChange: Bool = true`), `Sources/NoteIt/Model/NoteStore+Sync.swift` (`importConflictCopy` passes `postsLocalChange: false`), `Sources/NoteIt/Model/NoteStore+Trash.swift` (`moveToRecentlyDeleted` posts it), `Sources/NoteIt/Model/VersionHistory.swift` (`record` and `recordSavedBody` keep extras, `load` returns them, `restoreVersion` calls `editBody`); in `NoteStore.swift`, `flush` and `applyPreparedRemoteNote` pass the saved body's sidecar entry to `recordSavedBody`, and `removeHistory` of a purged note moves from `removeNotes` to `trashPendingBodies`; `Tests/NoteItTests/PurgeAuxFilesTests.swift` (Task 3.5)

- [ ] `OpenEditorRegistry.shared` keeps every registered `NoteItTextView` per note ID, each held weakly.
  - `RichTextEditor` registers its view in `makeNSView` and re-registers when the coordinator's `noteID` changes.
  - It unregisters in `dismantleNSView`.
  - `NoteItTextView.becomeFirstResponder` calls `markActive`. `textView(for:)` returns the most recently active view for the note, else the most recently registered one; `textViews(for:)` returns them all, most recent first. Several windows on the same note each stay registered.
- [ ] Observers for read-only surfaces (program §6), through `registerObserver(_:for:)` and `removeObserver(_:)`:
  - Observers are kept per note ID, apart from editors, so `textView(for:)` never returns one and `editBody` never edits one.
  - While an editor is registered for a note that has observers, the registry watches that editor's text storage (`didProcessEditing`) and passes each observer a copy. It stops when the editor unregisters.
  - After `editBody`'s closed path saves, and whenever `NoteStore` sets `externallyUpdatedNoteID` for the note, the registry passes the saved body to each observer.
  - `removeObserver` drops the handler. An observer whose note has no editor costs nothing.
  - Nothing registers an observer in wave 0; surfaces-polish's cheat sheet is the first.
- [ ] `editBody(_:actionName:versioning:extras:_:)` checks the note, in order:
  - missing → `noteMissing`;
  - `deletedAt != nil` → `inTrash`;
  - `isLocked` → `locked`;
  - `isBodyWriteBlocked` → `writeBlocked`.
- [ ] Versions: with `versioning: .recordCurrent` (the default), `editBody` records the note's current body in Version History exactly once per changing call, on both paths. With `.none` it records nothing. An unchanged edit records nothing either way. Callers never call `history.record` themselves before `editBody`.
- [ ] Versions keep extras (program §6). `VersionHistory` changes:
  - `record(_ text: NSAttributedString, extras: ContainerExtras, of id: UUID) -> NoteVersion?` also stores `extras` and the text's code-language IDs beside the version as `<version>.extras.json` (for example `history/<UUID>/20261019T110000Z.extras.json`), as one `BodyExtrasEntry` (not the two-entry sidecar file) with `bodySHA256` = `packageDigest` of the version package. The file is always written, also when the entry `isEmpty`; only a version from before extras support has none.
  - `recordSavedBody(at bodyURL: URL, extras: BodyExtrasEntry, of id: UUID, force: Bool = false) -> NoteVersion?` writes the extras file the same way, with the extras of the saved body it copies. `NoteStore` passes the entry for the body on disk before the write that replaces it, the same entry sidecar step 1 stores as `previous` (so it is called before step 1, in `flush`'s per-note step, which `persistNow` shares, and in `applyPreparedRemoteNote`); when there is no matching entry, it passes `.empty` extras, no IDs and the saved package's digest. If the extras file can't be written, it keeps no version and logs, as for any failed copy today.
  - `install` takes the `BodyExtrasEntry` too, so every path that installs a version writes the extras file. It picks the stamp as today (a stamp is taken when either `<stamp>.rtfd` or `<stamp>.extras.json` exists), writes the extras file atomically (temp, then rename), and only then moves the version package into place. If the extras file can't be written, the temp package is removed and `record` returns nil, so `editBody` throws `versionNotSaved`. If the package move fails, the extras file is removed too.
  - `load(_:)` returns `(text: NSAttributedString, extras: ContainerExtras?)`. `extras` is nil when the version has no extras file. When it has one, the stored IDs are set as `noteItCodeLanguageID` on the text's code paragraphs by position when the counts match. An extras file that exists but can't be read or decoded makes `load` throw.
  - `prune` and `removeHistory` delete a version's extras file together with it, and `prune` deletes any `.extras.json` with no matching `.rtfd` (left by a crash between the two writes). `versions(of:)` still lists only `.rtfd` packages.
  - A purged note's `removeHistory` moves out of the private `removeNotes` loop into `trashPendingBodies` (Task 3.5's rule), so its versions and their extras files are deleted with the body's `.trash` move, only after the saved `library.json` no longer lists the note. A failed library save keeps them.
  - Every `history.record` call in `editBody` passes the note's current extras: `bodyExtras[id] ?? .empty`.
- [ ] `extras:` (program §6) is used only by `NoteStore`'s own code; Restore Version is the only caller that passes it. nil keeps `bodyExtras[id]`. A value replaces `bodyExtras[id]` in the same body write, so on an RTFD store the sidecar's `current` holds them. A call is unchanged only when the text is unchanged and `extras` is nil or equal to `bodyExtras[id]`. `updateBody` gains the same internal `extras: ContainerExtras? = nil`: a value sets `bodyExtras[id]` before the write, and a change of extras alone counts as a stored change (it writes the body and posts `edited`). On the open path, Undo of a call that changed the extras restores the earlier text and the earlier extras together, and Redo reapplies both (next item).
- [ ] A failed version aborts the edit: with `.recordCurrent`, when `history.record` returns nil, `editBody` throws `BodyEditError.versionNotSaved` before any mutation, on both paths. No text storage, undo stack, body file or `externallyUpdatedNoteID` changes. `versionNotSaved` has a plain message: "The current version couldn't be saved, so the note wasn't changed."
- [ ] Open path, when `textView(for:)` returns a view (the originating, most recent one):
  - `handOverPendingEdits(id)` first. This rule is frozen: every open editor for the note commits its pending edits through its normal save path, in registration order, with the active editor (the one `textView(for:)` returns, last set by `markActive`) committed last whatever its registration position. When two editors hold different unsaved text, the active editor's text is therefore the one stored, the same last-writer result as today. Afterwards no editor holds unsaved text, and the edit below starts from the active editor's text.
  - Run `edit` on a mutable copy of that view's `textStorage`. If the call is unchanged, return.
  - With `.recordCurrent`, `history.record(current text storage, extras: bodyExtras[id] ?? .empty, of: id)` once; a nil result throws `versionNotSaved` here, before the storage is touched.
  - When the call changes the extras (non-nil and not equal to `bodyExtras[id]`), open the undo group named `actionName` on the view's `undoManager` and, before any storage change, register an extras action on the store: it sets `bodyExtras[id]` back to the extras before the call, commits the editor's text through its normal save path and calls `flush()` at once (so the text the undo has just restored and those extras go out in one body write), sets `externallyUpdatedNoteID = id`, and registers its own inverse, so Redo puts the call's extras back with the call's text in one write the same way. NSUndoManager runs a group's actions in reverse order, so this action runs after the text has been reverted.
  - When only `extras` differs (the text is unchanged), skip the storage replacement: in that same undo group, `updateBody(id, text, extras: extras)`, `flush()`, `externallyUpdatedNoteID = id`, and stop. Undo restores the earlier extras with the same text in one write.
  - Replace the whole storage inside `shouldChangeText(in:replacementString:)`/`didChangeText()` with an undo group named `actionName`. Selection is clamped to the new length.
  - With a non-nil `extras`, set `bodyExtras[id] = extras` just before the save, so it writes them. Save it now through the editor's normal save path (its coordinator's commit), then set `externallyUpdatedNoteID = id`. The originating view already shows the saved body and does nothing. Every other open editor for the note reloads it the way it reloads a sync change (`remoteUpdateArrived`, keeping selection and scroll): the edit is not registered in their undo stacks, and they clear their undo history as they do today for an external change.
- [ ] Closed path: the steps today's `VersionHistory.restoreVersion` takes.
  - `handOverPendingEdits(id)`, then `let current = body(for: id)`.
  - Apply `edit` to a mutable copy. If the call is unchanged, return.
  - With `.recordCurrent`, `history.record(current, extras: bodyExtras[id] ?? .empty, of: id)` once; a nil result throws `versionNotSaved` and nothing is written. Then `updateBody(id, edited, extras: extras)`, `flush()`, and `externallyUpdatedNoteID = id`.
- [ ] `restoreVersion` goes through `editBody` (program §6 has no exception). It loads the version's text and extras with `history.load`, then makes one call: `editBody(id, actionName: "Restore Version", versioning: .recordCurrent, extras: loaded.extras) { $0.setAttributedString(loaded.text) }`. Only a version from before extras support has no extras file; its `extras` is nil, so it restores with the note's current extras. It keeps today's quiet no-ops: `noteMissing`, `inTrash`, `locked` and `writeBlocked` are caught and return without a change, and restoring a version whose text and extras equal the current ones records nothing. A version whose extras file can't be read throws from `load`, and the sheet shows it like any other restore error. `versionNotSaved` is not a quiet no-op: `restoreVersion` lets it propagate, and `VersionHistorySheet` shows it through its existing error path (`errorMessage`), with the body unchanged. It no longer calls `history.record` itself. In an open note the restore becomes one Undo step ("Undo Restore Version"); this is an allowed user-visible change.
- [ ] Errors thrown by `edit` propagate, and nothing is written.
- [ ] `localNoteChange` (program §7, the one extra hook allowed in `NoteStore`), with `userInfo["noteID"]` and `userInfo["kind"]`:
  - `created`: `createNote` posts it once per new note. Every local path that adds a note goes through it.
  - `createNote(in:initial:postsLocalChange:)` takes `postsLocalChange: Bool = true`, so existing local callers don't change. Sync's conflict path, `importConflictCopy` in `NoteStore+Sync.swift`, also creates its note through `createNote`; it passes `false`, so a conflict copy that arrives through sync posts nothing. No other caller passes `false`.
  - `edited`: `updateBody` posts it after it stores a changed body. `updateBody` is only reached by local edits (the editor's save path, `editBody` and Restore Version), so local edits post it once per stored change.
  - `deleted`: `moveToRecentlyDeleted` posts it once per note, including for a batch.
  - `applyPreparedRemoteNote`, `importConflictCopy`, remote removal and every other sync apply path never post it.
  - Nothing observes it in wave 0; plugins are the first observer and build `noteCreated`, `noteEdited` and `noteDeleted` on it.
- [ ] Restore Version is the only app caller of `editBody` in wave 0. organise and linking are the first other callers.
- [ ] Tests:
  - the closed path changes the body, adds one version, and sets `externallyUpdatedNoteID`;
  - the open path with `.recordCurrent` adds exactly one version; `versioning: .none` adds none on either path;
  - an unchanged edit writes nothing and adds no version;
  - `restoreVersion` on a closed note and on an open note each add exactly one version (the body before the restore) and give the restored text; on a note in Recently Deleted it changes nothing and throws nothing;
  - each `BodyEditError`;
  - `testRestoreVersionRestoresExtras`: on an RTFD store, a note with a `frontMatter`, an unknown top-level key and a `zig-nightly` code paragraph is edited through `editBody` (which records a version with an extras file), then its extras are replaced and the code paragraph removed; restoring that version gives the old text, the old extras in `bodyExtras[id]` and in the sidecar, and the `zig-nightly` ID, in one write and one new version (whose extras file holds the replaced extras); with an injected failure writing the version's extras file, `editBody` throws `versionNotSaved` and leaves no version package;
  - `testSavedBodyVersionKeepsExtras`: on an RTFD store, a note with a `frontMatter` and a `zig-nightly` code paragraph is saved, then edited and saved again after `VersionHistory.minimumInterval` (injected `now`); the version `recordSavedBody` kept has a `.extras.json` holding the first save's extras and ID, and restoring it gives them back. A note with no extras gets a version extras file with `.empty` extras, and a sync apply that replaces a body keeps the replaced body's extras in its version the same way;
  - `PurgeAuxFilesTests` gains Version History: in `testFailedLibrarySaveKeepsAuxFiles` the purged note's `history/<UUID>/` folder, with a version and its `.extras.json`, is still in place after the failed save; in `testAuxFilesRemovedAfterDurableDelete` it still exists before `flush` and is gone after it;
  - `testRestoreLegacyVersionKeepsCurrentExtras`: a version package with no extras file (as an older build leaves it) restored into a note with a `frontMatter` gives the version's text and keeps that `frontMatter` in `bodyExtras[id]` and in the sidecar;
  - `testFailedVersionAbortsEdit`: with a history whose `record` returns nil (NoteStore gains an internal test-only seam `var recordVersionOverride: ((NSAttributedString, UUID) -> NoteVersion?)?`, nil by default; when set, the store calls it instead of `history.record`), `editBody` with `.recordCurrent` throws `versionNotSaved` on the closed path and on the open path, and the body, the text storage, the undo stack and `externallyUpdatedNoteID` are unchanged; `restoreVersion` with the same history throws `versionNotSaved` and leaves the body unchanged;
  - a throwing `edit` leaves the body unchanged;
  - the open path with a real `NoteItTextView` in an offscreen window: one undo step named `actionName`, and undo restores the text;
  - `testUndoRestoreVersionRestoresExtras`: on an RTFD store, a note open in an offscreen `NoteItTextView` with extras A and a `zig-nightly` code paragraph has a version restored whose text differs and whose extras are B. One undo ("Undo Restore Version") gives the earlier text, `bodyExtras[id] == A`, and a sidecar whose only entry is A and matches the saved body, from one body write, with the note clean; redo gives the version's text with B the same way. A restore that changes only the extras undoes and redoes the same way, and an edit with nil `extras` registers no extras action;
  - `testEditBodyRefusesUnreadableSidecar`: a note whose sidecar can't be decoded (as in Task 4.1's `testUnreadableSidecarBlocksWrites`) makes `editBody` throw `writeBlocked`, and the sidecar and the `.rtfd` are byte-identical afterwards;
  - `testPendingEditsHandOverActiveLast`: two editors on the same note in two offscreen windows, each holding different unsaved text, with the first-registered one made active through `markActive`; after `editBody` appends a line, the store and the active editor hold the active editor's unsaved text plus that line, the other editor has reloaded to the same text, and its own unsaved text is not in the result;
  - two editors on the same note in two offscreen windows, the second one active: `editBody` edits the second with one undo step, the first shows the saved body afterwards with no undo entry for the edit, and the store holds the edited body once;
  - `LocalNoteChangeTests`: `edited` is posted once for a closed-path `editBody` and for `updateBody`, not for an unchanged edit, and not for `applyPreparedRemoteNote`; `created` once for `createNote`, not for a remote apply that adds a note, and not for `importConflictCopy` (which still creates the conflict copy); `deleted` once per note for `moveToRecentlyDeleted` and not for remote removal;
  - `OpenEditorObserverTests`: an observer is never returned by `textView(for:)`; typing in a registered editor reaches the observer before saving; a closed-path `editBody` passes the saved body to the observer; a removed observer is not called.

**Verify:**
- `swift test --filter "BodyEditTests|OpenEditorObserverTests|LocalNoteChangeTests|VersionHistoryTests|PurgeAuxFilesTests|EditorColumnLayoutTests" 2>&1 | tail -5` → `with 0 failures`.
- Full gate.

**Commit:** `feat(store): editBody, open editor registry and local note change notification`

#### Task 4.6: Daily note helpers [P after 4.5]

**Files:**
- Create: `Sources/NoteItCore/Daily/{DailyNoteTitle,DailyLogLine,DailyNotes}.swift`, `Sources/NoteIt/Model/NoteStore+Daily.swift`, `Sources/NoteIt/Model/DailyLogAppender.swift`, `Tests/NoteItCoreTests/{DailyNoteTitleTests,DailyLogLineTests}.swift`, `Tests/NoteItTests/DailyNoteStoreTests.swift`
- Modify: `Sources/NoteIt/Settings/Preferences.swift` (`PrefKey.dailyNotesNotebookID`, `PrefKey.dailyNoteTitleFormat`)

- [ ] NoteItCore:
  - `DayKey`.
  - `DailyNoteTitle.title`/`parse` for the three formats, with month and weekday names from a `DateFormatter` in the given locale.
  - `DailyLogLine.format` and `prefix`, which use `en_US_POSIX` `HH:mm` (left out when `timestamp` is false); `format` cleans the text as the frozen comment states.
  - All of these are Foundation only.
- [ ] `dailyNotesNotebookID(createIfMissing:)`:
  - It uses the stored ID when `notebook(with:)` returns a notebook (deleted notebooks are removed from the library, so existence is the live state).
  - Otherwise, with `createIfMissing`, it creates "Daily Notes" with symbol `calendar` and the first palette color, then stores its ID.
- [ ] `dailyNote(for:createIfMissing:)` looks for a live note in that notebook whose title parses (`DailyNoteTitle.parse`, which tries every supported format) to the same `DayKey`. It prefers the oldest `createdAt`. Because lookup recognises every format, switching `dailyNoteTitleFormat` never creates a second daily note for a day that already has one.
  - Otherwise, with `createIfMissing`, it calls `createNote(in:initial:)` with the title in the user's chosen format (`PrefKey.dailyNoteTitleFormat`, default `iso`) as the first line. Existing titles are never rewritten when the format changes.
- [ ] `DailyLogAppender.append(_:timestamp:to:in:now:)` takes `DailyLogContent`:
  - `.plain(text)`: the entry is `DailyLogLine.format(text:at:timeZone:timestamp:)` in the body style.
  - `.attributed(text)`: the entry is `DailyLogLine.prefix(at:timeZone:timestamp:)` in the body style followed by `text` with its own formatting, trimmed of leading and trailing whitespace and newlines.
  - It never parses Markdown. A caller that accepts Markdown parses it first with the existing Markdown importer (`MarkdownReader.attributedString(from:)` until markdown-storage ships `NoteItMarkdown`) and passes `.attributed`.
  - It calls `dailyNote(for: date, createIfMissing: true)`, then `editBody(id, actionName: "Log to Daily Note")` with the default versioning. The edit appends a newline (when the body does not already end in one) plus the entry.
  - Empty content (a nil line, or attributed text that is empty after trimming) throws `DailyLogError.emptyText`, a one-case error declared next to the appender, before any note is created.
- [ ] `DailyNotes.isAvailable` is the program §5 gate, a `public static let` set to `false` in `NoteItCore` so the app, `NoteItAPI` handlers and the phone read the same value. Linking changes it to `true` in the task that ships its daily-note UI. While it is false, every caller listed in program §5 (Append to Today, the daily Local API routes with `501 not_implemented`, the daily CLI commands, the `daily` and `append?daily=` URL hosts) checks it and stays unavailable. In wave 0 none of those callers exist yet; each owner adds its check in the task that adds the caller. The helpers above work regardless of the gate, so linking can test them before flipping it.
- [ ] No menu, shortcut, sidebar row or settings UI. Linking adds those.
- [ ] Tests:
  - titles in the three formats for `en_US` and `sv_SE`;
  - parse round trip for every format, and a title in each format parses whatever format is currently chosen;
  - log line cleaning, length cap and the midnight `00:05` case;
  - the notebook is created once and reused;
  - a second call for the same day returns the same note;
  - `testFormatSwitchFindsExistingNote`: with `dailyNoteTitleFormat` set to `long`, create the day's note; switch to `weekdayLong`; `dailyNote(for:createIfMissing: true)` returns the same note, its title is unchanged and the notebook still has one note;
  - a note renamed away from the date is no longer found;
  - two appends give two lines in order;
  - `timestamp: false` gives `- text` with no time;
  - `.attributed` content keeps its bold run after the `- HH:mm ` prefix, and whitespace-only attributed content throws `emptyText`;
  - a deleted daily note is not reused;
  - `DailyNotes.isAvailable` is false (in `DailyNoteTitleTests`; linking updates the expectation when it flips the gate).

**Verify:**
- `swift test --filter "DailyNoteTitleTests|DailyLogLineTests|DailyNoteStoreTests" 2>&1 | tail -5` → `with 0 failures`.
- iOS `xcodebuild` for `NoteItCore`.
- Full gate.

**Commit:** `feat(core): daily note helpers`

### Step 5: `NoteItAPI`, registries and the embeds table

Moved from automation T1, T17 and the parser half of T5. 5.3 runs first and needs only step 1: it creates `NoteItCore.AppendPosition`, which 5.1's wire types alias, so 5.1 starts after 5.3 is merged. 5.1 → 5.2 run in order; 5.4 needs 5.3; 5.5 is independent of everything. Automation keeps all behaviour: the server, the router, auth, handlers, the CLI commands and the Share extension.

#### Task 5.1: `NoteItAPI` target, wire types, `NoteItCLI` stub [S after 5.3]

**Files:**
- Modify: `Package.swift`:
  - library product `NoteItAPI`;
  - targets `NoteItAPI` (depends on `NoteItCore`, `NoteItSync`), `NoteItCLI` (executable, depends on `NoteItAPI` and `NoteItSync`) and `NoteItAPITests`;
  - `NoteIt` depends on `NoteItAPI`.

  There is no executable product named `noteit`, so it cannot clash with `NoteIt` on a case-insensitive disk. The CLI is built as the `NoteItCLI` target only.
- Create: `Sources/NoteItAPI/Wire/*.swift` (one file per group in automation's Frozen interfaces: scopes and client kinds, DTOs, requests, errors, `APIJSON`, discovery and tokens, routes), `Sources/NoteItAPI/Server/HTTPMessage.swift`, `Sources/NoteItAPI/CLIVersion.swift`, `Sources/NoteItCLI/main.swift`, `Tests/NoteItAPITests/{WireTypeTests,CLIVersionTests}.swift`
- Modify: `Sources/NoteItSync/Migration/AppIdentity.swift` (automation's three constants)

- [ ] Build automation's frozen wire types verbatim, with the program §10 changes already folded in there:
  - `PingDTO.capabilities`;
  - `NoteSummaryDTO.locked`;
  - the search `score`/`highlights`, with `HighlightDTO` as `{field, ranges: [[start, length]]}` in UTF-16 offsets;
  - the notebook `parentID`/`path` (`parentID` is the API name for organise's `Notebook.parent`);
  - `TagNodeDTO` with `totalCount`;
  - `DailyAppendRequest.format`;
  - `APIErrorCode` `badRequest`/`readOnly`/`revisionMismatch`/`editorRequired`/`noteLocked`/`notImplemented`/`notAvailable`/`notReady`, declared `String, Codable, Sendable, Error`;
  - no `ClientKind.plugin`.

  `AppendPosition` is not declared here. It comes from `NoteItCore` through `public typealias AppendPosition = NoteItCore.AppendPosition`. Task 5.3 creates `NoteItCore.AppendPosition`, which is why this task waits for 5.3; it adds nothing to `NoteItCore`.
- [ ] Add `urlScheme`, `localAPIKeychainService` and `cliKeychainService` to the existing `NoteItSync.AppIdentity`, after `keychainService`, written as automation's Frozen interfaces show (the two services derive from `bundleID`). `NoteItAPI` declares no `AppIdentity` of its own and copies no identity literal; its files and `NoteItCLI` `import NoteItSync` where they need it. `bundleID` stays the first `public static let bundleID = "…"` line in the file, because `scripts/build_app.sh` reads that line.
- [ ] `NoteItCLI/main.swift` implements the `--version` stub and `CLIExit` as frozen. It prints `noteit <CLIVersion.current()>`.
  - `AppIdentity` has no version member and gets none. The one version source stays `scripts/build_app.sh`, which writes `CFBundleShortVersionString` into the app's `Info.plist` from `NOTEIT_VERSION` (default `0.1.0`).
  - `CLIVersion` lives in `NoteItAPI` so it can be tested; it uses only Foundation. It resolves symlinks in the executable path (a user may link `noteit` into their `PATH`), and when the path is `<X>.app/Contents/Helpers/<name>` it reads `CFBundleShortVersionString` from `<X>.app/Contents/Info.plist`.
  - Anywhere else, or when the file or key is missing, it returns `dev`. In wave 0 the CLI is not yet bundled (automation adds the `Contents/Helpers/noteit` row to the embeds table), so `swift run` prints `noteit dev`.
- [ ] `CLIVersionTests`, each building a fake app in the test's own temporary directory:
  - an executable at `Fake.app/Contents/Helpers/noteit` with `CFBundleShortVersionString` `1.2.3` in `Fake.app/Contents/Info.plist` gives `1.2.3`;
  - a symlink outside the app pointing at that executable gives `1.2.3`;
  - an executable outside any app gives `dev`, and so does `executableURL: nil`;
  - an `Info.plist` without the key, or an executable directly in `Contents/MacOS/`, gives `dev`.
- [ ] Nothing in the app uses `NoteItAPI` yet. The `NoteIt` dependency is only there so automation does not need to change `Package.swift` for it.
- [ ] Add `Sources/NoteItAPI` to `ImportHygieneTests`. `Network` is allowed for `NoteItAPI` only, because automation's server needs it; the test has a per-target allow list.
- [ ] `WireTypeTests`:
  - every `APIErrorCode` has an `httpStatus` and a snake_case raw value, and each code in the program §10 table exists and has that table's status (`not_implemented` and `not_available` are both 501 and stay distinct);
  - `HighlightDTO` encodes `ranges` as an array of two-integer arrays, and `TagNodeDTO` encodes `totalCount`;
  - `PingDTO` encodes `capabilities` and never `plugins`;
  - `ClientKind.allCases` has no `plugin`;
  - every `APIRoutes.all` id matches `<slug>.<name>` and no two share method and path;
  - `APIJSON` round-trips a `NoteSummaryDTO` with ISO 8601 dates.

**Verify:**
- `swift test --filter "WireTypeTests|CLIVersionTests|ImportHygieneTests" 2>&1 | tail -5` → `with 0 failures`.
- `swift run NoteItCLI --version` prints `noteit dev`, and `swift run NoteItCLI; echo $?` prints `2`.
- iOS `xcodebuild` for `NoteItAPI` → no errors.
- `grep -rn "enum AppIdentity" Sources` → exactly one line, in `Sources/NoteItSync/Migration/AppIdentity.swift`.
- `sed -nE 's/^ *public static let bundleID = "([^"]+)".*/\1/p' Sources/NoteItSync/Migration/AppIdentity.swift | head -n 1` (the line `scripts/build_app.sh` runs) prints the same bundle ID as before the task.
- Full gate.

**Commit:** `feat(api): NoteItAPI target and wire types`

#### Task 5.2: `LocalAPIRouteRegistry` [S after 5.1]

**Files:**
- Create: `Sources/NoteItAPI/Server/{RouteMatch,OriginDecision,ClientRegistry,LocalAPIContext,LocalAPIRouteRegistry}.swift` (`ClientRegistry.swift` holds only `ClientRecord`; automation adds the store and verification to it), `Tests/NoteItAPITests/LocalAPIRouteRegistryTests.swift`

- [ ] Build the frozen types. `LocalAPIRouteRegistry` keeps routes, search modes and capabilities behind one `NSLock`.
  - `validate()` returns one message per trap condition.
  - `register`, `registerSearchMode` and `addCapability` call `validate`-style checks and `preconditionFailure` with that message.
- [ ] `capabilities` starts empty. Automation adds the core names when its server starts. `removeCapability(_:)` takes a name out again and does nothing when it isn't there. `capabilities` is always the current set, and `GET /v1/ping` (automation) lists exactly that, so a feature the user turns off stops being advertised.
- [ ] No route is registered and no server runs in wave 0.
- [ ] Tests, on fresh instances, through `validate()` and the read-only accessors:
  - a route that conflicts with an `APIRoutes.all` path;
  - a duplicate id;
  - an id without a slug;
  - a nil scope;
  - search mode `keyword`, a duplicate and `Not_Kebab`;
  - capabilities sorted and de-duplicated;
  - `removeCapability` removes a name, and removing it again, or removing a name never added, changes nothing;
  - `handler(for:)` and `searchMode(_:)` find what was registered.

**Verify:**
- `swift test --filter LocalAPIRouteRegistryTests 2>&1 | tail -5` → `with 0 failures`.
- Full gate.

**Commit:** `feat(api): local API route registry`

#### Task 5.3: `NoteLink`, `URLCommand`, `AppendPosition` in `NoteItCore` [P after step 1; before 5.1 and 5.4]

**Files:**
- Create: `Sources/NoteItCore/{NoteLink,URLCommand}.swift`, `Tests/NoteItCoreTests/{NoteLinkTests,URLCommandTests}.swift`
- Modify: `Sources/NoteItDoc/LinkPolicy.swift` (tighten the `noteit:` check). If Task 2.1 has not merged yet, skip this edit; 2.1 then writes the tight check directly.

- [ ] Build `NoteLink` exactly as linking freezes it:
  - `noteit://note/<UUID>` or `noteit://note?title=<encoded>`, with an optional `heading=` query item, as in the linking spec §1;
  - titles up to `maxTextLength`;
  - `url` is the canonical form with an uppercase UUID, and `NoteLink(url: link.url) == link`;
  - `LinkQuery`, which is in the same file, is built too.
- [ ] Build `URLCommand` exactly as automation freezes it (the T5 parsing rules), including `.note`/`.noteTitle` through `NoteLink(url:)`, `reservedHosts`, `settingsTabs` (10 values), `callbackURL` and `changesNotes`.
  - `changesNotes` replaces `changesExistingNote`. It is true for `new`, `append` and daily `append`, the links program §10 confirms. The share-inbox link (`shareInbox`) is exempt from confirmation, so it is false there.
  - `AppendPosition` is declared in `URLCommand.swift`, as frozen. It is the only declaration of the type; Task 5.1 aliases it.
- [ ] `LinkPolicy` allows a `noteit:` href when `NoteLink(url:) != nil || (try? URLCommand.parse(url)) != nil`. Nothing else with scheme `noteit` is allowed.
- [ ] Tests:
  - automation's T5 cases (each host, the `x-callback-url` form, booleans, tags, `tooLarge`, every settings tab, dropped callback schemes, `registered` with fragment);
  - `testChangesNotes`: `changesNotes` is true for `new`, `append` (by id, by title and `daily=today`) and false for `shareInbox`, `open`, `note`, `noteTitle`, `search`, `daily`, `settings` and `registered`. `changesExistingNote` does not exist;
  - linking's `NoteLink` and `LinkQuery` cases (ID, title, heading, percent-encoding, lowercase UUID input, a title over the limit rejected, a non-UUID path rejected, `title#heading|alias` split);
  - `DocValidationTests` gains `noteit://note/<UUID>` allowed and `noteit://evil` rejected.

**Verify:**
- `swift test --filter "NoteLinkTests|URLCommandTests|DocValidationTests|ImportHygieneTests" 2>&1 | tail -5` → `with 0 failures`.
- iOS `xcodebuild` for `NoteItCore`.
- Full gate.

**Commit:** `feat(core): NoteLink and URLCommand parser`

#### Task 5.4: `URLRouteRegistry` [S after 5.3]

**Files:**
- Create: `Sources/NoteIt/Automation/URLScheme/URLRouteRegistry.swift`, `Tests/NoteItTests/URLRouteRegistryTests.swift`

- [ ] Build the frozen class. `register` traps on:
  - a host in `URLCommand.reservedHosts`;
  - a duplicate;
  - a host with uppercase letters or characters outside `[a-z0-9-]`.

  A `canRegister(host:) -> Bool` helper mirrors the checks for tests.
- [ ] The app still handles no `noteit:` URLs. `Info.plist` gains no URL type in wave 0; automation adds `CFBundleURLTypes` and `URLSchemeHandler`, which looks up `.registered(host:url:)` here.
- [ ] Tests:
  - every reserved host is refused;
  - `Tasks` is refused;
  - a fresh registry accepts `tasks` and returns its handler;
  - a duplicate is refused;
  - `hosts` is sorted.

**Verify:**
- `swift test --filter URLRouteRegistryTests 2>&1 | tail -5` → `with 0 failures`.
- Full gate.

**Commit:** `feat(app): URL route registry`

#### Task 5.5: Embeds table and inside-out signing in `scripts/build_app.sh` [P, independent]

**Files:**
- Modify: `scripts/build_app.sh`

- [ ] Add an `EMBEDS` array after the Sparkle embedding. Each row is `"<path in bundle>|<source path relative to $BIN_DIR>|<build step script or empty>|<entitlements path or empty>"`, the program §10 columns in that order. The path in bundle is the full bundle-relative path and always starts with `Contents/` (for example `Contents/Helpers/noteit`); the script joins it to `$APP` as is and refuses a row whose path doesn't start with `Contents/`.
  - It is empty in wave 0, with a comment giving the planned rows (`Contents/Helpers/noteit`, `Contents/PlugIns/NoteItShare.appex`, `Contents/Helpers/NoteItPluginHost`, `Contents/PlugIns/NoteItClipper.appex`) and their owning plans.
  - A loop runs each row's build step when it has one. If the source still doesn't exist afterwards, it prints `Skipping <path in bundle>: <source> not built` (for example `Skipping Contents/PlugIns/NoteItClipper.appex: NoteItClipper.appex not built`) and goes on to the next row; this covers the clipper when it wasn't built and the Share extension in ad-hoc builds. Otherwise it copies the source to `$APP/<path in bundle>` (`ditto`) and sets the rpath for Mach-O helpers the same way as the app binary.
  - Skipped rows are left out of signing.
  - The main app is not a row. It is always signed last, with `$ENTITLEMENTS`.
- [ ] Signing becomes one function `sign_inside_out` used by both the distribution path and the ad-hoc path. It signs, in order:
  - the Sparkle XPC services, `Autoupdate`, `Updater.app` and the framework, as today;
  - each embedded `EMBEDS` row at `$APP/<path in bundle>` with its entitlements (`--entitlements` only when the field is non-empty), deepest path first (most path components);
  - the app last, with `$ENTITLEMENTS`.

  The ad-hoc path uses the same order with `-s -` and without `--options runtime`. The `codesign --force --deep -s - "$APP"` line and the comment after it are removed. `--deep` remains only in the `codesign --verify --deep --strict` checks.
- [ ] No other behaviour changes: the install location, atomic install, version and build number, universal flag and Sparkle keys stay the same.

**Verify:**
- `NOTEIT_INSTALL_DIR=$PWD/.selftest/app scripts/build_app.sh` → ends with the install line, exit 0.
- `codesign --verify --deep --strict .selftest/app/NoteIt.app && echo ok` → `ok`.
- `codesign -d --entitlements - .selftest/app/NoteIt.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app 2>&1 | grep -c apple-events` → `0`. Sparkle's helpers did not inherit the app's entitlements.
- `grep -c -- 'codesign --force --deep' scripts/build_app.sh` → `0`.
- With one uncommitted scratch row whose source doesn't exist (for example `Contents/PlugIns/Missing.appex|Missing.appex||`), `NOTEIT_INSTALL_DIR=$PWD/.selftest/app scripts/build_app.sh 2>&1 | grep -c 'Skipping Contents/PlugIns/Missing.appex'` → `1`, the script exits 0, and `codesign --verify --deep --strict` still prints `ok`. Remove the row afterwards.
- `.selftest/app/NoteIt.app` launches and shows the library.

**Commit:** `build: embeds table and inside-out signing`

### Step 6: Frozen tables

Covers program §9, the General tab item and the roadmap item of program §2 step 6. Tasks 6.1–6.5 are [P] after step 1 and touch different files. Task 6.6 is the last task of wave 0. Each table goes into code as a constant, and a test fails when a later change breaks the table. No menu item, hotkey tile, sidebar row or Settings tab is added, and the sidebar keeps its current order: `SidebarLibraryRow` (Task 1.1) is the §9 order as a constant, and each owner places its row by it when it adds one. The only visible change in this step is the General tab's layout (Task 6.5).

#### Task 6.1: Menu shortcut table and uniqueness test [P after step 1]

**Files:**
- Create: `Sources/NoteIt/App/PlannedMenuShortcuts.swift`, `Tests/NoteItTests/MenuShortcutDefaultsTests.swift`

- [ ] `PlannedMenuShortcuts.rows` has one row per §9 command that is not yet a `MenuShortcutCommand` case.
  - `command` is the camelCase case name the owner will add: `copyNoteLink`, `lockNote`, `removeLock`, `lockAllNotes`, `togglePin`, `openToday`, `dailyNoteForDate`, `newNoteFromTemplate`, `linkToNote`, `goBack`, `goForward`, `toggleInspector`, `showTasks`, `setDueDate`, `addReminder`, `newSmartFolder`, `saveSearchAsSmartFolder`, `askNotes`, `createShareLink`, `zoomIn`, `zoomOut`, `actualSize`.
  - It also carries the owner and the `MenuShortcut` default, or nil for "none". For example, Back is `MenuShortcut(.leftArrow, [.control, .command])` and Zoom In is `MenuShortcut("=", [.control, .command])`.
  - The doc comment says: an owner deletes its row in the task that adds the case and its `defaultShortcut`.
- [ ] `MenuShortcutDefaultsTests` checks the following. `MenuShortcut` is only `Equatable`, so the shortcut checks compare pairs.
  - `testExistingDefaultsUnchanged`: the 12 current defaults, listed literally, in §9 order.
  - `testDefaultsAreUnique`: no two shortcuts are equal across all `MenuShortcutCommand.allCases.map(\.defaultShortcut)` plus every non-nil planned row.
  - `testDefaultsAvoidReservedShortcuts`: `MenuShortcutRules.reservedName(for:)` is nil for every planned default.
  - `testPlannedRowsNotYetCases`: no planned `command` equals a `MenuShortcutCommand` raw value. This makes an owner who adds the case delete the row.
  - `testPlannedCommandsUnique`.

**Verify:**
- `swift test --filter "MenuShortcutDefaultsTests|MenuShortcutStoreTests" 2>&1 | tail -5` → `with 0 failures`.
- Full gate.

**Commit:** `test(shortcuts): frozen menu shortcut table`

#### Task 6.2: Hotkey order table [P after step 1]

**Files:**
- Create: `Sources/NoteIt/Hotkeys/HotkeyOrder.swift`, `Tests/NoteItTests/HotkeyActionTests.swift`
- Modify: `Sources/NoteIt/Hotkeys/HotkeyAction.swift` (`hotkeyID` and `init?(hotkeyID:)`)

- [ ] `HotkeyOrder.rawValues` holds the 14 §9 raw values in order.
  - `hotkeyID(for:)` returns the 1-based position.
  - `rawValue(for:)` returns the raw value at that 1-based position, or nil for 0 and anything past the table.
  - `HotkeyAction.hotkeyID` returns `HotkeyOrder.hotkeyID(for: rawValue)!`. Today's six cases keep IDs 1–6, so registered Carbon hotkeys keep their IDs.
  - `HotkeyAction.init?(hotkeyID:)` resolves through the same table: `HotkeyOrder.rawValue(for: hotkeyID).flatMap(Self.init(rawValue:))`. It no longer uses the position in `allCases`, which would map an ID to the wrong action as soon as a case is missing from the file (a gap in the table).
  - A case merged out of order still gets its table position, so the ID does not depend on merge order.
- [ ] The doc comment on `HotkeyAction` says that new cases go in the file in `HotkeyOrder` order and have no default binding.
- [ ] `HotkeyActionTests`:
  - `testRawValuesUnique`;
  - `testFirstSixUnchanged` (the six raw values and IDs 1–6);
  - `testCasesFollowFrozenOrder`: `allCases.map(\.rawValue)` is a subsequence of `HotkeyOrder.rawValues` in the same order, and every case is in the table;
  - `testHotkeyIDsComeFromTable`;
  - `testHotkeyIDRoundTrip`: `HotkeyAction(hotkeyID: a.hotkeyID) == a` for every case in `allCases`;
  - `testHotkeyIDGapsResolveToNil`: for every ID from 1 to 14 whose table raw value has no case yet (a gap), `HotkeyAction(hotkeyID:)` is nil, and so are 0 and 15. With today's six cases, IDs 7–14 are gaps; as owners add cases out of merge order, this test and the round trip together catch any lookup that counts `allCases` positions;
  - `testNoDefaultBindings`: `HotkeyManager(defaults:)` on an empty `UserDefaults(suiteName:)` suite has no binding for any case.

**Verify:**
- `swift test --filter "HotkeyActionTests|HotkeyManagerTests" 2>&1 | tail -5` → `with 0 failures` (the second class only if it exists).
- Manual: bind Quick Capture in Settings › Shortcuts before and after the change. It still fires, and the binding survives a relaunch.
- Full gate.

**Commit:** `feat(hotkeys): frozen hotkey order`

#### Task 6.3: Settings tabs [P after step 1]

**Files:**
- Modify: `Sources/NoteIt/Settings/SettingsView.swift` (`Tab`, `body`, `tab` binding, `SettingsTabRouter.show`, the `noteItShowSettingsTab` doc comment)
- Create: `Tests/NoteItTests/SettingsTabTests.swift`

- [ ] `SettingsView.Tab` becomes `String, Hashable, CaseIterable` with the 10 §9 cases in order: `general`, `shortcuts`, `editor`, `sync`, `data`, `sharing`, `smart`, `integrations`, `plugins`, `about`.
  - `isAvailable` is false for `data`, `sharing`, `smart`, `integrations` and `plugins`. Each owner flips its own case in the task that builds the tab.
  - The planned symbols go in a `symbol` property as listed in §9, for owners to use.
- [ ] The `TabView` still lists the five built tabs, written as today. The `tab` binding maps an unavailable stored value to `.general`, and so does `SettingsTabRouter.show`. A stale `settingsTab` default therefore never selects a hidden tab.
- [ ] Update the notification doc comment to list all 10 raw values and say that hidden ones open General.
- [ ] `SettingsTabTests`:
  - `allCases.map(\.rawValue)` equals `URLCommand.settingsTabs` when Task 5.3 has merged, otherwise the literal §9 list. The literal is replaced by `URLCommand.settingsTabs` in whichever of 5.3 or 6.3 merges second.
  - The available set is exactly the five built tabs.
  - A stored `"plugins"` resolves to `.general`.
- [ ] Cross-check of the sidebar table: `SidebarOrderTests` from Task 1.1 already pins `SidebarLibraryRow`. This task adds no sidebar code.

**Verify:**
- `swift test --filter "SettingsTabTests|SidebarOrderTests" 2>&1 | tail -5` → `with 0 failures`.
- Full gate.
- Open Settings in the built app: five tabs, the same as before.

**Commit:** `feat(settings): reserve frozen settings tabs`

#### Task 6.4: `NoteCommands` group [P after step 1]

**Files:**
- Rename: `Sources/NoteIt/App/RecentlyDeletedCommands.swift` → `Sources/NoteIt/App/NoteCommands.swift` (`git mv`)
- Modify: `Sources/NoteIt/App/NoteItApp.swift` (`.commands`), and any other reference (`grep -rn RecentlyDeletedCommands Sources Tests`)
- Create: `Tests/NoteItTests/NoteCommandsTests.swift`

- [ ] Rename `RecentlyDeletedCommands` to `NoteCommands` and `RecentlyDeletedMenuItems` to `NoteMenuItems`. The type doc comment becomes "The note group of the File menu (program §9 order)."
  - The items, their order, titles and shortcuts are unchanged: Version History…, Delete Note / Delete Now…, Empty Recently Deleted….
- [ ] `NoteCommands.order` holds the §9 order as IDs: `["togglePin", "lockNote", "removeLock", "lockAllNotes", "versionHistory", "deleteNote"]`. "Empty Recently Deleted…" stays after the group and is not part of the order.
  - The doc comment says that owners insert their buttons at their place in this order.
- [ ] `NoteCommandsTests`:
  - the order matches §9;
  - `versionHistory` comes before `deleteNote`;
  - every ID in the order is either a `MenuShortcutCommand` raw value or a `PlannedMenuShortcuts` command. If 6.1 has not merged, compare with a literal; the second of the two to merge switches to the constant.

**Verify:**
- `grep -rn RecentlyDeletedCommands Sources Tests` → no output.
- `swift test --filter NoteCommandsTests 2>&1 | tail -5` → `with 0 failures`.
- Full gate.
- In the built app, the File menu shows the same items in the same order.

**Commit:** `refactor(menus): rename RecentlyDeletedCommands to NoteCommands`

#### Task 6.5: General tab as a scrolling grouped form [P after step 1]

Moved from capture-plus Task 0. Capture-plus, organise and surfaces-polish only fill in their sections and turn them on afterwards.

**Files:**
- Modify: `Sources/NoteIt/Settings/GeneralSettingsView.swift`
- Create: `Tests/NoteItTests/GeneralSettingsSectionTests.swift`

- [ ] Add `GeneralSettingsSection` as frozen: the existing sections `appearance` and `startup`, then `capture`, `emailIn`, `reminders`, `cheatSheet`, `updates`, in that order. `isAvailable` is false for `emailIn` (capture-plus), `reminders` (organise) and `cheatSheet` (surfaces-polish); each owner flips its own case in the task that fills the section. The doc comment says that owners only flip availability and fill their case; they don't add or move cases.
- [ ] `body` becomes one `Form` with `.formStyle(.grouped)` that builds its sections with `ForEach(GeneralSettingsSection.allCases.filter(\.isAvailable), id: \.self)` and a `switch` that returns today's `Section` for each case. `updates` still shows only when `updater.isEnabled`.
- [ ] Drop the fixed `.frame(height: updater.isEnabled ? 620 : 540)`. The sizes become constants in `GeneralSettingsLayout` (same file):
  - `idealHeight(updatesEnabled:)` is today's height (620 with Updates, 540 without), so the window opens at its previous size;
  - `minHeight` is smaller than both (320), so the window can be made shorter than the form, and the form then scrolls instead of clipping.

  The form uses `.frame(minHeight: GeneralSettingsLayout.minHeight, idealHeight: GeneralSettingsLayout.idealHeight(updatesEnabled: updater.isEnabled))`. It sets no `maxHeight`.
- [ ] Every existing row, its order, text, footnotes and behaviour stay the same (Appearance, Startup, Capture, Updates).
- [ ] Regression check against the pre-change view: every existing General row is present, in the same order, and the window opens at its previous size or larger, with nothing clipped. Before the change, record the row labels in order and the window size (Updates on and off); `GeneralSettingsSectionTests` keeps the label list as a literal.
- [ ] `GeneralSettingsSectionTests`:
  - `allCases.map(\.rawValue)` equals the literal order above;
  - the available set is exactly `appearance`, `startup`, `capture` and `updates`, in that order;
  - `cheatSheet` comes after `reminders` and directly before `updates`;
  - `testExistingRowsKeepOrder`: the row labels the available sections produce, in order, equal the recorded pre-change list;
  - `testDefaultSizeNotSmaller`: `GeneralSettingsLayout.idealHeight(updatesEnabled:)` is at least the old fixed height for the same updater setting (540 without Updates, 620 with), so the window opens at its previous size or larger;
  - `testMinimumAllowsScrolling`: `GeneralSettingsLayout.minHeight` is greater than 0 and smaller than `idealHeight` for both updater settings, so a shorter window scrolls the form.

**Verify:**
- `swift test --filter GeneralSettingsSectionTests 2>&1 | tail -5` → `with 0 failures`.
- Full gate.
- Manual regression check: `NOTEIT_DATA_DIR=.selftest/general-form swift run NoteIt`. Settings › General opens at its previous size or larger, shows every existing row in the same order with no row or footnote clipped, and the Updates section still follows the updater setting. Drag the window shorter than the form (down to about 320 points): the form scrolls and every row can still be reached.

**Commit:** `refactor(settings): General tab as a scrolling grouped form`

#### Task 6.6: Roadmap [S, last]

Runs after every other wave 0 task is merged.

**Files:**
- Modify: `docs/roadmap.md`

- [ ] Add one ticked item at the end of the "Now: trust and switching" list: `- [x] **Shared groundwork.** The building blocks that links, Markdown storage, automation and the iPhone app build on. Only two things change in the app: Settings › General scrolls when its window is short, and restoring a version of an open note can be undone in one step.`
- [ ] Change no other item. Wave 1 plans tick their own items.
- [ ] Plain user wording: no wave numbers, task numbers or type names.

**Verify:**
- `grep -c '^- \[x\] \*\*Shared groundwork\.\*\*' docs/roadmap.md` → `1`.
- `grep 'Shared groundwork' docs/roadmap.md | grep -E 'wave|Task [0-9]|NoteIt(Core|Doc|Sync|API)'` → no output.
- `grep 'Shared groundwork' docs/roadmap.md | grep 'Settings › General scrolls' | grep -c 'undone in one step'` → `1`: both user-visible changes are named.
- `git diff --stat docs/roadmap.md` → `1 file changed, 1 insertion(+)`.

**Commit:** `docs: roadmap records the shared groundwork`

## Self-review

### Spec coverage

| Program section | Requirement | Task |
|---|---|---|
| §1 | `NoteItCore`, `NoteItDoc`, `NoteItDocAppKit`, `NoteItDocTestSupport`, `NoteItAPI` targets; iOS 17 platform | 1.1, 2.1, 2.3, 2.2, 5.1 |
| §2.1 | `Notebook`, `NoteMeta`, `SidebarSelection` with every §9 case, `FuzzyMatcher`, folding into `NoteItCore`; re-export | 1.1, 1.2 (plus 1.3, 1.4 for the rest of mobile 0.2–0.3) |
| §2.2 | Doc split; lossless `JSONValue` numbers; `language` on `codeBlock`, `ImagePolicy` in `NoteItDoc` applied by `NoteItDocAppKit`, `frontMatter`, self-contained `.noteitdoc`, `AttachmentLimit`; `noteit:` links and vectors | 2.1, 2.2, 2.3, 4.2 (`.noteitdoc` file I/O), 5.3 (tight check) |
| §2.3 / §4.1 | Body encoding follows `features`, not `formatVersion` | 3.3 (`testBodyEncodingFollowsFeatureNotVersion`) |
| §4.2 | Four feature names, `rekey` as a manifest field; any feature implies version 2; `locked-notes` requires `noteit-doc`; `known` and `supported` (empty in 3.1–3.2, `[keyring]` from 3.3, so wave 0 ends with `[keyring]` and `noteit-doc` stores are refused); generic `supported` check only, with space-session acceptance left to sharing | 3.1, 3.3, 3.4 |
| §4.3 | Read-modify-write manifest with conditional write; every retry checks `rekey`, key ID, session kind, features and `requires` again and stops instead of replaying; `updateRekey` as the only writer while `rekey` is set, checking `toKeyID` on every retry; the checks use the session's own `StoreSession.supported` | 3.3 (`StoreSession.supported`), 3.4 (`updateManifest`, `updateRekey`, `testRetryStopsWhenRekeyStarts`, `testUpdateRekeyStopsWhenRekeyChanges`, `testUpdateUsesSessionSupported`) |
| §4.4 | One path to add a feature, with device confirmation; the device list is a warning, so blockers that appear during the write come back as `lateBlockers`; initial features only when `connectSession` creates a store; the caller's own device record (`currentDeviceID`) never blocks; `DeviceInfo.platform` (from `SyncEngine`'s `platform: DevicePlatform = .mac`), `supportedFeatures` (missing means none; written from 3.3), `rekeyAck` | 3.1, 3.3 (`initialFeatures`), 3.4 (`ensureFeature`, `testDeviceAppearingDuringWriteIsReportedAfter`) |
| §4.5 | Unknown keys survive; `RawMetaOverlay` in `NoteItSync`; raw meta merged only when its `sourceRevision` equals the record's applied revision (`testUnappliedRawMetaNotMerged`); one per-kind raw-meta lifecycle (`RawMetaKind` folder, per-kind applied-revision map, raw-before-apply, deferred deletion, relaunch: `testRawMetaKindsDoNotCollide`, `testRawMetaSurvivesRelaunch`, `testKindFolders`) with the contract a later kind follows; nil fields stay out of revisions | 3.5, 4.3 |
| §2.3 | `PendingBody` and `SyncState.pendingBodyVersions` in web-app's shape, declared and persisted but unused in wave 0; old state files decode them as empty (`testSyncStateWithoutPendingBodyVersionsDecodes`, `testPendingBodyVersionsRoundTrip`) | 3.1 |
| §7 | Per-note files in the data folder (raw meta, the body-extras sidecar, Version History and its extras files) are deleted on purge only with the body's `.trash` move, after `library.json` no longer lists the note (`testFailedLibrarySaveKeepsAuxFiles`, `testAuxFilesRemovedAfterDurableDelete`) | 3.5, 4.1, 4.5 |
| §4.6 | `RemoteLayout` prefix registry with depth and sealing (`.storeKey`, `.spaceKey`, `.unsealed`) | 3.5 |
| §4.7 | Re-encryption scope rule; `RekeyBlocker` as data | 3.5 (`RekeyScope`; `RekeyRunner` stays in sync-security), 3.1 |
| §4.8 | Key grammar, uppercase UUIDs, canary keys, depth table, list prefixes and their parent roots | 3.5 (`layout-keys.json`, `testKeyGrammar`, `testListPrefixes`, `testLegacyListRootsAllowed`) |
| §4.12 | NFC passphrases for keyring stores, raw bytes for v1; an empty passphrase creates no keyring (`passphraseRequired`, `testKeyringCreateRejectsEmptyPassphrase`), nor does an empty `deviceName` (`invalidManifest`, `testKeyringCreateRequiresDeviceName`); a keyring session carries its data key (`StoreSession.dataKey`, `testSessionDataKey`), which `SyncController` saves as `syncDataKey` | 3.2, 3.3 |
| §4.10, §4.11 | Unquoted ETags, frozen wire prefix | 3.3 (ETags unquoted), unchanged `RemoteLayout.folder` |
| §2.4 / §5 | `NoteStore+Daily`, `DailyLogLine`, `DailyLogAppender` taking `DailyLogContent` and `timestamp`, no fallback provider; `DailyNotes.isAvailable` gate, false in wave 0 | 4.6 |
| §2.4 / §6 | `editBody` with `versioning` (one version per change, Restore Version included) and NoteStore-internal `extras` (versions keep extras in `<version>.extras.json`; a version without one restores with the current extras), `OpenEditorRegistry` keeping every editor per note (the most recent one gets the undoable edit, whose undo and redo restore text and extras together; the others reload) and `registerObserver(_:for:)` for read-only surfaces | 4.5 (`testUndoRestoreVersionRestoresExtras`) |
| §7 | `localNoteChange` (`created`, `edited`, `deleted`) for local actions only; sync's conflict copy goes through `createNote(…, postsLocalChange: false)` and posts nothing | 4.5 |
| §2.4 / §7 | `DerivedIndex` registry with `noteChanged` (body changes and creation), `noteRemoved`, `metadataChanged` (metadata only), `rebuild`, `flush`; registered once, no unregister; locking sends `noteRemoved`; per-Mac files in `rootURL` (`sync-meta-raw/`); `contentRootURL` | 4.4, 4.1, 3.5 |
| §2.4 / §8 | `NoteMeta.lock`, `isLocked`, data only | 4.3 |
| §2.4 / §6 | `NoteBodyStorage`; `BodyCodec` enum with `case rtfd, noteItDoc` and instance-method switches, no registry; `bodyExtras` filled from disk, and set by sync apply only after its body is installed; the RTFD `body-extras/<UUID>.json` sidecar for extras and code language IDs, two-phase (`current` and `previous` entries, each with its `bodySHA256`; a read picks the entry matching the body), write-blocking the note when unreadable (§7 file table); `persistNow` writing one note's body and the library before returning | 4.1 (`testCrashAfterSidecarStageKeepsOldExtras`, `testCrashAfterBodyInstallKeepsNewExtras`, `testFailedSyncApplyKeepsExtras`, `PersistNowTests`), 4.2 |
| §2.5 / §10 | `NoteItAPI`, error codes with the §10 statuses (`not_implemented` and `not_available` both kept), `HighlightDTO`, `TagNodeDTO.totalCount`, `LocalAPIRouteRegistry` (`registerSearchMode`, `addCapability`, `removeCapability`), `AppIdentity` additions in `NoteItSync`, `URLRouteRegistry` with reserved hosts, `URLCommand` `note`/`noteTitle` and `changesNotes` (share inbox exempt), embeds table without `--deep` that skips unbuilt sources and signs the app last | 5.1, 5.2, 5.3, 5.4, 5.5 |
| §2.6 / §9 | Menu shortcut table and uniqueness test | 6.1 |
| §9 | Hotkey order, unique raw values, first six unchanged, no default bindings | 6.2 |
| §9 | Settings tab raw values, all 10 reserved | 6.3 |
| §9 | `NoteCommands` rename and order | 6.4 |
| §2.6 | General tab as a scrolling grouped form with a section order constant, including `cheatSheet` before `updates`; today's height as the ideal height with a smaller minimum, so a short window scrolls; regression check on rows, order and window size | 6.5 |
| §2.6 | `docs/roadmap.md` records that wave 0 is done and names both user-visible changes (General scrolls, Restore Version is one Undo step) | 6.6 |
| §9 | Sidebar cases and order | 1.1 (`SidebarLibraryRow`, `SidebarOrderTests`) |

### Placeholder scan

- No task says "TBD", "later" or "similar to".
- Every code task names its files, its tests by class (and by method where another plan required the name), a filtered `swift test` command with `with 0 failures`, and the full gate. The docs task (6.6) has grep checks.
- Tasks that touch sync also run the sync self-test. Tasks that touch the build script run the script and `codesign --verify`.

### Type consistency

- `StoreFeature`, `StoreSession`, `StoreSessionRef`, `BodyEncoding`, `Keyring`, `Rekey`, `KeyIdentity`, `StoreCredential`, `RawMetaOverlay`, `RemotePrefix` and the new `SyncError` cases are sync-security's frozen shapes, changed where the program differs: `StoreFeature` has no `rekey` case, `RecordSealing` is `storeKey`/`spaceKey`/`unsealed`, `RemotePrefix` has `depth`, `DeviceInfo` has `platform`, `SyncEngine.init` has `platform: DevicePlatform = .mac`, `devicesBlocking` and `ensureFeature` take `currentDeviceID`, `ensureFeature` returns `FeatureAddition`, `connectSession` takes a required `deviceName` and `initialFeatures`, `supported` and `cipher` (all defaulted), and `StoreSession` carries `supported` and `dataKey`. `updateRekey` matches sync-security's shape. This plan also adds `StoreFeature.supported` and `requires`, `RekeyScope`, and `RekeyBlocker`'s file location.
- `AppIdentity` is the existing `NoteItSync` type; automation's three constants are added to it, and no other target declares one.
- `NoteLink` and `LinkQuery` are linking's shapes. `URLCommand`, the wire types, `LocalAPIRouteRegistry` and `CLIExit` are automation's; `APIErrorCode` is `String, Codable, Sendable, Error`, which `SearchModeHandler`'s `Result` needs. `editBody` (with `EditBodyVersioning`), `OpenEditorRegistry` and `DerivedIndex` are organise's; the observer API on `OpenEditorRegistry` is built here for surfaces-polish. `DailyLogAppender` and `DailyLogContent` are linking's.
- The `NoteBodyStorage` member list is markdown-storage's, with `contentRootURL`. `BodyStorageContract` (4.1) has a check for every member of it.
- The `NoteItDoc` JSON follows web-app's `@noteit/doc` types. `JSONValue.number` holds the original token as a `String`, never a `Double`.
- Names used across tasks are the same everywhere:
  - `LibraryCoding`, `LibraryQuery`, `TrashPolicy`, `CaptureTitle` (step 1, used again in 3.5 and 4.6);
  - `BlockKind` and `CodeLanguage` in `NoteItDoc` (2.1, used in 2.3 and 4.2);
  - `ownedCodingKeys` (3.5, extended in 4.3);
  - `isLocked` (4.3, read in 4.4 and 4.5);
  - `editBody` and `EditBodyVersioning` (4.5, called by `restoreVersion` in 4.5 and in 4.6);
  - `BodyExtrasEntry`, `BodyExtrasSidecar` and `RTFDBodyStorage.packageDigest(at:)` (4.1, used by `VersionHistory` in 4.5);
  - `persistNow(_:)` and `PersistNowError` (4.1, called by automation and capture-plus);
  - `noteChanged`, `noteRemoved`, `metadataChanged` and `refreshDerivedIndexes(for:)` (4.4, called by sync-security's lock tasks);
  - `AppendPosition` (5.3, aliased by `NoteItAPI` in 5.1, which therefore runs after 5.3);
  - `CLIVersion` (5.1, read by `NoteItCLI`);
  - `RecordSealing.storeKey`/`.spaceKey`/`.unsealed` and `RemotePrefix.depth` (3.5, read by `RekeyScope`);
  - `DevicePlatform` (3.1, the `SyncEngine.init` parameter in 3.3);
  - `PendingBody` and `SyncState.pendingBodyVersions` (3.1; written by web-app Task 0.4, read by sync-security Task 4.3, declared nowhere else);
  - `LocalNoteChangeKind`, `createNote`'s `postsLocalChange`, `registerObserver(_:for:)`, `markActive` and `textViews(for:)` (4.5);
  - `FeatureAddition` and `lateBlockers` (3.4), `connectSession`'s `deviceName`, `initialFeatures`, `supported` and `cipher`, and `StoreSession.supported` and `.dataKey` (3.3);
  - `ImagePolicy` in `NoteItDoc` (2.1, applied in 2.3 and 4.2);
  - `GeneralSettingsSection` (6.5; capture-plus, organise and surfaces-polish flip availability) and `GeneralSettingsLayout` (6.5);
  - `URLCommand.settingsTabs` (5.3, compared in 6.3);
  - `PlannedMenuShortcuts` (6.1, compared in 6.4);
  - `HotkeyOrder` (6.2).
- Placement: `DailyLogAppender` is at `Model/DailyLogAppender.swift`, matching the linking plan. `NoteLink.swift` and `URLCommand.swift` are flat in `Sources/NoteItCore/`, matching linking and automation.

### No behaviour change

- New stores are still v1 manifests with no `features`.
- No app path calls `ensureFeature`, `DailyLogAppender`, `persistNow` or either registry. The only app caller of `editBody` is Restore Version, which gives the same text and the same single Version History entry as before (4.5).
- No `DerivedIndex` or `OpenEditorRegistry` observer is registered, and nothing observes `localNoteChange`.
- `DailyNotes.isAvailable` is false, so no daily-note entry point appears.
- Settings shows the same five tabs, and the File menu the same items.
- The sidebar is not reordered: `SidebarLibraryRow` is a constant, and the three new `SidebarSelection` cases show empty lists that nothing can select.
- There are two user-visible changes:
  - Settings › General is a scrolling grouped form with the same controls in the same order, at its previous window size or larger (6.5);
  - Restore Version in an open note becomes one Undo step, because it goes through `editBody` (4.5).
- The other differences are outside the app's UI:
  - `docs/roadmap.md` has one new ticked item that names the two changes above (6.6);
  - on disk, raw meta files appear under `sync-meta-raw/notes/` and `sync-meta-raw/notebooks/` in the data folder, and the device records gain `platform`, `appVersion` and `supportedFeatures`, which older builds ignore; every new version gets a `<version>.extras.json` beside it in `history/`, which older builds ignore. v1 manifests stay byte-identical.

### Open issues

None. The program contract, this plan and the sub-project plans agree on every seam listed above. `StoreFeature.supported` is empty until Task 3.3 adds `.keyring`. web-app Tasks 0.4–0.5 add `.noteItDoc` together with the Mac body conversion; until then a build refuses `noteit-doc` stores. sync-security adds `.lockedNotes` in its milestone M5, in wave 3 after those tasks.
