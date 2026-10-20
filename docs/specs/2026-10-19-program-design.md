# NoteIt Program — How the Sub-projects Fit Together

Status: proposed · Date: 2026-10-19 · Companion plan: docs/plans/2026-10-19-foundations.md

## Goal

NoteIt aims to be the notes app people pick when they want Apple Notes speed, plain files they own, end-to-end encrypted sync through storage they choose, real automation, and private on-device smart features. It should be free, with no account and no telemetry.

The work is split into 13 sub-projects plus the existing web app. Each has its own spec and plan. This document is the contract between them. When a sub-project spec disagrees with this document, this document wins, and the spec gets fixed.

## Why people would switch

Research into what users of Apple Notes, Obsidian, Notion, Bear, Joplin, Standard Notes, Trilium, SiYuan and Notesnook ask for kept coming back to the same list:

- Notes that stay on your devices, in open files, with export that doesn't lose anything.
- Sync that just works, without an account, through storage you already have.
- Speed and polish without first setting up a stack of plugins.
- Links between notes, tags, tasks, templates and daily notes.
- Automation: links, Shortcuts, a command line and an API.
- Capture from everywhere: browser, screenshots, voice and email.
- Smart features that never send notes to someone else's server.
- A good phone app, and a way in from Windows and Linux.

No single app offers all of these today. The sub-projects below close the gaps one at a time.

## Sub-projects

| # | Slug | Spec | Plan |
|---|------|------|------|
| 00 | foundations | this document | [plans/2026-10-19-foundations.md](../plans/2026-10-19-foundations.md) |
| 01 | automation | [automation](2026-10-19-automation-design.md) | [plan](../plans/2026-10-19-automation.md) |
| 02 | markdown-storage | [markdown-storage](2026-10-19-markdown-storage-design.md) | [plan](../plans/2026-10-19-markdown-storage.md) |
| 03 | linking | [linking](2026-10-19-linking-design.md) | [plan](../plans/2026-10-19-linking.md) |
| 04 | organise | [organise](2026-10-19-organise-design.md) | [plan](../plans/2026-10-19-organise.md) |
| 05 | capture-plus | [capture-plus](2026-10-19-capture-plus-design.md) | [plan](../plans/2026-10-19-capture-plus.md) |
| 06 | private-ai | [private-ai](2026-10-19-private-ai-design.md) | [plan](../plans/2026-10-19-private-ai.md) |
| 07 | web-clipper | [web-clipper](2026-10-19-web-clipper-design.md) | [plan](../plans/2026-10-19-web-clipper.md) |
| 08 | sync-security | [sync-security](2026-10-19-sync-security-design.md) | [plan](../plans/2026-10-19-sync-security.md) |
| 09 | sharing | [sharing](2026-10-19-sharing-design.md) | [plan](../plans/2026-10-19-sharing.md) |
| 10 | plugins | [plugins](2026-10-19-plugins-design.md) | [plan](../plans/2026-10-19-plugins.md) |
| 11 | mobile | [mobile](2026-10-19-mobile-design.md) | [plan](../plans/2026-10-19-mobile.md) |
| 12 | surfaces-polish | [surfaces-polish](2026-10-19-surfaces-polish-design.md) | [plan](../plans/2026-10-19-surfaces-polish.md) |
| 13 | growth | [growth](2026-10-19-growth-design.md) | [plan](../plans/2026-10-19-growth.md) |
| — | web-app | [web-app](2026-10-13-web-app-design.md) | [plan](../plans/2026-10-13-web-app.md) |

Each idea belongs to one sub-project. The others reference it by slug and never specify it again.

## Delivery order

1. **Wave 0: foundations.** Shared seams that several sub-projects need. These are built in the order listed in §2. They are planned in `docs/plans/2026-10-19-foundations.md` (tasks 1.1–6.6), which takes tasks out of the other plans; those plans say "moved to foundations".
2. **Wave 1:** automation, markdown-storage (everything except its locked-notes milestone, Milestone 10, which is in wave 3), linking, organise. They can run in parallel once wave 0 is done.
3. **Wave 2:** capture-plus, private-ai, web-clipper, sync-security (its M0 is in wave 0 and its locked-notes milestone M5 is in wave 3), surfaces-polish. Inside wave 2, capture-plus's `sourceLine` extraction ships before web-clipper's task that reads `sourceLine`.
4. **Wave 3:** web-app (everything except Tasks 0.1–0.3 and the type definitions of Task 0.4, which are in wave 0; this includes the store format work of Task 0.4 and the body conversion of Task 0.5), sync-security's locked-notes milestone (M5), markdown-storage's locked-notes milestone (Milestone 10, after sync-security Task 5.1), mobile (everything after the core extraction), sharing, plugins. Locked notes require `noteit-doc` (§4 rule 2), so M5 lands after web-app Tasks 0.4–0.5.
5. **Growth** runs alongside the waves. The public launch happens after the first release that contains all of wave 1.

Each milestone in each plan ships on its own and leaves the app working.

## 1. Target graph

`Package.swift` keeps `swift-tools-version:5.10` and declares `platforms: [.macOS(.v14), .iOS(.v17)]` once, in wave 0 (task 1.1). No plan changes `platforms` after that.

SwiftPM platforms are package-wide. The Platforms column below says where a target is used, not what SwiftPM builds. An `ImportHygieneTests` test fails if an iOS-capable target imports AppKit, and checks each portable target against a per-target allow list: Foundation, CryptoKit, CommonCrypto, Security and the targets it depends on. `NoteItAPI` is the only portable target allowed to import `Network`. `NoteItMobileKit` is the only one allowed to import `ImageIO` and `CoreGraphics` (both available on iOS and macOS), for the phone's image normalisation.

| Target | Kind | Platforms | Depends on | Holds |
|---|---|---|---|---|
| `NoteItCore` | library | macOS, iOS | — | Pure models and logic; full list below |
| `NoteItDoc` | library | macOS, iOS | `NoteItCore` | `noteit-doc` schema, validation, body container, `BlockKind`, `CodeLanguage`, the editor's block sentinels, `AttachmentLimit`, `ImagePolicy` (Foundation only) |
| `NoteItDocAppKit` | library | macOS | `NoteItDoc` | `NSAttributedString` ⇄ `noteit-doc` converter, style provider, ImageIO image normalisation that applies `ImagePolicy` |
| `NoteItDocTestSupport` | library, test only | macOS, iOS | `NoteItDoc` | `RandomDocGenerator`, golden fixtures loader |
| `NoteItSync` | library | macOS, iOS | — | Existing engine plus `StoreSession`, manifest features, keyring types, `RemoteLayout` registry, `RawMetaOverlay`, `RekeyRunner`, WebDAV, lock crypto, sharing codec |
| `NoteItMarkdown` | library | macOS, iOS | `NoteItDoc` | Markdown ⇄ `noteit-doc` (the only lossless Markdown path; §6) |
| `NoteItAPI` | library | macOS | `NoteItCore`, `NoteItSync` | Local API wire types, `HTTPMessage`, `ClientRecord`, server, client, `LocalAPIRouteRegistry` (Foundation and Network) |
| `NoteItMCP` | library | macOS | `NoteItAPI`, `NoteItCore` | MCP over stdio |
| `NoteItSmart` | library | macOS | `NoteItCore` | Embeddings, vector index, providers |
| `NoteItMail` | library | macOS | — | IMAP client |
| `NoteItPlugins` | library | macOS | `NoteItCore` | Plugin manifest, permissions, host protocol |
| `NoteItMobileKit` | library | macOS, iOS | `NoteItCore`, `NoteItDoc`, `NoteItSync`, `NoteItMarkdown` | Phone library, sync adapter, capture inbox, the phone's image normalisation |
| `NoteIt` | executable | macOS | all macOS libraries above, Sparkle | The Mac app, including `URLRouteRegistry` (§3) |
| `NoteItCLI` | executable | macOS | `NoteItAPI`, `NoteItSync`; `NoteItMCP` from wave 2 | `noteit` command, shipped as `Contents/Helpers/noteit` |
| `NoteItPluginHost` | executable | macOS | `NoteItPlugins` | One process per running plugin, `Contents/Helpers/` |

**`NoteItCore` holds:**

- Models: `Notebook`, `NoteMeta` and `SidebarSelection`. `SidebarSelection` keeps today's cases, including `.recent` and `.conflicts`. The existing `.tag(String)` is read as a slash-separated tag path. Wave 0 adds `.today`, `.tasks` and `.smartFolder(UUID)`.
- Text and search: `TextFold`, `FuzzyMatcher`, and `LibraryQuery` (pure filtering, search and sorting for every sidebar selection).
- Library: `LibraryFile` and `LibraryCoding`, `TrashPolicy`.
- Capture: `CaptureTitle`.
- Links and URLs: `NoteLink`, `URLCommand`, `AppendPosition`.
- Daily notes: daily note titles and `DailyLogLine`.
- Added by organise in wave 1: the query language and the `SmartFolder` model. Wave 0 doesn't create `SmartFolder`.

**Other rules:**

- `NoteItOrganise` is not created; its contents go into `NoteItCore`.
- `NoteItDoc` has no ImageIO code. Image normalisation lives in `NoteItDocAppKit` on the Mac and in `NoteItMobileKit` on the phone.
- `NoteItAPI` is created in wave 0 with `HTTPMessage` and the `NoteItAPITests` target (task 5.1) and `ClientRecord` (task 5.2). Automation's later tasks extend them and don't create them again.
- `AppIdentity` stays the existing public enum in `NoteItSync` (`Sources/NoteItSync/Migration/AppIdentity.swift`), because `scripts/build_app.sh` reads `bundleID` from that file. New identity constants, such as automation's `urlScheme`, `localAPIKeychainService` and `cliKeychainService`, are added to it. `NoteItAPI` and `NoteItCLI` import `NoteItSync` and use it. No other target declares an `AppIdentity` type or repeats its literals.
- `NoteItCLI` is created as a stub in wave 0 (task 5.1). `AppIdentity` has no version; the CLI reads its version from the enclosing app's `Info.plist` (`CFBundleShortVersionString`, written by `scripts/build_app.sh`) through `CLIVersion` in `NoteItAPI`, and prints `dev` when it runs outside an app. Automation builds it out in wave 1 without the `mcp` subtree. Private-ai adds the `NoteItMCP` dependency and `noteit mcp` in wave 2.
- `NoteItPlugins` compiles on iOS because platforms are package-wide. Its macOS-only code sits under `#if os(macOS)`. Only the Mac app links it.
- Shared test vectors for Swift and TypeScript live in `fixtures/golden/`, a new top-level folder.
- The Safari extension and the Mac Share extension are built by a script with `xcrun swiftc` into `Contents/PlugIns/`. They are listed in `Package.swift` only so they type-check.
- The iPhone and iPad app and their extensions are an XcodeGen project in `mobile/` that uses the library products.
- No cycles. Pure logic lives in libraries and is tested with `swift test`. iOS smoke tests and the browser extension tests run in their own CI jobs (`ios`, `clipper`).

## 2. Wave 0: foundations

Built in this order. Each step names the plan the work came from and the foundations tasks that build it. Wave 0 has no user-visible change except two: the General settings tab becomes a scrolling form (6.5), and Restore Version in an open note becomes one Undo step, because it goes through `editBody` (4.5, §6).

1. **Platforms and `NoteItCore`** (from mobile 0.1–0.3 and organise T1; tasks 1.1–1.4).
   - Set the platforms and create `NoteItCore` (1.1).
   - Move `Notebook`, `NoteMeta` and `SidebarSelection`, with every case listed in §1, into `NoteItCore` (1.1). The Mac app re-exports them.
   - Move `TextFold` and `FuzzyMatcher` (1.2); `LibraryFile`, `LibraryCoding`, `TrashPolicy` and `CaptureTitle` (1.3); and `LibraryQuery` (1.4).
   - Every field added later by any sub-project is added in `NoteItCore`.
2. **`NoteItDoc` split** (from web-app Phase 0, Tasks 0.1–0.3 and the `AttachmentLimit` part of Task 0.6, and mobile Task 0.5; tasks 2.1–2.4).
   - Create `NoteItDoc`, `NoteItDocAppKit` and `NoteItDocTestSupport`. Move `BlockKind`, `CodeLanguage`, the editor's block sentinels and `AttachmentLimit` into `NoteItDoc`.
   - Add the changes markdown-storage asks for: optional `language` on `codeBlock`, an image policy on export (`ImagePolicy` is a pure enum in `NoteItDoc`; `NoteItDocAppKit` applies it), `frontMatter` as a known container field, `.noteitdoc` for standalone files. Unknown top-level container keys are kept, with every number written back exactly as it was read (`JSONValue.number` holds the original token, never a `Double`). A `.noteitdoc` file is self-contained: its attachments are inside the container, with no sibling files. `ContainerExtras` (frozen, in `NoteItDoc`) carries `frontMatter` and the unknown top-level keys beside the editor's text, so they survive read → edit → write (§6 body codecs). The converter keeps a code block's `language` through editing in one new paragraph attribute, `noteItCodeLanguageID` (task 2.3), including identifiers that `CodeLanguage` doesn't know.
   - Allow `noteit:` links in the Swift validator. Wave 0 ships the shared golden vectors for them in `fixtures/golden/`. The TypeScript validator lands with the web app and must pass the same vectors.
   - Each portable target gets an iOS build check (mobile Task 0.5).
   - Add golden vectors for the existing store format (2.4).
3. **Store session and manifest** (from sync-security M0 plus the keyring value types from its Task 4.1; replaces web-app Task 0.4's type definitions; tasks 3.1–3.5). Rules in §4.
   - `StoreFeature` with `known` and `supported` (3.1). `supported` is empty in 3.1 and 3.2. Task 3.3 adds `keyring` in the same change that adds `connectSession` and the keyring cipher, so wave 0 ends with `supported = [.keyring]` and a wave 0 build refuses a store with `noteit-doc` (§4 rule 2).
   - `SyncError.rekeyBlocked` and `RekeyBlocker`, as data only (3.1).
   - `PendingBody` and `SyncState.pendingBodyVersions`, moved from web-app Task 0.4 with its shape (3.1). They are declared and persisted, and a state file without them decodes as empty, but nothing uses them in wave 0. Sync-security's rekey precondition (Task 4.3) and web-app's doc-body publish (Task 0.4) both use this one field, and neither plan declares it.
   - `DeviceInfo` fields (3.1), and `SyncEngine`'s `platform: DevicePlatform = .mac` init parameter (3.3).
   - `Keyring`, `KeyIdentity`, `StoreCredential` and the `rekey` manifest field (3.2).
   - `StoreSession` (carrying the `supported` set it was opened with and, for a keyring store, its data key) and `connectSession` with a required `deviceName` and defaulted `initialFeatures`, `supported` and `cipher` (3.3), and `SyncEngine.updateManifest`, `updateRekey` and `ensureFeature(_:backend:session:currentDeviceID:confirm:)` (3.4).
   - The `RemoteLayout` registry, the rekey scope rule (`RekeyScope`, with the sealing kinds `.storeKey`, `.spaceKey` and `.unsealed`) and `RawMetaOverlay` (3.5).
   - `RekeyRunner` behaviour stays in sync-security.
4. **Note store seams** (tasks 4.1–4.6).
   - `NoteBodyStorage` (from markdown-storage M1; 4.1): every body read and write goes through it.
   - The `BodyCodec` enum (4.2): `enum BodyCodec { case rtfd, noteItDoc }`, with its per-format conversion API as instance methods that switch over the case. There is no codec registry: markdown-storage adds `case markdown` in wave 1 by editing that enum (§6).
   - `NoteMeta.lock` and `NoteMeta.isLocked` (from sync-security; 4.3), as data only, with no behaviour yet. Nobody writes stubs for them.
   - `DerivedIndex` registry (from organise T3; 4.4): the only way to keep something in step with note bodies (§7).
   - `NoteStore.persistNow(_:)` (4.1): writes one note's body and the library at once and throws on failure, so capture paths remove their source only after the note is on disk (§6).
   - `NoteStore.editBody` and `OpenEditorRegistry`, including `registerObserver(_:for:)` for read-only surfaces (from organise; 4.5): the only way code outside the editor changes note text (§6).
   - The `localNoteChange` notification (from plugins; 4.5), the one extra `NoteStore` hook (§7).
   - Daily notes (from linking; 4.6): daily titles, `NoteStore+Daily`, `DailyLogAppender` (taking `DailyLogContent`), `DailyLogLine` and the `DailyNotes.isAvailable` gate (§5). They have no UI.
5. **Integration scaffolding** (from automation T1, T5 and T17; tasks 5.1–5.5). This step can run in parallel with steps 2–4. Task 5.3 comes before 5.1, because 5.1's wire types alias the `AppendPosition` that 5.3 creates in `NoteItCore`.
   - The `NoteItAPI` target with its wire types, `HTTPMessage`, the `NoteItAPITests` target and the `NoteItCLI` stub (5.1).
   - `LocalAPIRouteRegistry` (with `addCapability` and `removeCapability`) and `ClientRecord` (5.2).
   - `NoteLink`, `URLCommand` and `AppendPosition` in `NoteItCore` (5.3; §3).
   - `URLRouteRegistry`, a `@MainActor` class in the app target, `Sources/NoteIt` (5.4; §3).
   - The embeds table in `scripts/build_app.sh` (5.5; §10).
6. **Frozen tables** (tasks 6.1–6.5) and the roadmap (6.6). Add the §9 tables as code constants and tests, so that later plans only fill them in.
   - Menu shortcuts (6.1), `HotkeyOrder` (6.2), Settings tabs (6.3), the `NoteCommands` group (6.4).
   - `GeneralSettingsView` becomes a scrolling grouped `Form` with a constant section order (6.5). Capture-plus, organise and surfaces-polish only fill in their sections and turn them on.
   - The §9 sidebar order is frozen as a constant (task 1.1, with the `SidebarSelection` cases). The visible sidebar is not reordered in wave 0; each owner places its rows in the frozen order when it adds them (§9).
   - `docs/roadmap.md` records that wave 0 is done (6.6), as the last foundations task, and names both user-visible changes: the General tab scrolls, and Restore Version in an open note is one Undo step.

## 3. Links between notes

- The stored link is `noteit://note/<UUID>`, optionally with `?heading=<text>`. A link to a note that doesn't exist yet is `noteit://note?title=<text>`. Linking owns the format, `NoteItCore.NoteLink`.
- Automation owns all `noteit://` routing and the `URLCommand` parser. `URLCommand` gains `.note(id:heading:)` and `.noteTitle(title:heading:)`. `noteit://open?id=` stays as an action and opens the same note.
- Wave 0 builds `NoteLink` and `URLCommand` in `NoteItCore` (task 5.3). Linking uses them and doesn't create them.
- `URLRouteRegistry` is a `@MainActor` class in the app target (`Sources/NoteIt`), built in task 5.4. `NoteItAPI` holds only `LocalAPIRouteRegistry`. The `URLCommand` parser stays in `NoteItCore`. `URLRouteRegistry.register(host:handler:)` lets a sub-project own an extra host. The handler gets the whole URL, including the fragment. Sharing registers `join`.
- Reserved core hosts: `new`, `append`, `open`, `note`, `search`, `daily`, `settings`, `x-callback-url`.
- Mobile uses the same `URLCommand` parser from `NoteItCore`. On the phone, hosts that only work on the Mac show "This works in NoteIt for Mac".
- There is one "Copy Note Link" command (Edit menu, ⌃⌘L), owned by automation. It copies the `noteit://note/<UUID>` form. Linking's context menu and palette entry call the same command.
- MCP resources, the Local API and sharing all print the `noteit://note/<UUID>` form.

## 4. Sync store rules

These apply to the native app, the web app and the phone.

1. **Features, not version numbers.** Body encoding, the upgrade trigger, the web client's "legacy store" check and the phone's "store needs upgrade" check all depend on whether `features` contains `noteit-doc`. None of them check `formatVersion` directly.
2. **Any feature means version 2.** A manifest with any entry in `features` has `formatVersion: 2`.
   - Feature names: `noteit-doc`, `keyring`, `locked-notes`, `noteit-space`.
   - `rekey` is a manifest field, not a feature.
   - `locked-notes` requires `noteit-doc`. `ensureFeature` adds `noteit-doc` first.
   - `noteit-space` is accepted only by a shared-notebook (space) session. Foundations builds only the generic `supported` check, which `connectSession` takes as a `supported` parameter (default `StoreFeature.supported`). Sharing passes `StoreFeature.supported ∪ [.noteItSpace]` for space sessions, and its own `SpaceCipher` through `connectSession`'s `cipher` parameter, and owns the space-session acceptance logic.
   - Known and supported: `StoreFeature.known` lists every name above. `StoreFeature.supported` lists the features this build can read. A session refuses a store with any feature that isn't in `supported`. `supported` stays empty until foundations task 3.3 adds `keyring` together with `connectSession` and the keyring cipher, so a build never claims a feature it can't open. Wave 0 ends with `supported = [.keyring]`: a wave 0 build refuses a store with `noteit-doc`, `locked-notes` or `noteit-space`. Each owner adds its feature to `supported` in the task that ships the reader: web-app adds `noteit-doc` together with the Mac body conversion (web-app Tasks 0.4–0.5, wave 3), sync-security adds `locked-notes` in its locked-notes milestone (M5, wave 3, after web-app Tasks 0.4–0.5), sharing adds `noteit-space` for space sessions only.
3. **Manifest writes keep everything.** Every manifest change reads the manifest, changes only its own keys and writes it back with a conditional write. `upgradeToV2` adds `noteit-doc` and keeps `keyring`, `encryption` and every other feature. It refuses while the `rekey` field is set.
   - **Retries check again.** When the conditional write fails and the change is retried, every retry re-reads the manifest and checks it again before re-applying the change: the `rekey` field is still unset, the key ID is the session's, the manifest still suits the session kind, and its features are still supported and meet the `requires` rules. If a check fails, the change stops with `rekeyInProgress`, `keyChanged` or `manifestChangedConcurrently` and writes nothing. It never replays the change onto a manifest it hasn't checked.
   - **Writes during a rekey.** `updateManifest` refuses any manifest whose `rekey` field is set; starting a rekey (setting the field) goes through it. While the field is set, the only writer is `updateRekey(backend:session:expectedRekeyToKeyID:_:)`. On every attempt, retries included, it requires `rekey.toKeyID` to equal the expected value, else it stops with `manifestChangedConcurrently` and writes nothing. It may update or clear that `rekey` and the fields that move with it (`keyring`, `encryption`, and `rekey`'s `previousKeyring` and `previousEncryption`), nothing else. Sync-security's heartbeat and finish use it.
4. **One way to add a feature.** `SyncEngine.ensureFeature(_:backend:session:currentDeviceID:confirm:)` (task 3.4) is the only path that adds a feature older apps can't read.
   - **New stores and spaces:** creating a brand-new store (or a shared-notebook space) writes its initial `features` directly in the first manifest, through `connectSession`'s `initialFeatures` parameter, with `formatVersion: 2` when the list is non-empty and with every `requires` rule met. `initialFeatures` is used only when `createIfMissing` creates the store and is ignored for an existing one. Wave 0 callers pass nothing, so new stores stay featureless v1 manifests; web-app Task 0.4 passes `noteit-doc` (plus `keyring` for an encrypted keyring store). There are no other devices yet, so there is nothing to check. `ensureFeature` is the only path that adds a feature to an existing store or space, that is, to any manifest that has already been written.
   - Each device record in `devices/` carries `platform` (`mac`, `ios` or `web`), `appVersion`, `supportedFeatures: [String]` and `rekeyAck`. A Mac writes `supportedFeatures` from foundations task 3.3 on, when `supported` first has an entry.
   - The check uses `supportedFeatures`. A device record without the field counts as supporting no features.
   - The device adding the feature never blocks itself. The caller passes its own device ID (`currentDeviceID`), and its own record is skipped even when it is stale and has no `supportedFeatures`.
   - If any device blocks, the user sees the list of blocking Macs and devices that will stop syncing and confirms first.
   - **Known limitation:** the device list is a warning, not a fence. A device can write its record between the check and the manifest write. After a successful write, `ensureFeature` lists devices again and returns any new blocker in its result (`FeatureAddition.lateBlockers`); the caller shows it once as a notice. The write is not undone.
   - The automatic upgrade to `noteit-doc` runs only when no device blocks, or after that confirmation. The web-app spec's old reason for skipping this ("NoteIt has not been released") no longer holds.
5. **Unknown keys survive.** Every writer keeps the last decrypted note and notebook JSON and patches only the keys it owns.
   - `RawMetaOverlay` moves into `NoteItSync`; the web app has the same thing in TypeScript.
   - The Mac keeps its raw copies in `NoteStore.rootURL`, one folder per record kind: `sync-meta-raw/<kind>/<UUID>.json`, where `<kind>` is the `RawMetaKind` raw value (task 3.5). Wave 0 has `notes` and `notebooks`; organise adds `smart-folders` and surfaces-polish adds `boards`. Records of different kinds with the same UUID never share a file.
   - Every kind uses the one lifecycle foundations freezes in `NoteStore+RawMeta` (task 3.5): raw copy written before apply, merged only when its revision matches, an applied-revision map per kind (notes and notebooks in `library.json`, a later kind in its own data-folder file, saved with its records), deferred deletion, and a relaunch test. A later kind adds only the `RawMetaKind` case and the per-kind pieces task 3.5 lists.
   - Each raw copy records `sourceRevision`, the remote revision it came from (the `RecordPayload.revision` the engine records as applied). A writer merges a raw copy only when its `sourceRevision` equals the revision it last applied for that record. Otherwise it writes as if there were no raw copy, and the next successful apply replaces it. A raw copy is written before its record is applied, so a failed apply leaves one that must not be merged. A purged record's raw copy is deleted only after the deletion is saved in `library.json` (§7).
   - A field added to `Notebook` or `NoteMeta` goes into the revision fields only when it isn't nil, so existing revisions don't change. For example, `Notebook.parent` is included only when a parent is set.
6. **One list of remote record kinds.** `RemoteLayout` keeps a registry of every prefix and how it's sealed. There are three sealing kinds:
   - `.storeKey`: sealed with the session's key. That is the personal store key, or the space key in a space session.
   - `.spaceKey`: objects sealed with a space key inside a personal store.
   - `.unsealed`: signed logs, HPKE key files and the canary. `RekeyRunner` never re-seals them.

   Prefixes by owner:
   - existing: `notebooks/`, `notes/`, `tombstones/`, `devices/`
   - web-app: `bodies/`
   - organise: `smart-folders/`, `claims/reminders/`
   - sync-security: `keys/`
   - surfaces-polish: `boards/`
   - sharing: `noteit/identity/v1/`, `noteit/space/v1/`, and a depth-2 `noteit/v1/devices/` row for space device records (`<member-id>/<UUID>.json`)

   Every sub-project that adds a prefix registers it there and adds a key test vector for the web server.
7. **One re-encryption runner.** `RekeyRunner` (sync-security) re-seals every key under the store root whose `RemoteLayout` prefix has `sealing: .storeKey`, except `manifest.json`, `.canary/` and `.unsealed` rows. Wave 0 writes this rule down as `RekeyScope` (task 3.5).
   - Prefixes with `sealing: .spaceKey` are re-sealed by the same runner with the space cipher when a space key changes.
   - `.unsealed` rows are never re-sealed.
   - Only contents are re-encrypted. Keys and body paths stay the same. Body keys must not depend on meta ETags that a rekey changes; web-app checks its `baseTag` rule against this.
   - It runs only when no body versions are waiting to upload.
   - **Fence:** each device writes the rekey id as `rekeyAck` in its device record. The runner goes ahead when every device that hasn't been removed has acknowledged, or when the user confirms removing the stale devices. Otherwise it stops with `SyncError.rekeyBlocked`.
   - Check Sync Storage runs before and after it. A test lists the store afterwards and checks that nothing still opens with the old key.
8. **Remote keys.** The sync-security spec owns the key grammar and a per-prefix depth table.
   - Every segment matches `[A-Za-z0-9._-]+` and is not `.` or `..`.
   - UUID segments are uppercase canonical UUIDs.
   - The depth table lists every prefix, including `noteit/.canary/<UUID>`. A key is valid when it sits under a registered prefix at exactly the depth of a row with that path (two rows may share a path with different depths).
   - The web server accepts only keys that fit the table. List requests must use a registered prefix or one of its parent roots, such as `noteit/v1/`, so that clients that list the whole root (the sync engine, rclone) keep working. `RemoteLayout.isListablePrefix` allows both, plus Inkwell's `inkwell/v1/` and `inkwell/` so the 0.4.0 store copy (`RemoteMigration`) can look for an old store. Keys under `inkwell/` are not valid.
9. **Unknown record kinds are left alone.** The web and phone engines ignore any record kind or prefix they don't know, without per-record errors, and never delete it. This covers `smart-folders/`, `boards/`, `claims/`, `keys/`, `noteit/identity/`, `noteit/space/` and any later kind.
10. **WebDAV ETags** are stored without quotes, like every other backend.
11. The wire prefix `noteit/v1/` stays frozen. NoteIt 0.4.0 moved it from Inkwell's `inkwell/v1/`: on connect, `RemoteMigration` copies a store found only there to `noteit/v1/`, byte for byte with the manifest last, and leaves the old copy in place. Nothing else reads or writes under `inkwell/`, so every remote addition in these specs goes under `noteit/`.
12. **Passphrases.** Keyring stores use NFC-normalised passphrases. v1 stores keep the raw bytes.
13. **Locked bodies.** A locked note's remote body sits at the same path as its normal body for that store format, with `.locked` replacing the body suffix. `bodyVersion` increments as usual. §8 has the rest.
14. **Boards.** `boards/<notebookID>.json` is its own record kind: last writer wins, no tombstones. It is deleted when the notebook is deleted. A board whose notebook no longer exists, for example because the notebook was deleted on the phone or the web, is deleted by the next Mac that syncs. The notebook record has no board fields.

## 5. Daily notes and Append to Today

- **Owner:** linking owns daily notes: `NoteStore.dailyNote(for:createIfMissing:)`, the "Daily Notes" notebook and daily titles.
- **Titles:** a new daily note is titled in the user's chosen `DailyTitleFormat` (`iso`, `long` or `weekdayLong`; preference `dailyNoteTitleFormat`, default `iso`). Lookup recognises a title in every supported format, not just the current one and `iso`, so switching formats never creates a second daily note for the same day. Existing titles are not rewritten.
- **Wave 0** (task 4.6) builds the parts other plans call:
  - daily note titles in `NoteItCore`;
  - `NoteStore+Daily`;
  - `DailyLogAppender`, whose `append(_ content: DailyLogContent, timestamp: Bool = true, …)` takes `enum DailyLogContent { case plain(String); case attributed(NSAttributedString) }`;
  - `DailyLogLine`.

  None of them has UI.
- **Formatting:** `DailyLogLine` (in `NoteItCore`) formats appended lines as `- HH:mm text`, 24-hour, `en_US_POSIX`, or `- text` when `timestamp` is false. `DailyLogAppender` is the only code that appends to a daily note.
- **Callers:** capture-plus's Append to Today panel, automation's `POST /v1/daily/append`, the `noteit today` and `noteit append --today` commands, the `noteit://append?daily=today&text=` link and the "Append to Daily Note" Shortcuts action all call `DailyLogAppender`.
  - Plain text is passed as `.plain`. A caller that accepts Markdown (such as `format: markdown`) parses it with the existing Markdown importer first (`MarkdownReader.attributedString(from:)`, then `NoteItMarkdown` once markdown-storage replaces it; §6) and passes the result as `.attributed`. `DailyLogAppender` never parses Markdown itself.
- **One gate:** `DailyNotes.isAvailable` is false in wave 0. Linking sets it to true when its daily-note UI ships. While it is false:
  - Append to Today is unavailable;
  - the daily API routes return `501 not_implemented`;
  - the daily CLI commands and the `daily` and `append?daily=` URL hosts are unavailable.
- **No fallback:** there is no other daily-note provider.
- **Templates:** linking applies the daily template later, inside `dailyNote(for:createIfMissing:)`.
- **Local API:** the shape is automation's: `GET /v1/daily?date=&create=&format=` and `POST /v1/daily/append` with `{text, timestamp?, date?, format?}`. `format` is `plain` or `markdown`.

## 6. Changing note text from code

- **One path:** `NoteStore.editBody` (organise) is the only way code outside the editor changes a note's text. There are no exceptions: Restore Version also goes through it.
  - It edits only editable surfaces: the main window and floating notes. It keeps undo working and marks the note for saving.
  - **Several editors on one note:** `OpenEditorRegistry` keeps every open editor for a note. `editBody` applies the change, with Undo, in the most recently used editor, saves it, and then pushes the saved body to every other open editor for that note. Those reload it as they would an external change; the edit is not added to their undo stacks. Before the change, every open editor for the note saves its unsaved typing in registration order with the most recently used editor last, so that editor's text wins and the change applies on top of it.
  - **Versions:** `editBody` takes `versioning: EditBodyVersioning = .recordCurrent` (`.recordCurrent` or `.none`). With `.recordCurrent` it records the note's current body in Version History exactly once before the change, whether the note is closed or open in an editor (where it also registers the change for Undo). Restore Version calls it with `.recordCurrent`. Callers never record a version themselves before calling `editBody`.
  - **Versions keep extras:** each version also stores the note's `ContainerExtras` at that time (and on an RTFD store its code-language IDs) in `<version>.extras.json` beside it, as one sidecar entry (format below). Every new version gets this file, also when its extras are empty, whichever path records it (`editBody`, or the saved body kept before a save or sync apply replaces it). The file is written before the version is installed; if it can't be written, no version is kept, so `editBody` throws `versionNotSaved`. `editBody` takes `extras: ContainerExtras? = nil`, used only inside `NoteStore`: nil keeps the note's extras, and a value replaces `bodyExtras[id]` in the same write. Restore Version loads the version's text and extras and passes both in one `editBody` call. Only a version from before extras support has no extras file; it restores with the note's current extras. In an open editor, Undo of a change that replaced the extras (Restore Version) puts back both the earlier text and the earlier extras and saves them in one body write; Redo reapplies both.
  - Read-only surfaces, such as cheat sheets and previews, register as observers in `OpenEditorRegistry` with `registerObserver(_:for:)` (task 4.5) and mirror the updates.
  - Automation, capture-plus, linking, plugins, private-ai and sharing call it.
- **Many notes:** any change that touches more than one note (tag rename, link text update after a title change, plugin bulk update, Delete Tag) calls `editBody` with `.recordCurrent` for each note, so each gets a Version History entry first, and then offers Undo.
- **Body codecs:** wave 0 defines `enum BodyCodec { case rtfd, noteItDoc }` in the app target (task 4.2). Its per-format API (`read(at:) -> StoredBody`, `write(_:extras:to:)`, `data(of:extras:)`, `fileExtension`) is instance methods that switch over the case, with no `default:` branch. There is no codec registry. Markdown-storage adds `case markdown` in wave 1 by editing that enum and adding a branch to each switch; that branch calls `NoteItMarkdown` for the conversion. `StoredBody` holds the text and its `ContainerExtras`; `noteItDoc(of:extras:imagePolicy:)` and `attributedString(from:) -> StoredBody` carry them in and out of a container. `.rtfd` always reads `.empty` and ignores extras. `NoteStore` keeps each loaded body's extras by note ID (`bodyExtras`) and passes them on every body write, including sync apply, which writes the incoming container's extras and stores them in `bodyExtras[id]` only after the body and its sidecar are installed, so a failed apply leaves `bodyExtras[id]` as it was; sync's body encoding seals the container with them. Purging a note drops its entry. `bodyExtras[id]` is filled from disk on every body read, so the extras survive a relaunch. A `.noteitdoc` container holds both the extras and each code block's `language`. An `.rtfd` package holds no extras and keeps only known languages (as the code-language tab stop), so on an RTFD store `NoteStore` keeps them in a sidecar, `<rootURL>/body-extras/<UUID>.json` (task 4.1, §7):
  - Shape: `{"current": Entry, "previous": Entry?}`, where an Entry is `{"bodySHA256": String, "extras": ContainerExtras, "codeLanguageIDs": [String?]}`. `codeLanguageIDs` has one entry per code block in document order, taken from `noteItCodeLanguageID` at write time. `bodySHA256` is the SHA-256 of the `.rtfd` package the entry belongs to, computed over the package's files, so the same package on disk always gives the same hash.
  - **Two-phase write.** A body write of the note (1) writes the sidecar atomically (temp file, then rename) with `current` set to the new body's entry and `previous` set to the entry for the body now on disk: the sidecar entry whose hash matches that body, an empty entry with its hash when there is no sidecar, or none when there is no body or no entry matches; (2) installs the body; (3) rewrites the sidecar with `previous` removed, or deletes it when `current` is empty (no extras and no code block with an ID). When there is no sidecar and the new entry is empty, nothing is written. Empty new extras never delete the file before the body is installed. If step 1 fails, the whole body write fails: it throws, the body is untouched, and the editor keeps its unsaved text as for any failed save. A failed step 3 is only logged, because the file still reads correctly. The sidecar is deleted with the body when the note is purged, only after the purge is saved in `library.json` (§7).
  - Read with the `.rtfd` body. The entry whose `bodySHA256` matches the package is used; if neither matches (the `.rtfd` was changed outside `NoteStore`), `current` is used and the mismatch is logged. So a crash after step 1 reads the old body with its old extras, and a crash after step 2 reads the new body with the new extras. A missing sidecar means empty extras. A sidecar that exists but can't be read or decoded blocks writes to the note: the read sets `readOnlyReason` to `bodyExtrasUnreadable`, the note shows read-only like other read-only reasons, and nothing is deleted. The IDs are put back by position only when the note's code-block count equals the entry's count; otherwise they are dropped and logged.
  - `.noteItDoc` and Markdown bodies never use the sidecar.
- **Saving before a source is removed:** `NoteStore.persistNow(_ id: UUID) throws` (task 4.1) synchronously writes that note's pending body (on an RTFD store with its sidecar) and then the library metadata, and returns only after both are in place by atomic rename. It throws on any failure, and the note stays pending for the next save. A path that turns an outside source into a note (a share-inbox item, a screenshot file, a mail message) deletes, moves or marks that source only after `persistNow` returns; when it throws, the source stays so the capture can be retried.
- **Markdown:** Markdown in and out of notes goes through `NoteItMarkdown` (markdown-storage). It has two flavours:

  | Flavour | What it is | Used by |
  |---|---|---|
  | `library` | Lossless, with NoteIt comments | Markdown libraries, plugins |
  | `portable` | Clean Markdown | Local API and MCP reads (default), web clipper input |

  The Local API and MCP accept both flavours on write.
- **Images on import:** `NoteItMarkdown` takes `MarkdownImportOptions.resolveImage: (URL) async -> Data?` to fetch images. The web clipper and the importers use it.
- **Old paths:** the old `MarkdownWriter` and `MarkdownReader` remain only for the existing Export and Import menus and for parsing Markdown passed to `DailyLogAppender` (§5), until markdown-storage replaces them.

## 7. Derived indexes and per-Mac files

- **One hook:** organise's `DerivedIndex` registry (task 4.4) is the only hook. Each index implements:

  | Hook | Called when |
  |---|---|
  | `noteChanged(_ note: NoteMeta, body: NSAttributedString)` | a note's body changes or a note is created, and when Remove Lock unlocks a note for good |
  | `noteRemoved(_ noteID: UUID)` | a note is deleted for good, and when a note is locked |
  | `metadataChanged(_ note: NoteMeta)` | only metadata changes: a note is pinned, moved, re-tagged without a body change, moved to Recently Deleted or restored from it. These never call `noteChanged` |
  | `rebuild(notes: [NoteMeta], body: (UUID) -> NSAttributedString?) async` | the index is built from scratch |
  | `flush()` (synchronous) | pending index work must be written out, for example before quitting or switching stores |

  `noteChanged` is never called for a locked note. Locking a note calls `noteRemoved` on every index.
- **Who registers:** the link index (linking), image text (capture-plus), semantic index (private-ai), tasks and reminders (organise), and Spotlight (automation) each register an indexer. None of them edits `NoteStore.swift` to add a hook.
- **Register once, no unregister:** an index is registered once each time a store opens, and there is no way to unregister it. A feature the user can turn off keeps its index registered but dormant: its hooks do nothing while the feature is off, and when it is turned back on the index schedules its own rebuild.
- **Local note changes:** `NoteStore` posts a `localNoteChange` notification (added in task 4.5, with `editBody`) with `kind` set to `created`, `edited` or `deleted`. It is posted for local actions only, never for changes that arrive through sync. That includes the conflict copy sync creates through `createNote`: it passes `postsLocalChange: false`. Plugins build their `noteCreated`, `noteEdited` and `noteDeleted` events on it. It is the one extra hook allowed in `NoteStore`.
- **Search index:** organise owns the search index v2 format. Markdown-storage uses it as is.
- **Text in images:** organise defines `protocol ImageTextProviding { func imageText(for noteID: UUID) -> String? }` in wave 1, with no provider, and the registration point `NoteStore.registerImageTextProvider(_:)`. Capture-plus registers its provider in wave 2. Search shows "Found in an image" only when a provider is registered.
- **Where files live:** all derived and per-Mac files live in `NoteStore.rootURL` (the data folder), never in a Markdown library's content folder. Markdown-storage renames its own property to `contentRootURL`. Files:

  | File | Owner |
  |---|---|
  | `search-index.json` | organise |
  | `link-index.json` | linking |
  | `attachment-text.json` | capture-plus |
  | `mail-in-state.json` | capture-plus |
  | `capture-pending/` | capture-plus |
  | `semantic-index/` | private-ai |
  | `smart-folders.json` | organise |
  | `library-settings.json` | surfaces-polish |
  | `lock-keys.json` | sync-security |
  | `sync-meta-raw/<kind>/` (one subfolder per `RawMetaKind`; §4 rule 5) | foundations (task 3.5) |
  | `sync-meta-raw/notes/`, `sync-meta-raw/notebooks/` | foundations (task 3.5) |
  | `sync-meta-raw/smart-folders/` | organise |
  | `sync-meta-raw/boards/` | surfaces-polish |
  | `body-extras/<UUID>.json` (RTFD stores only; §6 body codecs) | foundations (task 4.1) |
  | `shares.json`, `spaces.json`, `sites/` | sharing |
  | `spaces/<id>/` (per-space state) | sharing |
  | `local-api.json` | automation |

- **Deleting per-note files:** purging a note (Delete Now, Empty Recently Deleted, the automatic purge, a remote deletion) deletes its files in the data folder (its raw meta, its body-extras sidecar, its Version History) only together with the body's move to `.trash`, after the library save that drops the note has succeeded and `library.json` no longer lists it. `NoteStore` queues them with the body in `pendingTrash`. A failed library save deletes nothing, so the note is still listed after a relaunch with all its files; a failed file delete is retried on the next save. Raw meta of every other kind follows the same rule: its file is deleted only after the save that removes the record from that kind's own file has succeeded (`queueRawMetaDeletion`, task 3.5).

## 8. Locked notes

- **Owner:** sync-security. Locked notes ship in its milestone M5, in wave 3, after web-app Tasks 0.4–0.5 bring `noteit-doc` (Delivery order). Markdown-storage's Milestone 10 adds them to Markdown libraries, conversion, backups and the restore drills in the same wave; before wave 3 there are no locked notes.
- **What stays visible:**
  - The title stays visible.
  - Lists, search results and the Local API show the note with `locked: true` and an empty preview. Search matches its title only.
  - The Local API returns `423 note_locked` for any body read or write.
  - MCP, plugins and smart features follow the same rule.
- **Inside the lock:**
  - The sealed content is always a `noteit-doc` body container.
  - The remote body is `bodyFormat: "noteit-locked/1"`, allowed only when the store has the `locked-notes` feature. Its path follows §4 rule 13. The conversion sweep skips it.
  - Local file: `notes/<uuid>.locked` in RTFD libraries and on the phone, `.noteit/locked/<uuid>.sealed` in Markdown libraries. Converting a library moves sealed files as they are.
- **Never lost by accident:**
  - The sealed file has a cleartext header with `keyID` and `sealedID`, and `lock` is rebuilt from that header if the metadata lost it.
  - On every platform, a sealed file is deleted only by Remove Lock or by permanently deleting the note (emptying Recently Deleted or the automatic purge).
- **Kept out of derived data:** locked notes are left out of every derived index (search body text, links, semantic index, image text, Spotlight, tasks and reminders). Locking a note calls `noteRemoved` on every index (§7). The lock sheet says that reminders in a locked note won't ring.
- **Version history:** locking a note deletes its earlier versions on this Mac after the lock sheet says so.
- **Backups:** backups include sealed files and `lock-keys.json`. Backup checks verify sealed files by hash and report "N locked notes (sealed, not opened)".
- **Settings:** the Locked Notes section is in the Sync tab, next to Encryption. Its text says that locking works without sync.
- **Shared notebooks and the phone:**
  - Notes in shared notebooks can't be locked. Locking one, or moving a locked note into a shared notebook, is refused with "Notes in shared notebooks can't be locked."
  - The phone shows locked notes as locked in its first releases.

## 9. Frozen tables

### Menu shortcuts

Existing defaults stay: ⌘N, ⇧⌘N, ⌘O, ⇧⌘P, ⌘F, ⌥⌘F, ⇧⌘F, ⇧⌘S, ⌘P, ⌥⇧⌘C, ⌥⌘Y, ⌘⌫.

| Command | Owner | Default | Menu |
|---|---|---|---|
| Copy Note Link | automation | ⌃⌘L | Edit |
| Lock Note | sync-security | none | Note group |
| Remove Lock | sync-security | none | Note group |
| Lock All Notes | sync-security | ⌥⌃⌘L | Note group |
| Pin / Unpin | surfaces-polish | ⌥⌘P | Note group |
| Open Today's Note | linking | ⌃⌘T | File |
| Daily Note for Date… | linking | none | File |
| New Note from Template… | linking | ⌥⌘N | File |
| Link to Note… | linking | ⇧⌘K | Format |
| Back / Forward | linking | ⌃⌘← / ⌃⌘→ | View |
| Links and Outline panel | linking | ⌥⌘I | View |
| Tasks | organise | ⇧⌘T | View |
| Set Due Date… | organise | ⇧⌘D | Format › Task |
| Add Reminder… | organise | ⌃⌘R | Format › Task |
| New Smart Folder… / Save Search as Smart Folder… | organise | none | File / Edit |
| Ask Your Notes… | private-ai | ⌥⌘A | Edit › Find |
| Create Share Link… | sharing | ⌥⌘L | File › Share |
| Zoom In / Zoom Out / Actual Size | surfaces-polish | ⌃⌘= / ⌃⌘- / ⌃⌘0 | View |

Each owner updates `MenuShortcutRules` and `docs/keyboard-shortcuts.md` in the task that adds the command. Wave 0 adds a test that fails if two default shortcuts are the same (task 6.1).

Palette-only commands, with no menu item: New Template (linking) and Compare Conflict (shown in the palette, the note's context menu and the conflict badge).

### Global hotkeys

All are unbound by default.

- **Persistence:** bindings are saved by raw value. Order never changes a saved binding.
- **Runtime ID:** a case's runtime `hotkeyID` is its index in `HotkeyOrder`, not its declaration order in `HotkeyAction`. The reverse lookup, `HotkeyAction.init?(hotkeyID:)`, resolves through `HotkeyOrder` too, so an ID whose table entry has no case yet gives nil.
- **`HotkeyOrder`** (task 6.2) lists all 14 raw values in the frozen order below. Each owner adds its `HotkeyAction` case at its frozen position, whatever order the plans merge in.
- **Same task:** each plan updates the `ShortcutsSettingsView` tile switch and the `AppDelegate` handler switch in the task that adds its case.
- **Tests** check that:
  - `HotkeyAction.allCases` is an in-order subsequence of `HotkeyOrder`;
  - raw values are unique;
  - the first six cases are unchanged;
  - `HotkeyAction(hotkeyID: a.hotkeyID) == a` for every case, and IDs in the table's gaps give nil;
  - no new case has a default binding.
- **Onboarding** suggests no default hotkey. Its hotkey step shows a recorder and a "Skip" button.

| Order | Case | Owner |
|---|---|---|
| 1–6 | `showMainWindow`, `newNote`, `quickCapture`, `openQuickly`, `commandPalette`, `captureSelection` | existing |
| 7 | `openToday` | linking |
| 8 | `showTasks` | organise |
| 9 | `screenshotToText` | capture-plus |
| 10 | `recordVoiceNote` | capture-plus |
| 11 | `appendToToday` | capture-plus |
| 12 | `askNotes` | private-ai |
| 13 | `cheatSheet` | surfaces-polish (adds key-release events to `HotkeyManager`) |
| 14 | `toggleFloatingNotes` | surfaces-polish |

### Settings tabs

| Order | Tab | Raw value | Symbol | Owner |
|---|---|---|---|---|
| 1 | General | `general` | existing | existing |
| 2 | Shortcuts | `shortcuts` | existing | existing |
| 3 | Editor | `editor` | existing | existing |
| 4 | Sync | `sync` | existing | existing; sync-security adds a Locked Notes section next to Encryption (§8) |
| 5 | Your Data | `data` | `externaldrive` | markdown-storage |
| 6 | Sharing | `sharing` | `person.2` | sharing |
| 7 | Smart Features | `smart` | `sparkles` | private-ai |
| 8 | Integrations | `integrations` | `point.3.connected.trianglepath.dotted` | automation (Local API, CLI, Spotlight, connected apps including MCP clients and the web clipper) |
| 9 | Plugins | `plugins` | `puzzlepiece.extension` | plugins |
| 10 | About | `about` | existing | existing |

`noteit://settings?tab=` accepts every raw value above.

`GeneralSettingsView` is a scrolling grouped `Form` from wave 0 (task 6.5). Its section order is a constant, `GeneralSettingsSection`: the existing sections (`appearance`, `startup`), then `capture`, `emailIn`, `reminders`, `cheatSheet`, `updates`. Capture-plus (`emailIn`), organise (`reminders`) and surfaces-polish (`cheatSheet`) each turn on their own section; none of them adds or moves a section.

### Menus

- **File:**
  - New Note, New Note from Template…, New Notebook, New Smart Folder…
  - Open Quickly, Command Palette… (existing, stays), Open Today's Note, Daily Note for Date…
  - **Capture ▸** submenu: Screenshot to Text, New Voice Note, Append to Today…
  - **Share ▸** submenu: Create Share Link… (⌥⌘L), Share Notebook…, Publish…, Join Shared Notebook…
  - Back Up Everything…, Show Note File in Finder
- **Edit:** Copy Note Link. Ask Your Notes… sits with Find.
- **Format:** Insert Template… and the Task submenu.
- **Note group:** the existing `RecentlyDeletedCommands` group is renamed `NoteCommands` (task 6.4). Order: Pin, Lock Note, Remove Lock, Lock All Notes, Version History, Delete.
- **Palette command IDs** stay camelCase, for example `backUpEverything`, `revealNoteFile`, `pairDevice`.

### Sidebar

1. Library rows: All Notes, Today, Tasks, Pinned, Recent, Conflicts (only when there are conflicts).
2. The Smart Folders section.
3. Notebooks (nested) and the tag tree.
4. Recently Deleted, in its own section at the bottom.

Wave 0 freezes this order as a constant (task 1.1) but doesn't reorder the visible sidebar. Each owner places its rows in this order when it adds them: linking adds Today, organise adds Tasks and the Smart Folders section, and surfaces-polish adds Pinned. Recently Deleted moves into its own bottom section when the first owner changes the sidebar (organise). Sharing adds badges to notebook rows. `SidebarSelection` has `.today`, `.tasks`, `.tag(path)` and `.smartFolder(UUID)` from wave 0 (§1).

### Inspector and shared editor UI

- Linking owns the main window's inspector (⌥⌘I, Links and Outline tabs).
- Plugin panels are extra inspector tabs.
- Board view opens a card's note in its own panel, which can show the same inspector.
- There is one inline completion popup, `InlineCompletionController`. Linking creates it for `[[` links; organise reuses it for tags and the query language.

## 10. Local API and integration rules

- **Ownership:** automation owns the Local API. Each sub-project registers its own routes through `LocalAPIRouteRegistry.register` with:
  - a route id `<slug>.<name>`;
  - an explicit scope;
  - errors from `APIErrorCode` only, in the nested error body.

  A "needs from 01" list is not enough; the owning plan has a task that registers the route.
- **Search modes:** `LocalAPIRouteRegistry.registerSearchMode(_:handler:)` adds search modes. Private-ai registers `meaning` and `hybrid`. Unknown modes return `400 bad_request`; a mode the user turned off returns `501 not_available`.
- **Capabilities:** `addCapability(_:)` advertises an optional capability on `GET /v1/ping` in a field named `capabilities` (not `features`, which belongs to the sync manifest), and `removeCapability(_:)` withdraws it, for example when the user turns a feature off. Both are idempotent. `/v1/ping` lists only the capabilities registered at the time of the request. Names are kebab-case, such as `meaning-search` or `web-clipper`.
- **Error codes** that other sub-projects rely on (automation owns the full list):

  | Code | HTTP | Meaning |
  |---|---|---|
  | `bad_request` | 400 | the request is malformed or names an unknown option |
  | `unauthorized` | 401 | the token is missing or unknown |
  | `read_only` | 403 | the note is in a shared notebook the user can only read |
  | `not_found` | 404 | the note, notebook or other resource doesn't exist |
  | `editor_required` | 409 | plugins only: needs an open editor |
  | `revision_mismatch` | 412 | conflicting revision |
  | `note_locked` | 423 | the note is locked |
  | `internal` | 500 | an unexpected error in NoteIt |
  | `not_implemented` | 501 | not built yet or not switched on by its owner: the daily routes while the daily gate is off (§5), `GET /v1/tags?tree=1` with no tree provider, and anything else not built into this version |
  | `not_available` | 501 | a search mode the user turned off (above) |
  | `not_ready` | 503 | "Your library is still opening. Try again in a moment." |

  In Swift these are `APIErrorCode` cases (the type is `String, Codable, Sendable, Error`, so it can be `Result`'s failure type and can be thrown), including `badRequest`, `readOnly`, `revisionMismatch`, `editorRequired`, `noteLocked`, `notImplemented`, `notAvailable` and `notReady`. Automation's other codes (`token_revoked`, `forbidden_scope`, `rate_limited` and the rest) stay as automation defines them.

- **Data shapes:**
  - `NoteSummaryDTO` has `locked`.
  - Search results have an optional `score` and optional `highlights`, a list of `HighlightDTO` values `{field, ranges: [[start, length]]}`. `field` is `"title"` or `"body"`. Each range is a `[start, length]` pair in UTF-16 offsets.
  - Tags and notebooks: automation exposes `LocalAPIRouteRegistry.extendTags(treeProvider:)` and `NotebookDTOExtending`. Organise uses them to fill `GET /v1/tags?tree=1` and the notebook fields `parentID` and `path`. Organise's provider builds each `TagNodeDTO`, including `totalCount`. Without a provider, `?tree=1` returns `501 not_implemented`. Plain `GET /v1/tags` stays a flat list.
  - The `Notebook` model field is `parent: UUID?` (added by organise); the API field is `parentID`.
  - Smart folders use `/v1/smart-folders` and `/v1/smart-folders/{id}`.
- **Routes:**
  - The only UI route is `POST /v1/notes/{id}/open`. Surfaces-polish uses `noteit://` actions instead of API routes for floating notes and cheat sheets.
  - Templates: linking registers `POST /v1/templates/{id}/notes` (`linking.createFromTemplate`). Automation's create-note route has no `templateID`.
  - `LocalAPIRouteRegistry` lives in `NoteItAPI`. `URLRouteRegistry` lives in the app target (§3).
- **Clients and tokens:**
  - Clients are managed in-process through `AutomationService.clients` (issue, list, revoke). `ClientKind.plugin` is removed; plugins never hold tokens.
  - Safari extension tokens are bound by the origin scheme plus the extension's bundle identifier, because Safari's extension origin changes between launches. The extension sends its bundle identifier in the `X-NoteIt-Extension-Bundle` header. This is written into the automation spec.
- **MCP:**
  - The `noteit mcp` command tree belongs to private-ai.
  - Keychain profile names match `mcp(-[a-z0-9]+)*`.
  - Private-ai builds the MCP setup sheet. Integrations opens it from "Set Up an AI App…".
- **Links that change notes:**
  - Links from other apps that change notes (`new`, `append`, and daily `append`) ask for confirmation, unless the user turns on "Allow links to change notes without asking" in Integrations. That setting is off by default. `URLCommand.changesNotes` is true for exactly these commands.
  - The share-inbox link the Share extension uses is exempt from confirmation.
  - Links that only open or show something don't ask: `open`, `note`, `search`, `daily` (open) and `settings`.
  - `x-callback-url` callbacks to `http` or `https` never receive a note id or title.
- **Embeds:** wave 0 adds an embeds table to `scripts/build_app.sh` (task 5.5) that lists every helper and appex. Columns:

  | Column | Meaning |
  |---|---|
  | path in bundle | the full bundle-relative path, always starting with `Contents/`, for example `Contents/Helpers/noteit` |
  | source | a built product or a script |
  | build step | optional script that builds it |
  | entitlements file | the file passed to `codesign` |

  Rows are signed inside-out, deepest path first, without `--deep`. A row whose source isn't built is skipped with a log line, for example the clipper when it wasn't built, or the Share extension in an ad-hoc build. The main app is not a row: it is signed last, with its own entitlements. Later plans only add rows: `Contents/Helpers/noteit`, `Contents/Helpers/NoteItPluginHost`, `Contents/PlugIns/NoteItClipper.appex` and `Contents/PlugIns/NoteItShare.appex`. A row string lists the columns in the order above, for example `"Contents/Helpers/noteit|NoteItCLI||"`.
- **Mac Share extension:** owned by automation. "Share → NoteIt" from any app saves text, links and images as a new note. It is built like the Safari extension.
  - It hands content to the app through an inbox folder in a shared app group.
  - An app group needs a Team ID, so ad-hoc builds skip the Share extension.
- **App Intents:** they depend on automation's spike (T19). If App Intents can't be built from SwiftPM:
  - Shortcuts uses documented `noteit://` links;
  - plugin commands still appear in the Plugins menu and the command palette; they are only missing from Shortcuts and the Local API.
- **Plugin helper:** runs without JIT in v1.

## 11. Data safety rules

- **Markdown library deletions:** NoteIt pauses and doesn't apply the deletions if, in one scan of a Markdown library, either of these is true:
  - more than 20 files were deleted;
  - at least 10% of the files were deleted, and that is at least 5 files.

  It shows "Many notes disappeared from the folder" and waits for the user. No tombstones are synced for that batch until the user confirms.
- **Adopted folders:** a folder adopted as a library keeps its file names. NoteIt doesn't rename files when titles change unless the user turns that on.
- **Wiki links in tables:** a wiki link inside a Markdown table cell escapes `|` as `\|`.
- **Previous library after conversion:** NoteIt never moves it to the Trash on its own. After 30 days it asks.
- **Rewriting many notes:** any operation that rewrites more than one note follows §6 (version first, then Undo).
- **Text in images:** finding text in images already in the library is off by default. After the first Screenshot to Text, NoteIt offers to turn it on.
- **Spotlight:** stays on by default. It's local to the Mac and can be turned off in Integrations.
- **Pairing a phone:** the QR code alone isn't enough.
  - The Mac shows an 8-character code (Crockford base32, about 40 bits) and the phone asks for it.
  - The QR code is encrypted with a key derived from that code with PBKDF2-SHA256, 600,000 iterations.
  - The QR code and the code expire after 10 minutes or after one use.

## 12. Things each sub-project now owns

| Item | Owner |
|---|---|
| Checklist polish: move checked items to the bottom, ⌘↩ to toggle, drag to reorder, nested indent. The per-note "checked to bottom" setting is a synced `NoteMeta` field, in the revision fields only when set (§4 rule 5) | surfaces-polish |
| Onboarding asks "New to NoteIt / I use NoteIt on another Mac"; the second path sets up sync first and skips import | surfaces-polish |
| Offering the Evernote and Notion importers in onboarding | surfaces-polish (importers by markdown-storage) |
| Choosing Markdown storage: only from Your Data, not in onboarding | markdown-storage |
| Benchmarks: every suite (links, semantic search and the rest) uses the shared `NOTEIT_BENCH_FIXTURE`. No sub-project adds its own bench library | surfaces-polish (metrics defined by linking and private-ai) |
| `CaptureTitleRefining` protocol | capture-plus (private-ai provides a model-based implementation) |
| Board layouts, stored as `boards/<notebookID>.json` records (§4 rule 14) | surfaces-polish |
| Nested notebooks as nested folders, up to 4 deep, in Markdown libraries; `.noteit-notebook.json` stores the whole notebook record except the name, keeping unknown keys. Board layouts are not in it | markdown-storage |
| Wiki-link syntax on disk in Markdown libraries (`[[file name\|text]]`) | markdown-storage (resolution rules from linking) |
| Rules for new notebook fields when older apps drop them | foundations (§4 rule 5) |
| Recently Deleted on the Mac already exists. The web-app spec's §15 statement that the Mac has no trash is outdated and gets fixed | web-app |
| The Homebrew cask `binary` line for the CLI | growth (CLI from automation) |
| `docs/network.md`, including future rows: Local API listener, IMAP, plugin directory, sharing uploads, web clipper image downloads, speech model download | sync-security |
| The WebDAV `atomicConditionalWrites()` and `atomicConditionalDelete()` capability methods on `StorageBackend`, and every backend's baseline answer to them | sync-security (wave 2). web-app Task 0.4 (wave 3) only uses them |
| Linking to `docs/network.md` from the site. Until the page exists, the site states the short no-telemetry text | growth |
| Address-pinned HTTP client (`PinnedHTTPClient` in `Sources/NoteIt/Net/`, `NoteIt` app target): resolve once, public-address check, connect to the checked IP with TLS to the original host. Used for web clipper images and plugin `net.fetch` | web-clipper (wave 2); plugins uses it |
| The `noteit-plugins` directory repository, its contribution guide, index format and CI check, and the website's `/plugins/` page | plugins (site rules from growth) |

## 13. Writing rules for every spec and plan

- Plain English, concise.
- No local machine paths, no emojis.
- Wording mentions no tools or people that helped write the docs.
- User-facing names are plain: "Ask Your Notes", "Smart Features", "Locked Notes".
- Spec sections: Goal; What the user gets; Design; Dependencies; Non-goals; Open questions.
- Plans: Goal, Architecture, Tech stack, Spec link, Conventions, File structure, Frozen interfaces, Tasks with verification, Self-review, and milestones that ship on their own.
