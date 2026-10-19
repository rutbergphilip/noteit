# NoteIt Surfaces and Polish Implementation Plan

**Goal:** Add three new surfaces for notes (a hold-to-show cheat sheet, always-on-top floating notes, and a board view per notebook), plus:
- display-only typography controls;
- checklist polish (⌘↩ to toggle, nesting, drag to reorder, checked items to the bottom, checked style);
- a first-run guide with a "new to NoteIt" path and an "I use NoteIt on another Mac" path;
- a VoiceOver pass with automated checks;
- an in-app benchmark suite with published numbers, including link and meaning-search numbers;
- polish for Quick Capture motion, pinning and the sync status.

**Architecture:** Most of the work sits in the app target, `Sources/NoteIt`. The exceptions follow the program's target graph: `BoardLayout`, `BoardPosition` and `NoteMeta.checkedItemsToBottom` live in `NoteItCore`; the board record kind and the unsynced count live in `NoteItSync`.
- Per-library, never-synced state (typography, cheat sheets, floats, board flags and zoom) lives in a new `library-settings.json` in `NoteStore.rootURL`. It's reached only through `NoteStore`.
- Board card positions are their own last-writer-wins record kind, `boards/<notebookID>.json`, registered in `RemoteLayout` (program §4 rules 6 and 14). They have no tombstones and are deleted with their notebook. They're stored locally in `rootURL/boards/` and never touch the notebook record. Their raw meta is foundations' `boards` raw-meta kind (`sync-meta-raw/boards/`, foundations Task 3.5 per-kind contract).
- The new panels follow the existing `NSPanel` patterns in `MenuBar/QuickCapturePanel.swift` and `Capture/CaptureToast.swift`, and register with `TransientSurfaceHider`.
- Floating notes and the board's note pane register their text views as editors with foundations' `OpenEditorRegistry`, so `NoteStore.editBody` reaches them (program §6). The cheat sheet is read-only and registers as an observer through foundations' `registerObserver(_:for:)` (task 4.5); it mirrors updates and is never edited.
- Floating notes and cheat sheets are reachable from other apps through `noteit://float` and `noteit://cheat-sheet`, registered with foundations' `URLRouteRegistry` (task 5.4). There are no Local API routes for them (program §10).
- Typography is applied at display time, like `CodeStyler`, and never saved into RTFD.
- Checklist edits run as text-view edits (`shouldChangeText`/`didChangeText`), so undo, saving, version history and sync behave as they do for typing.
- Benchmarks run inside the app under `NOTEIT_BENCH`, because SwiftPM can't link the executable target from another executable. One shared fixture (`NOTEIT_BENCH_FIXTURE`) serves every suite, including linking's and private-ai's metrics.
- Each feature keeps its logic in a pure, unit-tested type: `TypographySettings`, `CheatSheetHoldLogic`, `BoardGeometry`, `ChecklistOutline`, `QuickCaptureMotion`, `EditorRotorIndex`, `NoteAccessibility`, `BenchStats` and `OnboardingFlow`. The UI wiring stays thin.

**Tech Stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftPM, SwiftUI and AppKit (`NSPanel`, `NSLayoutManagerDelegate`, `NSAccessibilityCustomRotor`), Carbon hotkeys. One Python 3 script for the report table, like `scripts/make_appcast.py`. No new dependencies. Tests use XCTest via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. CI runs macos-15.

**Spec:** `docs/specs/2026-10-19-surfaces-polish-design.md`. The program contract is `docs/specs/2026-10-19-program-design.md`; where they differ, the program wins.

**Wave:** 2. Foundations (wave 0) and automation, markdown-storage, linking and organise (wave 1) have shipped before this plan starts. Private-ai runs in the same wave; only T15b depends on it.

---

## Conventions for every task

- Test command (run from the repository root): `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite> 2>&1 | tail -20`. Expect `Executed N tests, with 0 failures`.
- "Both builds" means the two app builds, debug and release: `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, run from the repository root. Each must end with `Build complete!`, with 0 errors and exit 0. There is no other target to build for this plan.
- Never touch real user data in `~/Library/Application Support/NoteIt`. When running the app, set `NOTEIT_DATA_DIR=<project>/.selftest/<name>` (already gitignored). Benchmarks use `.bench/` (gitignored in Task 15).
- Tests create stores with `NoteStore(location: LibraryLocation(url: <temp dir>, seedsFreshLibrary: false))`, as the existing tests do.
- **Global hotkeys (program §9):** `HotkeyAction` cases appear in the frozen table order, whatever order plans merge in. This plan owns `cheatSheet` (13) and `toggleFloatingNotes` (14): `cheatSheet` goes after every case from positions 1–12 that exists and before `toggleFloatingNotes`; `toggleFloatingNotes` goes last. The task that adds a case also adds its `ShortcutsSettingsView` tile and its `AppDelegate` handler. Saved bindings are keyed by raw value (`HotkeyManager.encode`), and `hotkeyID` is only used at runtime, so a case inserted at its table position never breaks saved bindings. Tests follow the program: raw values are unique, the first six cases are unchanged, and no new case has a default binding.
- Every new menu shortcut is a `MenuShortcutCommand` case with a `MenuShortcuts` accessor, uses the default from the program's frozen menu table, and is added to `MenuShortcutRules` and `docs/keyboard-shortcuts.md` in the same task. Foundations' test fails if two default shortcuts are the same.
- Every new command is added to `PaletteCommandRegistry`.
- New remote prefixes are a `RemotePrefix` row in `RemoteLayout.prefixes` with key vectors in `fixtures/golden/layout-keys.json` (program §4.6, foundations task 3.5). Records keep unknown keys through `RawMetaOverlay` (program §4.5).
- Per-Mac and derived files go in `NoteStore.rootURL`, never in a Markdown library's content folder (program §7).
- Code outside the editor changes note text only through `NoteStore.editBody` (program §6). Editor-originated edits (checklist moves, ⌘↩) go through the text view.
- Commit after each task using Conventional Commits, e.g. `feat(board): add board geometry`. Never amend, rebase or force.
- No `#Preview`. Comments only where something is non-obvious.
- Each milestone ends with its docs updated, so it can ship by itself.

## File structure

```
Sources/NoteItCore/
  BoardLayout.swift                        new: BoardLayout, BoardPosition
  Models/NoteMeta.swift                    modify: checkedItemsToBottom (revision fields only when non-nil; file from foundations)
  Models/CodingKeyNames.swift              modify: NoteMeta.ownedCodingKeys gains "checkedItemsToBottom"; BoardLayout.ownedCodingKeys (file from foundations 3.5)
Sources/NoteItSync/
  Model/SyncTypes.swift                    modify: RecordKind.board (usesLastWriterWins)
  Model/SyncState.swift                    modify: boardBases, unsyncedCount(local:deletions:)
  Engine/RemoteLayout.swift                modify: register boards/ prefix, board(_:) key
  Engine/SyncEngine.swift                  modify: board records (bases by kind, no tombstones, orphan cleanup), unsyncedCount()
Sources/NoteIt/
  Model/LibrarySettings.swift              new: LibrarySettings, TypographySettings, CheatSheetAssignments, FloatingNoteState
  Model/NoteStore+LibrarySettings.swift    new: load/save rootURL/library-settings.json, updateLibrarySettings, pruning
  Model/NoteStore.swift                    modify: load hooks, didSeedThisLaunch, removeUnchangedSeedNotes, setCheckedItemsToBottom, board cleanup on notebook delete
  Model/NoteStore+Board.swift              new: boards in rootURL/boards/ (BoardFile with its applied revision), setBoardPositions(_:in:), arrangeBoard(in:)
  Model/NoteStore+RawMeta.swift            modify: RawMetaKind.boards and its two switch arms (file from foundations 3.5)
  Sync/NoteStoreSyncAdapter.swift          modify: export/apply/delete board records
  Editor/TypographyStyler.swift            new: font-family swap, line-spacing delegate, persisted(_:)
  Editor/ChecklistOutline.swift            new: items, subtrees, indent rule, checked-to-bottom order, move edits
  Editor/NoteItTextView+Checklist.swift    new: ⌘↩, nesting, sort, drag handle tracking, Move Item Up/Down
  Editor/EditorStyles.swift                modify: maxReadingWidth from typography, maxListLevel
  Editor/FormatCommand.swift               modify: ⌘↩ KeyShortcut for toggleCheckbox, moveItemUp/Down
  Editor/TextFormatter.swift               modify: checked style on every check path, nested indent rules
  Editor/NoteItTextView.swift              modify: styler hookup, persisted form, isEditable checks for checkbox clicks and drops, rotors and actions, grip and drop line drawing (NoteItLayoutManager)
  Editor/RichTextEditor.swift              modify: scroll view magnification for zoom, EditorRole (main, floating, boardPane, cheatSheet)
  Accessibility/NoteAccessibility.swift    new: label and announcement builders
  Accessibility/EditorRotorIndex.swift     new: headings / checklist / code / link index
  Surfaces/CheatSheetHoldLogic.swift       new: pure hold/tap/toggle state machine
  Surfaces/CheatSheetController.swift      new: lookup, show/hide, monitors, registry or mirror
  Surfaces/CheatSheetPanel.swift           new: non-activating read-only panel
  Surfaces/CheatSheetAppPicker.swift       new: running-apps sheet + Other App…
  Surfaces/FloatingNotesController.swift   new: open/close/restore/toggle, limit
  Surfaces/FloatingNotePanel.swift         new: utility panel hosting RichTextEditor
  Surfaces/FloatingNotePlaceholder.swift   new: main-window placeholder view
  Surfaces/SurfaceURLRoutes.swift          new: noteit://float and noteit://cheat-sheet handlers
  Board/BoardGeometry.swift                new: placement, snapping, culling, zoom clamp, pruning, neighbours
  Board/BoardView.swift                    new: zoomable canvas
  Board/BoardNotePane.swift                new: the board's note pane, hosts linking's LinksPanelView on ⌥⌘I
  Board/BoardCardView.swift                new: card
  Onboarding/OnboardingFlow.swift          new: paths, steps, shouldShow, hotkey rows (no default combos)
  Onboarding/OnboardingModel.swift         new: page state, hotkey apply, import continuation, sync wait
  Onboarding/OnboardingView.swift          new: Window content and pages
  Bench/BenchStats.swift                   new: median/p95 and result types
  Bench/BenchFixture.swift                 new: deterministic library generator (shared fixture)
  Bench/BenchRunner.swift                  new: NOTEIT_BENCH suites
  Bench/BenchSuites+Links.swift            new: links suite
  Bench/BenchSuites+Semantic.swift         new: semantic suite
  MenuBar/QuickCaptureMotion.swift         new: pure frame math
  MenuBar/QuickCapturePanel.swift          modify: use QuickCaptureMotion, glyph pulse
  App/SurfaceCommands.swift                new: Window menu (Float Note, Show/Hide Floating Notes), View (zoom, board), Help (Welcome)
  App/NoteItApp.swift                      modify: welcome Window scene, SurfaceCommands, MenuBarGlyph pulse
  App/AppDelegate.swift                    modify: hotkey press/release routing, bench entry, float restore, onboarding trigger, URL routes
  App/MenuShortcuts.swift                  modify: togglePin, zoomIn, zoomOut, actualSize
  App/MenuShortcutRules.swift              modify: new defaults
  App/NoteCommands.swift                   modify: Pin Note first in the group (renamed in foundations task 6.4)
  App/WindowRouter.swift                   modify: welcomeWindowID, showWelcome()
  Hotkeys/HotkeyAction.swift               modify: cheatSheet (13), toggleFloatingNotes (14)
  Hotkeys/HotkeyManager.swift              modify: kEventHotKeyReleased, releaseHandler
  Palette/PaletteController+Global.swift   modify: TransientSurfaceHider.Surface.cheatSheet
  Palette/PalettePanel.swift               modify: previousApp
  Palette/PaletteCommandRegistry.swift     modify: new commands
  Palette/PaletteModel.swift               modify: result-count announcement hook
  Import/ImportSheet.swift                 modify: ImportSheetPresenter.show(continuing:)
  Settings/Preferences.swift               modify: PrefKey.cheatSheetMode, onboardingCompletedVersion
  Settings/EditorSettingsView.swift        modify: Font, Zoom, Line spacing, Text width
  Settings/GeneralSettingsView.swift       modify: Cheat Sheet section (GeneralSettingsSection.cheatSheet)
  Settings/GeneralSettingsSection.swift    modify: cheatSheet isAvailable turned on (the case is frozen in foundations task 6.5)
  Settings/ShortcutsSettingsView.swift     modify: tiles for new actions
  Design/Tokens.swift                      modify: tileCheatSheet, tileFloatingNotes, board, checklist and motion tokens
  Views/MainView.swift                     modify: Board mode layout
  Views/NoteListView.swift                 modify: Pinned/Notes sections, swipe, labels, List|Board control
  Views/SidebarView.swift                  modify: labels, rotors (Pinned row stays in program order)
  Views/EditorContainerView.swift          modify: floating placeholder, header ⋯ menu (Float, Use as Cheat Sheet, Keep Checked Items at Bottom)
  Views/SyncStatusView.swift               modify: pill opens popover, MenuBarSyncRow count
  Views/SyncStatusPopover.swift            new
  Sync/SyncController.swift                modify: unsyncedCount
Tests/NoteItTests/
  LibrarySettingsTests.swift  TypographyStylerTests.swift  PinningTests.swift  QuickCaptureMotionTests.swift
  HotkeyActionTests.swift (create if no earlier plan has)  CheatSheetTests.swift  FloatingNotesTests.swift  SurfaceURLRouteTests.swift
  BoardGeometryTests.swift  BoardStoreTests.swift  ChecklistOutlineTests.swift  ChecklistEditingTests.swift  ChecklistFieldSyncTests.swift
  BoardRawMetaTests.swift
  OnboardingFlowTests.swift  NoteAccessibilityTests.swift  EditorRotorIndexTests.swift  AccessibilityAuditTests.swift
  BenchStatsTests.swift  BenchFixtureTests.swift  MenuShortcutStoreTests.swift (modify)  PaletteCommandRegistryTests.swift (modify)
Tests/NoteItSyncTests/
  UnsyncedCountTests.swift  BoardSyncTests.swift  RemoteLayoutTests.swift (modify, from foundations)
Tests/NoteItCoreTests/
  NoteMetaChecklistFieldTests.swift
fixtures/golden/layout-keys.json          modify: inkwell/v1/boards/<UUID>.json key cases and the boards/ list prefix
scripts/bench.sh                           new
scripts/bench_report.py                    new
.gitignore                                 modify: .bench/
docs/performance.md  docs/accessibility.md new
docs/architecture.md  docs/development.md  docs/keyboard-shortcuts.md  docs/known-limitations.md  docs/roadmap.md  README.md   modify
```

## Frozen interfaces

```swift
// Model/LibrarySettings.swift
struct LibrarySettings: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "library-settings.json"   // in NoteStore.rootURL
    var version: Int = currentVersion
    var typography = TypographySettings()
    var cheatSheets = CheatSheetAssignments()
    var floatingNotes: [FloatingNoteState] = []
    var boardNotebookIDs: Set<UUID> = []
    var boardZoom: [String: Double] = [:]          // notebook uuidString → 0.5...2.0
    init()
    init(from decoder: Decoder) throws              // decodeIfPresent for every key
    func clamped() -> LibrarySettings
    func pruned(liveNoteIDs: Set<UUID>, notebookIDs: Set<UUID>) -> LibrarySettings
}

enum TextWidth: String, Codable, CaseIterable { case narrow, medium, wide, full
    var points: CGFloat { get }                     // 560, 720, 900, Tokens.Size.readingMax (1100)
    var title: String { get }
}
enum BodyFontFamily: String, Codable, CaseIterable { case system, serif, rounded
    var title: String { get }
    var design: NSFontDescriptor.SystemDesign { get }
}
struct TypographySettings: Codable, Equatable {
    static let lineSpacingRange: ClosedRange<Double> = 1.0...1.8
    static let zoomRange: ClosedRange<Double> = 0.9...1.5
    var lineSpacing: Double = 1.0
    var width: TextWidth = .full
    var fontFamily: BodyFontFamily = .system
    var zoom: Double = 1.0
    func clamped() -> TypographySettings
}
struct CheatSheetAssignments: Codable, Equatable {
    var global: UUID?
    var perApp: [String: UUID] = [:]                // bundle ID → note ID
    func noteID(forBundleID bundleID: String?) -> UUID?
}
struct FloatingNoteState: Codable, Equatable, Identifiable {
    var noteID: UUID
    var frame: CGRect
    var opacity: Double = 1.0                       // 0.4...1.0
    var isVisible: Bool = true
    var id: UUID { noteID }
    func fitted(toVisibleFrames frames: [CGRect], main: CGRect) -> FloatingNoteState
}

// Model/NoteStore+LibrarySettings.swift
extension Notification.Name { static let noteItLibrarySettingsChanged: Notification.Name }
extension NoteStore {
    var librarySettings: LibrarySettings { get }   // backed by @Published private(set) var in NoteStore
    func updateLibrarySettings(_ change: (inout LibrarySettings) -> Void)
}
// NoteStore.swift
private(set) var didSeedThisLaunch: Bool
func removeUnchangedSeedNotes()                     // onboarding .otherMac path; no Recently Deleted, no tombstones
func setCheckedItemsToBottom(_ on: Bool, for noteID: UUID)   // metadata only; new note revision

// NoteItCore/BoardLayout.swift
public struct BoardPosition: Codable, Hashable, Sendable { public var x: Double; public var y: Double }
public struct BoardLayout: Codable, Hashable, Sendable {
    public var version: Int = 1
    public var notebookID: UUID
    public var revision: String
    public var modifiedAt: Date
    public var positions: [String: BoardPosition]  // note uuidString → position at 100% zoom
}
// NoteItCore/Models/CodingKeyNames.swift: the keys this build writes, for RawMetaOverlay (ModelCodingTests checks it)
extension BoardLayout { public static let ownedCodingKeys: Set<String> }
// NoteItCore NoteMeta gains:  public var checkedItemsToBottom: Bool? = nil   // in revision fields only when non-nil
// NoteMeta.ownedCodingKeys gains "checkedItemsToBottom", so RawMetaOverlay takes it from the local meta (a cleared value is removed)

// NoteItSync
extension RecordKind { /* case board; usesLastWriterWins == true; hasBody == false */ }
extension RemoteLayout {
    public static let boardsPrefix = root + "boards/"   // registered in the prefix registry, sealed
    public static func board(_ notebookID: UUID) -> String   // "inkwell/v1/boards/<UUID>.json"
}
public struct SyncState { /* existing */ public var boardBases: [UUID: Base] }   // decodeIfPresent, default [:]

// Model/NoteStore+Board.swift
// The local file rootURL/boards/<notebookID>.json. appliedRemoteRevision is the boards kind's applied-revision entry
// (foundations Task 3.5 contract, item 2): local only, never synced, written in the same atomic write as the layout.
// Each board is its own file, so the kind's map is the set of these entries, keyed by notebook ID; nil (omitted)
// for a board never applied from remote.
struct BoardFile: Codable { var layout: BoardLayout; var appliedRemoteRevision: UUID? }
// Model/NoteStore+RawMeta.swift (foundations 3.5) gains one case; folder sync-meta-raw/boards/ (program §7 row).
//   appliedRemoteRevision(for:kind:) reads BoardFile.appliedRemoteRevision; isDurablyListed(_:kind:) is true while
//   the board's file exists on disk (the last successful write).
// enum RawMetaKind { case notes, notebooks, boards }
extension NoteStore {
    var boards: [UUID: BoardLayout] { get }        // notebook ID → layout, from rootURL/boards/
    func setBoardPositions(_ positions: [UUID: BoardPosition], in notebookID: UUID)  // new board revision + modifiedAt only
    func arrangeBoard(in notebookID: UUID)
}

// Board/BoardGeometry.swift
enum BoardGeometry {
    static let cardSize = CGSize(width: 220, height: 140)
    static let gap: CGFloat = 24
    static let snapStep: CGFloat = 8
    static let moveStep: CGFloat = 64
    static let zoomRange: ClosedRange<Double> = 0.5...2.0
    static let maxCards = 2_000
    static func placements(for noteIDs: [UUID], stored: BoardLayout?, columns: Int) -> [UUID: CGPoint]
    static func gridArrangement(for noteIDs: [UUID], columns: Int) -> [UUID: CGPoint]
    static func snap(_ point: CGPoint) -> CGPoint
    static func visible(_ placements: [UUID: CGPoint], in rect: CGRect) -> [UUID]
    static func neighbour(of id: UUID, direction: MoveDirection, in placements: [UUID: CGPoint]) -> UUID?
    static func readingOrder(_ placements: [UUID: CGPoint]) -> [UUID]
    static func pruned(_ positions: [String: BoardPosition], keeping ids: Set<UUID>) -> [String: BoardPosition]
    static func clampZoom(_ zoom: Double) -> Double
    enum MoveDirection { case left, right, up, down }
}

// Hotkeys (frozen table order, program §9)
enum HotkeyAction { /* 1–12 … */ case cheatSheet /* 13 */, toggleFloatingNotes /* 14 */ }
final class HotkeyManager { var releaseHandler: ((HotkeyAction) -> Void)? }

// Surfaces/CheatSheetHoldLogic.swift
enum CheatSheetMode: String, CaseIterable { case hold, toggle }   // PrefKey.cheatSheetMode, default .hold
struct CheatSheetHoldLogic {
    static let tapThreshold: TimeInterval = 0.3
    enum Effect: Equatable { case show, hide, none }
    private(set) var isVisible = false
    mutating func press(at time: TimeInterval, mode: CheatSheetMode) -> Effect
    mutating func release(at time: TimeInterval, mode: CheatSheetMode) -> Effect
    mutating func dismissed()
}
// Surfaces/CheatSheetController.swift
@MainActor final class CheatSheetController {
    static let shared: CheatSheetController
    func hotkeyPressed()
    func hotkeyReleased()
    func toggle(forBundleID bundleID: String?)
    func dismiss()
}

// Surfaces/FloatingNotesController.swift
@MainActor final class FloatingNotesController: ObservableObject {
    static let shared: FloatingNotesController
    static let maxWindows = 10
    @Published private(set) var floatingNoteIDs: Set<UUID>
    func float(_ noteID: UUID) -> Bool               // false at the limit or for a locked/deleted note
    func returnToMain(_ noteID: UUID)
    func close(_ noteID: UUID)
    func toggleAll()
    func restore(from store: NoteStore)
    func isFloating(_ noteID: UUID) -> Bool
}

// Surfaces/SurfaceURLRoutes.swift
@MainActor enum SurfaceURLRoutes {
    static func register(in registry: URLRouteRegistry)   // hosts "float" and "cheat-sheet"
}

// Editor/RichTextEditor.swift
enum EditorRole { case main, floating, boardPane, cheatSheet }  // cheatSheet: isEditable = false, observes and never registers as an editor
// Editor/NoteItTextView.swift: checkbox clicks, grip handles and drops do nothing when isEditable is false

// Editor/OpenEditorRegistry.swift (foundations task 4.5; used here, not changed)
//   registerObserver(_:for:) and removeObserver(_:): read-only surfaces (program §6). Never returned by textView(for:),
//   never edited by editBody. Called after the registered editor processes an edit, and after editBody's closed path or
//   a sync update saves the note.

// Settings/GeneralSettingsSection.swift (foundations task 6.5)
// case cheatSheet is frozen between reminders and updates; this plan turns its isAvailable on

// Editor/TypographyStyler.swift
extension NSAttributedString.Key { static let typographyOriginalFont: NSAttributedString.Key }
@MainActor final class TypographyStyler: NSObject, NSLayoutManagerDelegate {
    init(textView: NoteItTextView)
    var settings: TypographySettings { get set }
    func restyle(range: NSRange?)                   // nil = whole storage
    static func displayFont(for font: NSFont, family: BodyFontFamily) -> NSFont?   // nil = leave alone
    static func extraLineSpacing(multiple: Double, lineHeight: CGFloat, isCode: Bool) -> CGFloat
    static func persisted(_ string: NSAttributedString) -> NSAttributedString
}

// Editor/ChecklistOutline.swift
struct ChecklistOutline: Equatable {
    static let maxLevel = 5                         // 6 levels, 0-based
    struct Item: Equatable {
        var paragraph: NSRange; var level: Int; var kind: ListKind; var checked: Bool
        var parent: Int?                            // index into items
    }
    var items: [Item]
    init(_ string: NSAttributedString)
    func subtreeRange(of index: Int) -> NSRange      // the item plus its nested items
    func canIndent(_ index: Int) -> Bool             // at most one level deeper than the item above, ≤ maxLevel
    func checkedToBottomOrder() -> [Int]?            // nil when already in order; stable, per list and level
    func placementAfterToggle(of index: Int) -> Int? // target index when checkedItemsToBottom is on
    func move(_ index: Int, before target: Int?, level: Int) -> ChecklistMove?
    struct ChecklistMove: Equatable { var replaced: NSRange; var newLevelBySource: [Int: Int]; var order: [Int] }
}

// MenuBar/QuickCaptureMotion.swift
struct QuickCaptureMotion {
    struct Keyframe: Equatable { var frame: NSRect; var alpha: CGFloat }
    static let showDuration: TimeInterval = 0.18
    static let saveDuration: TimeInterval = 0.22
    static let discardDuration: TimeInterval = 0.12
    static let pulseDuration: TimeInterval = 0.4
    var reduceMotion: Bool
    func showStart(final: NSRect) -> Keyframe
    func saveEnd(from frame: NSRect, toward target: NSRect?, screenFrame: NSRect) -> Keyframe
    func discardEnd(from frame: NSRect) -> Keyframe
}

// Accessibility
enum NoteAccessibility {
    static func rowLabel(_ note: NoteMeta, notebookName: String?, now: Date) -> String
    static func sidebarLabel(title: String, count: Int) -> String
    static func cardLabel(_ note: NoteMeta, now: Date) -> String
    static func resultsAnnouncement(count: Int) -> String
}
struct EditorRotorIndex: Equatable {
    enum Kind: CaseIterable { case heading, checklistItem, codeBlock, link }
    struct Entry: Equatable { var kind: Kind; var range: NSRange; var label: String }
    var entries: [Entry]
    init(_ string: NSAttributedString)
    func entries(of kind: Kind) -> [Entry]
}

// Onboarding/OnboardingFlow.swift
enum OnboardingPath: String { case newUser, otherMac }
enum OnboardingStep: Int, CaseIterable { case welcome, syncFirst, hotkeys, menuBar, bringNotes, anotherMac, done }
enum OnboardingFlow {
    static let currentVersion = 1
    static func shouldShow(completedVersion: Int, librarySeededThisLaunch: Bool, forced: Bool) -> Bool
    static func steps(for path: OnboardingPath?) -> [OnboardingStep]   // nil = only .welcome
    static let hotkeyRows: [HotkeyAction]          // quickCapture, showMainWindow, commandPalette; no default combos (program §9)
    static func importSources(available: [ImportSource]) -> [ImportSource]   // appleNotes, then evernote and notion when present
}

// Bench
enum BenchSuite: String, CaseIterable { case launch, openNote, search, palette, links, semantic }
struct BenchStats: Codable, Equatable {
    var samples: [Double]; var median: Double; var p95: Double; var min: Double; var max: Double
    init(samples: [Double])                         // nearest-rank p95; empty → all zero
}
struct BenchResult: Codable, Equatable {
    var suite: String; var metric: String; var machine: String; var chip: String; var osVersion: String
    var appVersion: String; var commit: String; var noteCount: Int; var date: Date
    var stats: BenchStats?; var skippedReason: String?
}
struct BenchFixtureSpec: Equatable {
    var noteCount: Int; var notebooks = 20; var linksPerNote = 5; var hubBacklinks = 500; var longNoteParagraphs = 5_000
}
enum BenchFixture { static func populate(_ store: NoteStore, spec: BenchFixtureSpec, seed: UInt64) }
@MainActor enum BenchRunner { static func runIfRequested(environment: [String: String]) -> Bool }

// NoteItSync
extension SyncState {
    public func unsyncedCount(local: [LocalRecord], deletions: [UUID: LocalDeletion]) -> Int
}
extension SyncEngine { public func unsyncedCount() async throws -> Int }
// SyncController
@Published private(set) var unsyncedCount: Int?
```

## Tasks

Milestones and dependencies:
- **M1 Foundations and polish:** T1 → T2. T3, T4 and T5 have no dependencies and can run in parallel with T1.
- **M2 Floating surfaces:** T6 (no dependencies) → T7 and T8 (both need T1 and T6; T7 and T8 can run in parallel).
- **M3 Board:** T9 (needs T1) → T10 (needs T9; needs T8 for Float Note in the context menu and for the floating placeholder, otherwise it omits them and adds them later).
- **M4 Onboarding:** T11 (needs T6 so the hotkey page can bind; can start any time after T6) → T11a (needs markdown-storage's Evernote and Notion importers).
- **M5 Accessibility:** T12 (no dependencies) → T13 (best after M1–M4 and M7, so the audit covers their views).
- **M6 Benchmarks:** T14 (no dependencies) → T15 → T15a (needs linking) and T15b (needs private-ai), which can run in parallel.
- **M7 Checklists:** T16 (no dependencies) → T17 and T18 (both need T16; they can run in parallel) → T18a.

### Milestone 1: Foundations and polish

### Task 1: Library settings file
**Files:**
- Create:
  - `Sources/NoteIt/Model/LibrarySettings.swift`
  - `Sources/NoteIt/Model/NoteStore+LibrarySettings.swift`
  - `Tests/NoteItTests/LibrarySettingsTests.swift`
- Modify: `Sources/NoteIt/Model/NoteStore.swift`

Steps:
- [ ] Write the frozen types.
  - `init(from:)` uses `decodeIfPresent` for every key.
  - `clamped()` clamps typography, opacity (0.4...1.0) and board zoom.
  - `pruned` removes:
    - IDs of missing notes and of notes with `deletedAt` set from `cheatSheets` and `floatingNotes`;
    - unknown notebook IDs from `boardNotebookIDs` and `boardZoom`.
- [ ] In `NoteStore`:
  - add `@Published private(set) var librarySettings`;
  - load it at the end of `load()`, before `finishLoad()`;
  - save it alongside the library's debounced save and in `flush()`.
  - Write atomically to `rootURL/library-settings.json` (program §7). It's never written into a Markdown library's content folder, so the path comes from `rootURL`, not from the storage backend.
  - A decode failure renames the file to `library-settings.corrupt-<timestamp>.json` (reuse `uniqueURL`/`timestamp`) and uses defaults.
  - When the file's `version > currentVersion`, keep a `librarySettingsReadOnly` flag and skip writes.
- [ ] Add `didSeedThisLaunch`, set where `SeedData.seed(into:)` runs.
- [ ] `updateLibrarySettings(_:)` applies the closure, clamps, and returns early when nothing changed. Otherwise it schedules a save and posts `.noteItLibrarySettingsChanged`.
- [ ] Prune on load and on `noteItLocalChange`, without posting a change notification when nothing was removed.
- [ ] Write the tests:
  - `testMissingFileGivesDefaults`
  - `testRoundTrip`
  - `testMissingKeysDecodeToDefaults`
  - `testCorruptFileIsSetAsideAndDefaultsUsed`
  - `testNewerVersionIsNotOverwritten`
  - `testClampsOutOfRangeValues`
  - `testPruneDropsDeletedAndTrashedNotes`
  - `testUpdatePostsNotificationOnlyOnChange`
  - `testFileLivesInRootURL` (with a Markdown library location whose content folder differs from `rootURL`, the file is written in `rootURL` and the content folder is untouched)
  - `testSyncAdapterNeverSeesSettings` (the adapter's local records never include library settings)
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "LibrarySettingsTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Commit `feat(store): add per-library settings file`.

### Task 2: Typography
**Files:**
- Create:
  - `Sources/NoteIt/Editor/TypographyStyler.swift`
  - `Tests/NoteItTests/TypographyStylerTests.swift`
- Modify:
  - `Editor/EditorStyles.swift`
  - `Editor/NoteItTextView.swift`
  - `Editor/RichTextEditor.swift`
  - `Settings/EditorSettingsView.swift`
  - `App/MenuShortcuts.swift`
  - `App/SurfaceCommands.swift` (create)
  - `App/NoteItApp.swift`
  - `Palette/PaletteCommandRegistry.swift`
  - `Tests/NoteItTests/MenuShortcutStoreTests.swift`

Steps:
- [ ] `TypographyStyler.displayFont`:
  - Only fonts whose `familyName` is the system UI family are swapped, by building `NSFontDescriptor` with `withDesign(_:)` at the same size and symbolic traits.
  - It returns nil for `.system`, for monospaced fonts, and for any other family.
- [ ] `restyle(range:)` stores the original in `.typographyOriginalFont` and sets the display font. `persisted(_:)` restores originals and removes the key.
- [ ] Chain the persisted forms in `NoteItTextView.attributedString()` and `writeSelection(to:type:)` as `TypographyStyler.persisted(CodeStyler.persisted(...))`.
- [ ] Line spacing: the styler is the layout manager's delegate. It implements `layoutManager(_:lineSpacingAfterGlyphAt:withProposedLineFragmentRect:)` by calling `extraLineSpacing`, which returns 0 inside code blocks (the code-block attribute `NoteItLayoutManager` already uses).
- [ ] Width: `EditorStyle.maxReadingWidth` reads the current library typography width. `NoteItTextView.setFrameSize`/`settleColumn`/`make()` pass it to `EditorColumnLayout.fitting(width:maxReadingWidth:)`.
- [ ] Zoom: `RichTextEditor.makeNSView` sets `allowsMagnification = true` and `magnification = settings.zoom`. Observe `.noteItLibrarySettingsChanged` to reapply.
- [ ] Settings › Editor › Text adds the controls in the spec's table, with the footnote, and updates the sample live.
- [ ] Add `MenuShortcutCommand.zoomIn` (⌃⌘=), `.zoomOut` (⌃⌘-) and `.actualSize` (⌃⌘0), with `MenuShortcuts` accessors.
- [ ] Add View menu items in `App/SurfaceCommands.swift`, wired into `NoteItCommands`.
- [ ] Add palette commands `zoomIn`, `zoomOut` and `actualSize`, each stepping by 0.1 within the range.
- [ ] Write the tests:
  - `testSystemFontSwappedToSerifKeepsSizeAndBold`
  - `testMonospacedAndCustomFontsUntouched`
  - `testPersistedRestoresOriginalFonts`
  - `testPersistedWithCodeStylerIsIdentityForUnstyledText`
  - `testExtraLineSpacingZeroInCode`
  - `testExtraLineSpacingScales`
  - `testWidthPresetsFeedColumnLayout`
  - In `MenuShortcutStoreTests`: `testNewDefaultsDontCollideWithReservedOrEachOther` (all `MenuShortcutCommand.allCases` defaults pass `MenuShortcutRules`)
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "TypographyStylerTests|MenuShortcutStoreTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Manual check with `NOTEIT_DATA_DIR=.selftest/typography`:
  - Serif and 1.5 spacing apply live.
  - Quit, then open `notes/<id>.rtfd`: it still has system fonts.
- [ ] Commit `feat(editor): add display-only typography controls`.

### Task 3: Pinning polish (parallel with T1, T4, T5)
**Files:**
- Modify:
  - `Views/NoteListView.swift`
  - `Views/SidebarView.swift`
  - `Views/EditorContainerView.swift`
  - `App/MenuShortcuts.swift`
  - `App/MenuShortcutRules.swift`
  - `App/NoteCommands.swift`
  - `Palette/PaletteCommandRegistry.swift`
- Create `Tests/NoteItTests/PinningTests.swift`.

Steps:
- [ ] Add a pure `NoteListSections.split(_ notes: [NoteMeta], selection: SidebarSelection, searching: Bool) -> (pinned: [NoteMeta], others: [NoteMeta])?` in `NoteListView.swift`. It returns nil when:
  - the list is the Pinned view;
  - the list is Recently Deleted;
  - a search is active;
  - either group is empty.
- [ ] Render `Section("Pinned")` / `Section("Notes")` when it isn't nil.
- [ ] Add `.swipeActions(edge: .leading)` with Pin/Unpin.
- [ ] Wrap `togglePin` calls in `withAnimation(.snappy)` unless Reduce Motion is on.
- [ ] Label the pin icon "Pinned".
- [ ] Add `MenuShortcutCommand.togglePin` ("Pin Note", ⌥⌘P) and its accessor, and add the default to `MenuShortcutRules`.
  - The menu item is the first item in the `NoteCommands` group (program §9), which foundations renamed in task 6.4. `togglePin` is already first in the frozen `NoteCommands.order`; this task adds the item at that place and changes nothing else in the group.
  - Its title follows the selected note's state (Pin Note / Unpin Note).
  - The palette's `togglePin` command shows `shortcuts.current(.togglePin)?.display`.
  - The header button gets help text with the shortcut.
- [ ] Sidebar: add the Pinned library row (`SidebarLibraryRow.pinned`, foundations task 1.1) at its place in the frozen order: All Notes, Today, Tasks, Pinned, Recent, Conflicts. The sidebar builds its library rows from `SidebarLibraryRow.allCases` filtered by what's present, so no other row moves. Recently Deleted stays in its own section at the bottom.
- [ ] Write the tests:
  - `testSectionsSplitPinnedFirst`
  - `testNoSectionsInPinnedViewSearchOrSingleGroup`
  - `testPaletteTogglePinShowsShortcut`
  - `testPinIsFirstInNoteCommands` (the group's item order starts with Pin and the remaining items keep the program's order among those present)
  - `testSidebarPinnedRowFollowsProgramOrder` (the shown library rows are in `SidebarLibraryRow` order: Pinned after All Notes, Today and Tasks when present, and before Recent and Conflicts)
  - Default shortcut collision is already covered by foundations' test and T2's test, or add it here if T3 lands first.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "PinningTests|PaletteCommandRegistryTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Commit `feat(list): add pinned section, swipe and shortcut`.

### Task 4: Sync status popover and unsynced count (parallel with T1, T3, T5)
**Files:**
- Modify:
  - `Sources/NoteItSync/Model/SyncState.swift`
  - `Sources/NoteItSync/Engine/SyncEngine.swift`
  - `Sources/NoteIt/Sync/SyncController.swift`
  - `Views/SyncStatusView.swift`
- Create:
  - `Views/SyncStatusPopover.swift`
  - `Tests/NoteItSyncTests/UnsyncedCountTests.swift`

Steps:
- [ ] `unsyncedCount(local:deletions:)` counts:
  - records whose base revision differs from the record's revision, looking in `boardBases` for board records (added in T9) and in `bases` for everything else;
  - deletion IDs not in `knownTombstones`.
- [ ] Read `SyncEngine` first. `unsyncedCount()` reads the engine's current state and its `SyncLocalStore`'s records and deletions, the same way a pass does, without network calls.
- [ ] `SyncController`:
  - recomputes after each pass and 2 s after `noteItLocalChange` (debounced);
  - sets nil when `status == .notConfigured`;
  - logs errors and keeps the previous value.
- [ ] `SyncStatusPill` toggles a `.popover` with `SyncStatusPopover`, which has the content and wording from spec §11. Conflicts selects `SidebarSelection.conflicts` through `NoteStore`. `MenuBarSyncRow` appends the count.
- [ ] Write the tests:
  - `testNoBasesCountsAllRecords`
  - `testMatchingRevisionNotCounted`
  - `testDeletionCountedUntilKnownTombstone`
  - `testEngineCountDoesNoNetwork` (the InMemoryBackend counters stay 0)
  - T9 adds `testBoardRecordCountedAgainstBoardBase`.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "UnsyncedCountTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Commit `feat(sync): show pending changes in the sync status popover`.

### Task 5: Quick Capture motion (parallel with T1, T3, T4)
**Files:**
- Create:
  - `Sources/NoteIt/MenuBar/QuickCaptureMotion.swift`
  - `Tests/NoteItTests/QuickCaptureMotionTests.swift`
- Modify:
  - `MenuBar/QuickCapturePanel.swift`
  - `App/NoteItApp.swift` (`MenuBarGlyph`)
  - `Design/Tokens.swift`

Steps:
- [ ] Implement the frozen math:
  - `showStart`: 0.96 scale around the center, 8 pt higher, alpha 0.
  - `saveEnd`: 20% size centered on the target's center (or the top center of `screenFrame`), alpha 0.
  - `discardEnd`: 0.98 scale, alpha 0.
  - With `reduceMotion`, every keyframe keeps the frame and only changes alpha.
- [ ] `QuickCaptureController`:
  - Show animates the frame and alpha with `NSAnimationContext` using `showDuration`.
  - Save and discard use their keyframes.
  - Keep the `presentationGeneration` check in completions.
- [ ] Find the status item frame by searching `NSApp.windows` for the status bar window that holds the NoteIt glyph. It's nil when the icon is hidden.
- [ ] Add `QuickCaptureVisibility.savedPulse` (a published counter). `MenuBarGlyph` shows the capturing glyph for `pulseDuration` after it changes.
- [ ] Write the tests:
  - `testShowStartIsScaledAndRaised`
  - `testSaveEndTowardTarget`
  - `testSaveEndFallsBackToTopCenter`
  - `testReduceMotionKeepsFrames`
  - In `QuickCaptureDismissalTests`: `testStaleCompletionDoesNotCloseNewPresentation` still passes.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "QuickCaptureMotionTests|QuickCaptureDismissalTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0. Check by eye with `NOTEIT_DATA_DIR=.selftest/quick-capture swift run NoteIt --debug-quick-capture`.
- [ ] Commit `feat(capture): add Quick Capture motion`.

### Task 5a: Milestone 1 docs
- [ ] Update the docs:
  - `docs/keyboard-shortcuts.md`: ⌥⌘P, ⌃⌘=, ⌃⌘-, ⌃⌘0.
  - `docs/architecture.md`: `library-settings.json` in `rootURL`, display-only typography.
  - `docs/roadmap.md`: mark typography and the polish items done.
  - `README.md`: the typography line in the product tour.
- [ ] Verify: `grep -n "⌥⌘P" docs/keyboard-shortcuts.md`, `grep -n "⌃⌘0" docs/keyboard-shortcuts.md`, `grep -n "library-settings.json" docs/architecture.md` and `grep -in "typography" README.md docs/roadmap.md` each print at least one line.
- [ ] Commit `docs: document typography and polish`.

### Milestone 2: Floating surfaces

### Task 6: Hotkey release events and hold logic
**Files:**
- Create:
  - `Surfaces/CheatSheetHoldLogic.swift`
  - `Tests/NoteItTests/CheatSheetTests.swift` (logic part)
- Modify:
  - `Hotkeys/HotkeyManager.swift`
  - `Hotkeys/HotkeySelfTest.swift`
  - `App/AppDelegate.swift`

This task adds no `HotkeyAction` case. T7 and T8 each add their own case with its tile and handler (program §9).

Steps:
- [ ] `installEventHandler` registers `kEventHotKeyPressed` and `kEventHotKeyReleased`. It routes released events to `releaseHandler`, using the same ID lookup. Pressed events keep going to `handler` unchanged.
- [ ] `AppDelegate` sets `releaseHandler` to a switch over the action that does nothing for every case for now. T7 adds `.cheatSheet` to it.
- [ ] `HotkeySelfTest` still passes; extend it to confirm a release event reaches `releaseHandler` when it can post one.
- [ ] Write `CheatSheetHoldLogic` and its tests:
  - `testHoldShowsThenHidesOnRelease`
  - `testShortTapLatchesOpen`
  - `testPressWhileLatchedHides`
  - `testRepeatPressWhileHeldIgnored`
  - `testToggleModeIgnoresRelease`
  - `testDismissResetsState`
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "CheatSheetTests|HotkeyActionTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Commit `feat(hotkeys): add key-release events`.

### Task 7: Cheat-sheet overlay (parallel with T8)
**Files:**
- Create:
  - `Surfaces/CheatSheetController.swift`
  - `Surfaces/CheatSheetPanel.swift`
  - `Surfaces/CheatSheetAppPicker.swift`
  - `Surfaces/SurfaceURLRoutes.swift` (if T8 hasn't created it)
  - `Tests/NoteItTests/SurfaceURLRouteTests.swift` (if T8 hasn't created it)
- Modify:
  - `Hotkeys/HotkeyAction.swift`
  - `Settings/ShortcutsSettingsView.swift`
  - `Design/Tokens.swift`
  - `App/AppDelegate.swift`
  - `Editor/RichTextEditor.swift`
  - `Editor/NoteItTextView.swift`
  - `Palette/PaletteController+Global.swift`
  - `Palette/PalettePanel.swift`
  - `Palette/PaletteCommandRegistry.swift`
  - `Settings/Preferences.swift`
  - `Settings/GeneralSettingsView.swift`
  - `Settings/GeneralSettingsSection.swift`
  - `Views/NoteListView.swift`
  - `Views/EditorContainerView.swift`
  - `Tests/NoteItTests/HotkeyActionTests.swift` (create if missing)
  - `Tests/NoteItTests/CheatSheetTests.swift`

Steps:
- [ ] Add `HotkeyAction.cheatSheet` ("Show Cheat Sheet", "Hold to see a note over the app you're in", `rectangle.on.rectangle`) at position 13: after every case from positions 1–12 that exists, before `toggleFloatingNotes` if T8 landed first. It has no default binding.
  - In the same change: `Tokens.Color.tileCheatSheet` and its `ShortcutsSettingsView` tile; the `AppDelegate` press handler (`CheatSheetController.shared.hotkeyPressed()`) and release handler (`hotkeyReleased()`). Every switch over `HotkeyAction` stays exhaustive, so the build fails if one is missed.
- [ ] Add `PrefKey.cheatSheetMode` (default `hold`).
- [ ] Add `TransientSurfaceHider.Surface.cheatSheet`. Call `surfaceWillAppear`/`surfaceDidClose` around the panel, as the capture toast does.
- [ ] Add `EditorRole` to `RichTextEditor`. In the `.cheatSheet` role the text view has `isEditable = false` and doesn't register with `OpenEditorRegistry` as an editor. `NoteItTextView`'s checkbox clicks, grip handles (T18) and drops check `isEditable`, so they do nothing there. The panel never becomes key either.
- [ ] Use the observer API foundations task 4.5 provides on `OpenEditorRegistry` (`registerObserver(_:for:)`); this task relies on, and tests, its behaviour:
  - Observers are kept per note ID, apart from editors, so `textView(for:)` never returns one and `editBody` never edits one.
  - When an editor registers for a note that has observers, the registry watches that editor's text storage `didProcessEditing` and passes a copy of the storage to each observer; it stops when the editor unregisters.
  - After `editBody`'s closed path saves, and when `NoteStore` posts `externallyUpdatedNoteID` for the note, the registry passes the saved body to each observer.
  - Unregistering drops the observer; an observer whose note has no editor costs nothing.
- [ ] Build the panel per spec §2:
  - borderless, non-activating, `canBecomeKey == false`, floating level;
  - header plus `RichTextEditor(noteID:controller:role: .cheatSheet)`;
  - `setFrameAutosaveName("NoteItCheatSheet")`;
  - minimum size 280 × 200;
  - the "No cheat sheet for <App>" and locked states.
- [ ] Keep it current (program §6):
  - On show, load the body through `NoteStore.body(for:)`, then call `registerObserver(_:for:)` with an observer that replaces the panel's text storage. If `textView(for:)` returns an editor, start from a copy of its text storage so unsaved typing shows.
  - On hide, unregister the observer. The panel's text view never registers as an editor.
- [ ] The controller:
  - reads the frontmost bundle ID at press time;
  - looks the note up via `librarySettings.cheatSheets.noteID(forBundleID:)`;
  - refuses locked notes (`NoteMeta` lock state from sync-security) and shows the locked state;
  - feeds `CheatSheetHoldLogic`;
  - while visible, installs a global left/right mouse-down monitor and observes `didActivateApplicationNotification`, then removes both on hide.
- [ ] Assigning:
  - Add the **Use as Cheat Sheet** menu to the note context menu and to a new ⋯ `Menu` in `EditorHeader`. It's disabled for locked notes with the help text "Locked notes can't be shown as a cheat sheet."
  - `CheatSheetAppPicker` lists `NSWorkspace.shared.runningApplications` with `.regular` activation policy, excluding NoteIt, plus **Other App…** (`NSOpenPanel`, `allowedContentTypes: [.application]`).
- [ ] Settings › General › Cheat Sheet: turn on `isAvailable` for `GeneralSettingsSection.cheatSheet`, which foundations task 6.5 freezes between `reminders` and `updates`, and render it with the mode picker, global picker, per-app table and the help text from the spec.
- [ ] `PaletteController` records `previousApp` when it shows.
- [ ] Add palette commands `showCheatSheet`, `cheatSheetGlobal` and `cheatSheetForApp`.
- [ ] `SurfaceURLRoutes.register(in:)` adds the `cheat-sheet` host through `URLRouteRegistry.register(host:handler:)`: no query toggles for the frontmost app, `app=<bundle id>` for a named app. It never asks for confirmation. `AppDelegate` calls `register(in:)` where automation's routes are registered. No Local API route is added.
- [ ] Write the tests:
  - In `HotkeyActionTests`: `testRawValuesAreUnique`, `testFirstSixCasesUnchanged`, `testNewCasesHaveNoDefaultBinding` (`cheatSheet` has none), `testCasesFollowFrozenTableOrder` (`cheatSheet` comes after every present case from 1–12 and before `toggleFloatingNotes` when present). Each test passes whether or not T8 has landed.
  - `testEveryActionHasTileAndHandler` (the tile color and handler lookup return a value for every case)
  - `testLookupPrefersAppThenGlobal`
  - `testNoteItInFrontUsesGlobal`
  - `testDeletedAssignmentPruned`
  - `testAssignReplacesPreviousForApp`
  - `testLockedNoteCannotBeAssignedOrShown`
  - `testPaletteCommandsAvailableOnlyWithNote`
  - `testCheatSheetRegistersAsObserverNotEditor` (`textView(for:)` stays nil with only the sheet showing, and returns the main editor when one is open)
  - `testObserverMirrorsRegisteredEditor` (typing in the registered editor reaches the observer before saving)
  - `testEditBodyClosedPathNotifiesObserver` (with no editor open, `editBody` saves and the visible sheet shows the new body)
  - `testRemovedObserverNotCalled`
  - `testReadOnlySurfaceIgnoresCheckboxClick` (`isEditable == false`, the body is unchanged)
  - `testGeneralSectionsKeepFrozenOrder` (`cheatSheet` sits between `reminders` and `updates`)
  - In `SurfaceURLRouteTests`: `testCheatSheetRouteRegistered`, `testCheatSheetRouteUsesAppParameter`, `testNoLocalAPIRoutesAdded` (the Local API route table is unchanged)
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "CheatSheetTests|HotkeyActionTests|SurfaceURLRouteTests|PaletteGlobalTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Manual check with `NOTEIT_DATA_DIR=.selftest/cheatsheet`:
  - Bind a hotkey. Hold it over TextEdit and the note shows while TextEdit keeps the caret; release and it hides.
  - Tap it and it stays; a click outside closes it.
  - With NoteIt hidden, showing the panel doesn't unhide the main window.
  - With the note open in the main window, typing there shows in the visible cheat sheet.
  - `open "noteit://cheat-sheet"` toggles it.
- [ ] Commit `feat(surfaces): add cheat-sheet overlay`.

### Task 8: Floating notes (parallel with T7)
**Files:**
- Create:
  - `Surfaces/FloatingNotesController.swift`
  - `Surfaces/FloatingNotePanel.swift`
  - `Surfaces/FloatingNotePlaceholder.swift`
  - `Surfaces/SurfaceURLRoutes.swift` (if T7 hasn't created it)
  - `Tests/NoteItTests/FloatingNotesTests.swift`
  - `Tests/NoteItTests/SurfaceURLRouteTests.swift` (if T7 hasn't created it)
- Modify:
  - `Hotkeys/HotkeyAction.swift`
  - `Settings/ShortcutsSettingsView.swift`
  - `Design/Tokens.swift`
  - `App/SurfaceCommands.swift`
  - `App/AppDelegate.swift`
  - `Editor/RichTextEditor.swift`
  - `Views/EditorContainerView.swift`
  - `Views/NoteListView.swift`
  - `MenuBar/MenuBarView.swift`
  - `Palette/PaletteCommandRegistry.swift`
  - `Tests/NoteItTests/HotkeyActionTests.swift` (create if missing)

Steps:
- [ ] Add `HotkeyAction.toggleFloatingNotes` ("Show / Hide Floating Notes", `macwindow.on.rectangle`) as the last case (position 14). It has no default binding.
  - In the same change: `Tokens.Color.tileFloatingNotes` and its `ShortcutsSettingsView` tile; the `AppDelegate` press handler (`FloatingNotesController.shared.toggleAll()`).
- [ ] The panel follows spec §3: utility style, `.floating`, `hidesOnDeactivate = false`, 320 × 360 default, 220 × 160 minimum, and an opacity menu that sets `alphaValue`.
  - It hosts `RichTextEditor(noteID:controller:role: .floating)`, editable.
  - Its text view registers with `OpenEditorRegistry` when the window opens and unregisters when it closes, so `editBody` edits it in place as one undo step.
  - Moves, resizes and opacity changes go to `updateLibrarySettings`.
- [ ] The controller:
  - enforces `maxWindows`;
  - refuses locked notes, and closes a float when its note becomes locked;
  - cascades new windows by 24 pt;
  - closes windows on `noteItLocalChange` / `externallyUpdatedNoteID` when a note is gone or trashed;
  - restores with `FloatingNoteState.fitted` at the end of `applicationDidFinishLaunching`.
- [ ] `toggleAll` is wired to the hotkey, the Window menu, the palette (`floatNote`, `toggleFloatingNotes`) and the menu bar extra. Float Note is disabled for locked notes with the help text "Locked notes can't float."
- [ ] `EditorContainerView` shows `FloatingNotePlaceholder` instead of `RichTextEditor` when `FloatingNotesController.shared.isFloating(id)`, so the main window never registers a second editor.
- [ ] `SurfaceURLRoutes.register(in:)` adds the `float` host: `noteit://float?id=<UUID>` calls `float(_:)`. A missing or bad ID, a missing note, a locked note or the limit gives the route's error result. It never asks for confirmation. No Local API route is added.
- [ ] Write the tests:
  - In `HotkeyActionTests`: `toggleFloatingNotes` is last, has no default binding, and the program tests from T7 still pass.
  - `testFloatRefusedAtLimit`
  - `testFloatRefusedForLockedNote`
  - `testFloatingStateSavedAndRestored` (via `LibrarySettings`)
  - `testFrameFittedOntoScreen`
  - `testDeletedNoteDroppedOnRestore`
  - `testPlaceholderShownWhileFloating` (controller state only)
  - `testFloatingEditorRegisteredWhileOpen` (registered on open, unregistered on close)
  - `testEditBodyUpdatesFloatingNote` (with a floating note open, `editBody` changes its text storage and adds one undo step)
  - In `SurfaceURLRouteTests`: `testFloatRouteFloatsNote`, `testFloatRouteRejectsBadID`, `testFloatRouteRefusesLockedNote`
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "FloatingNotesTests|HotkeyActionTests|SurfaceURLRouteTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Manual check: float two notes, edit one, quit and relaunch, and both come back in place with their opacity. Text typed in a float appears in the main window after Return to Main Window. `open "noteit://float?id=<UUID>"` floats a note.
- [ ] Commit `feat(surfaces): add floating notes`.

### Task 8a: Milestone 2 docs
- [ ] Update the docs:
  - `docs/keyboard-shortcuts.md`: the two new global hotkeys.
  - The `noteit://` link reference (automation's docs page): `noteit://float?id=` and `noteit://cheat-sheet[?app=]`.
  - `docs/known-limitations.md`: cheat sheet can't close with Esc; hotkeys don't fire under secure input; reword "One window" to say floating notes exist and a second main window doesn't.
  - `docs/roadmap.md`: Cheat sheets and Floating notes done.
  - `docs/architecture.md`: `Surfaces/`.
  - `README.md`.
- [ ] Verify: `grep -in "cheat sheet" docs/keyboard-shortcuts.md docs/known-limitations.md docs/roadmap.md README.md`, `grep -in "floating note" docs/keyboard-shortcuts.md docs/known-limitations.md docs/roadmap.md README.md`, `grep -rn "noteit://float?id=" docs/`, `grep -rn "noteit://cheat-sheet" docs/`, `grep -in "secure input" docs/known-limitations.md` and `grep -n "Surfaces/" docs/architecture.md` each print at least one line.
- [ ] Commit `docs: document cheat sheets and floating notes`.

### Milestone 3: Board

### Task 9: Board record, geometry and sync
**Files:**
- Create:
  - `Sources/NoteItCore/BoardLayout.swift`
  - `Sources/NoteIt/Model/NoteStore+Board.swift`
  - `Sources/NoteIt/Board/BoardGeometry.swift`
  - `Tests/NoteItTests/BoardGeometryTests.swift`
  - `Tests/NoteItTests/BoardStoreTests.swift`
  - `Tests/NoteItTests/BoardRawMetaTests.swift`
  - `Tests/NoteItSyncTests/BoardSyncTests.swift`
- Modify:
  - `Sources/NoteItCore/Models/CodingKeyNames.swift` (foundations Task 3.5)
  - `Sources/NoteIt/Model/NoteStore+RawMeta.swift` (foundations Task 3.5)
  - `Sources/NoteItSync/Model/SyncTypes.swift`
  - `Sources/NoteItSync/Model/SyncState.swift`
  - `Sources/NoteItSync/Engine/RemoteLayout.swift`
  - `Sources/NoteItSync/Engine/SyncEngine.swift`
  - `Sources/NoteIt/Sync/NoteStoreSyncAdapter.swift`
  - `Sources/NoteIt/Model/NoteStore.swift`
  - `Tests/NoteItSyncTests/RemoteLayoutTests.swift`
  - `Tests/NoteItSyncTests/UnsyncedCountTests.swift`
  - `fixtures/golden/layout-keys.json`
  - `Tests/NoteItSyncTests/RemoteLayoutRegistryTests.swift`

Board layouts are their own record kind (program §4 rules 6 and 14). `Notebook` gains no field, and the notebook record and its revision never change because of a board.

Steps:
- [ ] Add `BoardLayout`/`BoardPosition` to `NoteItCore` as frozen, and `BoardLayout.ownedCodingKeys` to `Models/CodingKeyNames.swift` with its `ModelCodingTests` check (the set equals the encoded keys with every optional set).
- [ ] `NoteItSync`:
  - Add `RecordKind.board`: no body, `usesLastWriterWins == true` (organise's flag), so a concurrent change never makes a conflict copy.
  - Add `RemotePrefix(path: "inkwell/v1/boards/", depth: 1, sealing: .storeKey, owner: "surfaces-polish")` to `RemoteLayout.prefixes`, and add `board(_:)`. `RekeyRunner` then re-seals board records with no change here.
  - Add to `fixtures/golden/layout-keys.json`: a valid `inkwell/v1/boards/<UUID>.json` key with prefix `boards/` and action `reseal`, invalid keys (`boards/<UUID>/x.json`, a non-UUID name), and `boards/` in `listPrefixes`. Foundations' `RemoteLayoutRegistryTests` and the web server's tests read the same file.
  - Add `SyncState.boardBases`, decoded with `decodeIfPresent`. The engine keeps board bases there and never in `bases`, because a board's ID is its notebook's ID.
  - Boards have no tombstones (program §4 rule 14). When a notebook is deleted locally, the adapter reports its board as a board deletion and the engine deletes the remote object (best effort) and drops the board base. A remote board whose notebook is missing locally and remotely, or has a tombstone, is ignored and deleted by the Mac. The phone and the web app never delete it (program §4 rule 9), so this is how boards of notebooks deleted there are removed.
- [ ] `NoteStore+Board`:
  - Boards are read from and written to `rootURL/boards/<notebookID>.json` as `BoardFile`, atomically, through `NoteStore` only.
  - `setBoardPositions` merges the positions, prunes them with `BoardGeometry.pruned` against the notebook's current live notes, sets a new board `revision` and `modifiedAt`, marks the board dirty for sync and schedules a save. It doesn't touch `Notebook`, `libraryDirty` or the notebook revision.
  - `arrangeBoard` writes `gridArrangement` by date edited.
  - Deleting a notebook deletes its board file.
- [ ] Raw meta for boards, following foundations Task 3.5's per-kind contract with the `NoteStore+RawMeta` functions as frozen there (no new raw-meta code paths), so unknown keys in a board record survive (program §4.5):
  - add `RawMetaKind.boards` (folder `sync-meta-raw/boards/`, already a program §7 row) and its arms in `appliedRemoteRevision(for:kind:)` (reads `BoardFile.appliedRemoteRevision`) and `isDurablyListed(_:kind:)` (the board's file exists). A board's ID is its notebook's ID; the separate folder and the separate entry keep the two kinds apart;
  - apply: `setLastRemoteMeta(RawMeta(sourceRevision: payload.revision, meta: decrypted), for: notebookID, kind: .boards)` before the board is applied; a throw skips that board's apply this pass and leaves its entry unchanged. A successful apply writes the layout and `appliedRemoteRevision = payload.revision` in the same atomic `BoardFile` write. `setBoardPositions`, `arrangeBoard` and this Mac's own pushes keep the entry as it is;
  - export: `RawMetaOverlay(lastDecrypted: lastRemoteMeta(for: notebookID, kind: .boards)).merged(with: encoded, ownedKeys: BoardLayout.ownedCodingKeys)` before sealing;
  - removal (notebook deleted locally or remotely, orphan board removed by the Mac): after the board file is deleted, `queueRawMetaDeletion(notebookID, kind: .boards)`. The raw file is never deleted directly; foundations' pending-trash pass deletes it once `isDurablyListed` is false, so a failed board-file delete keeps the raw file.
- [ ] `NoteStoreSyncAdapter` exports a `.board` local record per board file (through the overlay above), applies remote boards (whole-record replace, raw meta first), and reports board deletions.
- [ ] Implement `BoardGeometry` as frozen:
  - Columns are derived from the viewport width at 100%.
  - `placements` keeps stored positions and puts the rest into free grid slots after the lowest stored row.
  - `neighbour` picks the nearest card whose center lies in the direction's 90° cone.
- [ ] Write the tests:
  - `BoardGeometryTests`: `testUnplacedNotesFillGridAfterStored`, `testSnapToEightPoints`, `testVisibleCulling`, `testNeighbourDirections`, `testReadingOrder`, `testPrunedDropsMissing`, `testZoomClamped`
  - `BoardStoreTests`:
    - `testSetPositionsBumpsBoardRevisionOnly` (the notebook's revision and `modifiedAt` are unchanged)
    - `testOpeningBoardWritesNothing`
    - `testBoardFileLivesInRootURL`
    - `testDeletingNotebookDeletesBoard`
    - `testNotebookRecordHasNoBoardKey`
  - `BoardRawMetaTests`, foundations' four lifecycle tests for this kind, plus the shared-ID case:
    - `testUnknownKeySurvivesLocalEdit`: apply a remote board with `"futureField": 1`, move a card, export; the sealed plaintext still has `futureField`;
    - `testUnappliedRawMetaNotMerged`: apply R1 with `"futureField": 1`; write the raw file for R2 with `"futureField": 2` and make its apply fail; a card move exports with no `futureField`; after a successful apply of R3 with `"futureField": 3`, a card move exports `"futureField": 3`;
    - `testDeletionWaitsForDurableSave`: delete the notebook of an applied board while its board file can't be deleted (the `boards/` folder made read-only); after `flush()` the raw file is still there. With the folder writable again, the next flush removes the board file and then the raw file. With the raw delete failing, the ID stays queued and the next flush removes it;
    - `testRawMetaSurvivesRelaunch`: apply a remote board with `"futureField"` and flush; a new `NoteStore` on the same root reads the applied revision from the board file, and after a card move the export still has `futureField`;
    - `testBoardAndNotebookRawMetaDontCollide`: a notebook and its board (same UUID), applied with `"notebookFuture"` and `"boardFuture"`, get files under `sync-meta-raw/notebooks/` and `sync-meta-raw/boards/`; after a local edit of each, each export keeps only its own key, and applying one leaves the other's applied revision unchanged.
  - `BoardSyncTests` (InMemoryBackend, two engines):
    - `testBoardCreatedOnAAppearsOnB`
    - `testConcurrentMovesLastWriterWinsWithoutConflictCopy`
    - `testBoardAndNotebookBasesDontCollide` (rename the notebook on A and move cards on B; both changes arrive and neither makes a conflict)
    - `testNoBoardTombstoneWritten`
    - `testNotebookDeleteRemovesRemoteBoard`
    - `testOrphanBoardIgnoredAndDeletedByMac` (the notebook is tombstoned by another device that left the board in place)
    - `testLegacyIndexIgnoresBoards` (a `RemoteIndex` built with a copy of the 0.2 folder switch lists nothing under `boards/`)
    - `testMissingBoardBasesDecodes` (old `SyncState` JSON)
  - `RemoteLayoutTests`: `testBoardsPrefixRegisteredAndSealed`; `RemoteLayoutRegistryTests` passes with the new `layout-keys.json` cases.
  - `UnsyncedCountTests`: `testBoardRecordCountedAgainstBoardBase`.
- [ ] Hand the web app and phone owners a store fixture with a board record; their engines must ignore it without error (program §4.9).
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "BoardGeometryTests|BoardStoreTests|BoardRawMetaTests|BoardSyncTests|RawMetaStoreTests|ModelCodingTests|RemoteLayoutTests|RemoteLayoutRegistryTests|UnsyncedCountTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`.
- [ ] Run the sync suites to confirm nothing else changed: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "SyncEngineTests|SyncPlannerTests" 2>&1 | tail -20`, expecting `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Commit `feat(board): add board layout records`.

### Task 10: Board view
**Files:**
- Create:
  - `Board/BoardView.swift`
  - `Board/BoardCardView.swift`
  - `Board/BoardNotePane.swift`
- Modify:
  - `Views/MainView.swift`
  - `Views/NoteListView.swift`
  - `Editor/RichTextEditor.swift`
  - `App/SurfaceCommands.swift`
  - `Palette/PaletteCommandRegistry.swift`
  - `Design/Tokens.swift`

Steps:
- [ ] The List | Board segmented control appears in the note list toolbar only for `.notebook` selections. It toggles `boardNotebookIDs`.
- [ ] `MainView` uses a two-column `NavigationSplitView` (sidebar plus `BoardView`) when the selected notebook is in board mode.
- [ ] `BoardView`:
  - a `ScrollView([.horizontal, .vertical])` with `.scaleEffect` by zoom inside a sized frame;
  - only `visible` cards are built;
  - drag gestures commit on end via `setBoardPositions`;
  - a rubber-band selection;
  - keyboard: arrows select via `neighbour`; ⌥/⌥⇧ arrows nudge; Return opens the note pane; Esc closes it;
  - pinch (`MagnifyGesture`) and ⌘-scroll zoom stored in `boardZoom`;
  - the toolbar − / 100% / + and ⋯ › Arrange in Grid;
  - the 2,000-card bar.
- [ ] `BoardNotePane` (spec §4), not the window `.inspector`, which linking owns:
  - a resizable pane on the right edge of `BoardView`, 420 pt by default;
  - hosts `RichTextEditor(noteID:controller:role: .boardPane)`, or `FloatingNotePlaceholder` when the note floats;
  - its text view registers with `OpenEditorRegistry` while a note is open in it and unregisters when it closes or switches note;
  - while board mode is on, `toggleLinksPanel` (⌥⌘I) shows or hides linking's `LinksPanelView` inside the pane for the opened note, using linking's `inspectorTab` preference. Plugin tabs appended to linking's inspector appear there too. The main window's `.inspector` stays closed in board mode.
- [ ] Cards: title, three-line preview, pin glyph, date edited; `.draggable(note.id.uuidString)`; the list's context menu plus Float Note.
- [ ] Accessibility: `.accessibilityElement(children: .combine)` with `NoteAccessibility.cardLabel` (added in T12; use a local string until then), `.accessibilityAction(named:)` for Open and the four moves, and an `.accessibilityRotor("Cards")` in `readingOrder`.
- [ ] Add palette commands `toggleBoard` and `boardArrange`.
- [ ] Write the tests (in `BoardStoreTests`, state only):
  - `testBoardPaneRegistersOpenNote` (registered while open, unregistered on close and on switching note)
  - `testEditBodyUpdatesBoardPane`
  - `testBoardModeDoesNotUseWindowInspector` (the main view's inspector binding stays false in board mode; ⌥⌘I toggles the pane's links section instead)
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "BoardStoreTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0. Manual check with `NOTEIT_DATA_DIR=.selftest/board`:
  - Drag cards, quit and relaunch, and positions are kept.
  - Open a card, press ⌥⌘I, and backlinks for that note show in the pane.
  - Run two instances with folder sync (as in the sync plan's two-instance check) and confirm a move on one appears on the other, and that renaming the notebook on the other at the same time keeps both changes.
- [ ] Commit `feat(board): add board view`.

### Task 10a: Milestone 3 docs
- [ ] Update the docs:
  - `docs/architecture.md`: the `boards/` record kind, local `rootURL/boards/`, its raw meta in `sync-meta-raw/boards/`, last writer wins, no tombstones.
  - `docs/known-limitations.md`: no freeform drawing; boards show a notebook's direct notes only; web and phone don't show boards yet.
  - `docs/roadmap.md`.
  - `README.md`.
- [ ] Verify: `grep -n "boards/" docs/architecture.md`, `grep -in "last writer wins" docs/architecture.md`, `grep -in "drawing" docs/known-limitations.md` and `grep -in "board" docs/roadmap.md README.md` each print at least one line.
- [ ] Commit `docs: document board view`.

### Milestone 4: Onboarding

### Task 11: Welcome window
**Files:**
- Create:
  - `Onboarding/OnboardingFlow.swift`
  - `Onboarding/OnboardingModel.swift`
  - `Onboarding/OnboardingView.swift`
  - `Tests/NoteItTests/OnboardingFlowTests.swift`
- Modify:
  - `Model/NoteStore.swift`
  - `App/NoteItApp.swift`
  - `App/WindowRouter.swift`
  - `App/SurfaceCommands.swift`
  - `App/AppDelegate.swift`
  - `Settings/Preferences.swift`
  - `Import/ImportSheet.swift`
  - `Palette/PaletteCommandRegistry.swift`

Steps:
- [ ] Add `PrefKey.onboardingCompletedVersion` (Int, default 0).
- [ ] Add a `Window("Welcome to NoteIt", id: WindowRouter.welcomeWindowID)` scene with `.windowResizability(.contentSize)`. Add `WindowRouter.showWelcome()`, Help › Welcome to NoteIt… (`CommandGroup(before: .help)`), and the palette command `showWelcome`.
- [ ] `AppDelegate`:
  - after `LaunchMigration.presentPendingNotices()`, call `showWelcome()` when `OnboardingFlow.shouldShow(completedVersion:librarySeededThisLaunch:forced:)` returns true;
  - add the `--debug-onboarding` argument in `handleDebugArguments()`.
- [ ] `OnboardingFlow.steps(for:)`:
  - nil: `[.welcome]`;
  - `.newUser`: welcome, hotkeys, menuBar, bringNotes, anotherMac, done;
  - `.otherMac`: welcome, syncFirst, hotkeys, menuBar, done.
  - Going back to Welcome and picking the other answer switches the list; pages already completed keep their state.
- [ ] Sync first page (`.otherMac` path):
  - **Set Up Sync…** calls `SettingsTabRouter.show(.sync)`.
  - The page observes `SyncController`'s status and shows "Not set up yet", "Syncing…" or "Synced. <n> notes on this Mac." **Continue** is always enabled.
  - When the page appears and sync isn't configured, call `NoteStore.removeUnchangedSeedNotes()`: it removes seeded welcome notes whose revision still matches the seeded one, with no Recently Deleted entry and no tombstone, and keeps edited ones. It does nothing once sync has ever run on this library.
- [ ] Hotkey page: one row per `OnboardingFlow.hotkeyRows` entry (Quick Capture, Show / Hide NoteIt, Command Palette), each with an empty `ShortcutRecorder` and the help text "Click to record a shortcut." No combo is suggested or prefilled (program §9).
  - The page shows **Skip** while no row has a recorded shortcut, and **Continue** once one does. Skip moves on and binds nothing.
  - `OnboardingModel.applyHotkeys()`, for each recorded row: rejects combos where `isSystemShortcut` is true; calls `setCombo`; reads `registrationErrors` and, on failure, clears the binding and reports "In use by macOS or another app. Pick another." on the row.
- [ ] Menu bar page: bind the same `@AppStorage` keys as `GeneralSettingsView`, and reuse its launch-at-login toggle view.
- [ ] Bring your notes page (new-user path): **Apple Notes** and **Other…** in this task. `OnboardingFlow.importSources(available:)` decides which buttons show; T11a adds Evernote and Notion. The model owns an `ImportModel(store:)`. Closing the window mid-run calls `ImportSheetPresenter.show(continuing: model)`, which is a new overload that presents the sheet for an existing model. The page has no storage choice; Markdown storage stays in Settings › Your Data.
- [ ] The Another Mac page calls `SettingsTabRouter.show(.sync)`. The Done page calls `WindowRouter.focusEditor()`.
- [ ] Skip Setup, close and Start Writing all set the completed version.
- [ ] Write the tests:
  - `testShowsOnlyOnSeededFreshLibrary`
  - `testForcedAlwaysShows`
  - `testCompletedVersionSuppresses`
  - `testNewUserSteps` and `testOtherMacStepsSkipImport` (no `.bringNotes` or `.anotherMac` on that path; `.syncFirst` comes second)
  - `testSwitchingPathFromWelcome`
  - `testHotkeyRowsHaveNoDefaultCombos` (every row starts empty)
  - `testSkipBindsNothing`
  - `testApplyHotkeysSkipsEmptyRows`
  - `testApplyHotkeysRejectsSystemShortcut` (a recorded ⌥Space is refused with the row's error)
  - `testApplyHotkeysReportsTakenCombo` (the manager is injected through a small protocol in `OnboardingModel`)
  - `testRemoveUnchangedSeedNotesKeepsEditedOnes` (no Recently Deleted entries, no deletions reported to the sync adapter)
  - `testRemoveSeedNotesDoesNothingAfterSync`
  - `testImportSourcesAppleNotesFirst`
  - `testNoStorageChoiceInOnboarding` (no step or model property changes the library's storage)
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "OnboardingFlowTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Manual check: with an empty `NOTEIT_DATA_DIR=.selftest/welcome`, the window appears.
  - New to NoteIt: Apple Notes import runs and continues after closing. Help reopens the window.
  - Another Mac: set up folder sync against a second instance's folder; the welcome notes don't appear on the other instance, and its notes arrive here.
- [ ] Time a 500-note Apple Notes import and record it for `docs/performance.md`.
- [ ] Update `docs/known-limitations.md` (remove "No first-run guide"), `docs/development.md` (`--debug-onboarding`), `docs/roadmap.md` and `README.md`.
- [ ] Commit `feat(onboarding): add welcome window`.

### Task 11a: Evernote and Notion in onboarding
**Files:**
- Modify:
  - `Onboarding/OnboardingFlow.swift`
  - `Onboarding/OnboardingView.swift`
  - `Tests/NoteItTests/OnboardingFlowTests.swift`

Needs markdown-storage's `ImportSource.evernote` and `.notion` with `EvernoteImporter` and `NotionImporter`.

Steps:
- [ ] `importSources(available:)` returns Apple Notes, then Evernote and Notion when the import sheet offers them.
- [ ] The Evernote and Notion buttons use the same file prompts and wording as the import sheet and run through the page's `ImportModel` with the same progress line and `show(continuing:)` behaviour.
- [ ] Write the tests:
  - `testImportSourcesIncludeEvernoteAndNotionWhenAvailable`
  - `testImportSourcesHideMissingImporters`
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "OnboardingFlowTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Manual check: import a small `.enex` file and a Notion export zip from the page.
- [ ] Commit `feat(onboarding): offer Evernote and Notion import`.

### Milestone 5: Accessibility

### Task 12: Labels, rotors and announcements
**Files:**
- Create:
  - `Accessibility/NoteAccessibility.swift`
  - `Accessibility/EditorRotorIndex.swift`
  - `Tests/NoteItTests/NoteAccessibilityTests.swift`
  - `Tests/NoteItTests/EditorRotorIndexTests.swift`
- Modify:
  - `Views/SidebarView.swift`
  - `Views/NoteListView.swift`
  - `Views/EditorContainerView.swift`
  - `Editor/FormattingToolbar.swift`
  - `Editor/NoteItTextView.swift`
  - `Palette/PaletteModel.swift`
  - `Palette/PaletteView.swift`
  - `MenuBar/QuickCapturePanel.swift`
  - `Board/BoardCardView.swift`

Steps:
- [ ] Implement the label builders with relative dates via `RelativeDateTimeFormatter` (injected `now`) and "Untitled" for empty titles.
- [ ] `EditorRotorIndex`: one pass over the storage.
  - Headings and checklist items come from the paragraph block markers `EditorStyle` already defines (read `EditorStyles.swift` for the sentinel values).
  - Code blocks come from the code-block attribute `NoteItLayoutManager` draws.
  - Links come from `.link`.
  - The label is the trimmed line text, or the link text.
- [ ] `NoteItTextView`:
  - `accessibilityCustomRotors()` returns four `NSAccessibilityCustomRotor`s backed by a cached index, invalidated in `textStorage(_:didProcessEditing:)`;
  - `accessibilityCustomActions()` adds Toggle Checkbox and Copy Code Block when they apply.
- [ ] SwiftUI:
  - `.accessibilityLabel` on every icon-only button and meaningful image;
  - `.accessibilityHidden(true)` on decorative ones;
  - rows use `.accessibilityElement(children: .combine)` with the builders;
  - add rotors Notebooks, Tags and Pinned Notes.
- [ ] The palette posts `NSAccessibility.post(element:notification: .announcementRequested, userInfo:)` 0.5 s after the last query change. Quick Capture announces "Saved to <notebook>".
- [ ] Write the tests:
  - `testRowLabelIncludesPinnedNotebookAndDate`
  - `testEmptyTitleReadsUntitled`
  - `testResultsAnnouncementPlural`
  - `testRotorFindsHeadingsChecklistCodeLinks`
  - `testRotorRangesStayInBounds`
  - `testEmptyStorageHasNoEntries`
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "NoteAccessibilityTests|EditorRotorIndexTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Commit `feat(a11y): add VoiceOver labels, rotors and announcements`.

### Task 13: Audit test and checklist
**Files:**
- Create:
  - `Tests/NoteItTests/AccessibilityAuditTests.swift`
  - `docs/accessibility.md`
- Modify:
  - `docs/known-limitations.md`
  - `docs/development.md`
  - `docs/roadmap.md`

Steps:
- [ ] Add a helper `auditUnlabeled(_ root: Any) -> [String]`. It recursively walks `NSAccessibilityElementProtocol` children and collects role and path for:
  - buttons, images, checkboxes, pop-up buttons and sliders with an empty `accessibilityLabel()` and `accessibilityTitle()`;
  - but not hidden elements.
- [ ] For each view:
  - host it in `NSHostingView` inside an offscreen `NSWindow` (`orderBack`) with a temp `NoteStore` holding 3 notes;
  - call `layoutSubtreeIfNeeded()`;
  - audit it.
- [ ] Use `XCTSkip` when the root has no children.
- [ ] Views to audit: `SidebarView`, `NoteListView`, `EditorContainerView`, `PaletteView`, `SyncStatusPill`, each `OnboardingStep` page, `BoardView`.
- [ ] Fix every element it reports.
- [ ] `docs/accessibility.md`: VoiceOver, keyboard-only and Reduce Motion / Increase Contrast checklists per surface. Each row has Steps, Expected, Result and Version. Run it once and fill in the results.
- [ ] Remove "Accessibility hasn't been audited" from known limitations and replace it with any findings left open. Add the audit command to `docs/development.md`.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "AccessibilityAuditTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures` (or `Executed N tests, with N tests skipped and 0 failures` without a window server). Run the full suite: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`, expecting `with 0 failures` and exit 0.
- [ ] Commit `test(a11y): add accessibility audit and checklist`.

### Milestone 6: Benchmarks

### Task 14: Bench harness
**Files:**
- Create:
  - `Bench/BenchStats.swift`
  - `Bench/BenchFixture.swift`
  - `Bench/BenchRunner.swift`
  - `Tests/NoteItTests/BenchStatsTests.swift`
  - `Tests/NoteItTests/BenchFixtureTests.swift`
- Modify: `App/AppDelegate.swift`, `App/NoteItApp.swift`, `scripts/build_app.sh`

Steps:
- [ ] Implement `BenchStats`: median, nearest-rank p95, min and max.
- [ ] Implement `BenchFixture.populate` (the one shared fixture, spec §8):
  - uses a seeded `SystemRandomNumberGenerator` replacement (a small SplitMix64);
  - creates 20 notebooks and tags;
  - preassigns every note's UUID from the seeded generator before any note is created, and picks each note's link targets (`linksPerNote` on average, plus the hub note's `hubBacklinks` sources) from those UUIDs;
  - builds each note's complete body first: 1–40 KB with headings, lists, checklists, a code block, web links and its note links already in the stored form (`noteit://note/<UUID>`), and one note with `longNoteParagraphs` paragraphs;
  - creates each note with exactly one call, `createNote(in:initial:id:)` (linking's appended `id:` parameter, with foundations' `postsLocalChange` left at its default), passing the full body and the preassigned UUID, so a link may point at a note created later in the loop. It never calls `updateBody` and never changes a body after creation; if a change after creation ever becomes unavoidable, it goes through `editBody`;
  - finishes with `flush()`, so every `DerivedIndex` indexer sees the notes.
- [ ] `BenchRunner.runIfRequested(environment:)`:
  - It's called first in `applicationWillFinishLaunching`.
  - Without `NOTEIT_DATA_DIR` it prints "Benchmarks need NOTEIT_DATA_DIR" and exits 2.
  - With `NOTEIT_BENCH_FIXTURE` it populates and exits 0.
  - Otherwise it runs the requested suite as in spec §8 (`links` and `semantic` are added in T15a and T15b; until then they write a "skipped" result), writes `BenchResult` JSON to `NOTEIT_BENCH_OUT` (or `<data dir>/bench-<suite>.json`), and calls `NSApp.terminate`.
- [ ] `launch` reads `kinfo_proc.kp_proc.p_starttime` via `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()])`. When the main window is key with an editor, it posts a key-down/up for "x" and stops at the editor's `textDidChange`.
- [ ] `search` and `palette` use `ContinuousClock`.
- [ ] `palette` drives `PaletteModel(store:host:)` and awaits `items` through Combine.
- [ ] Machine info comes from `sysctlbyname("hw.model")` and `machdep.cpu.brand_string`. Version and commit come from `Info.plist` (`CFBundleShortVersionString`, plus a new `NoteItGitCommit` key that `scripts/build_app.sh` writes from `git rev-parse --short HEAD`). A missing key reads "unknown".
- [ ] Write the tests:
  - `testMedianOddEven`
  - `testP95NearestRank`
  - `testEmptySamples`
  - `testFixtureIsDeterministic` (same seed gives the same titles and counts on 50 notes)
  - `testFixtureLinkShape` (on 200 notes: about `linksPerNote` links per note in the stored form, the hub has `hubBacklinks` sources, the long note has `longNoteParagraphs` paragraphs)
  - `testFixtureCreatesEachNoteOnce` (on 50 notes: every note's ID is the preassigned one, `localNoteChange` is posted with `kind: created` once per note and never with `kind: edited`, and Version History has no entries)
  - `testRunnerRefusesWithoutDataDir`
  - `testSuiteSelection` (`NOTEIT_BENCH=all` selects every `BenchSuite`; an unknown name exits 2)
  - `testSkippedResultEncodes` (a result with `skippedReason` and no stats round-trips)
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "BenchStatsTests|BenchFixtureTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Commit `feat(bench): add in-app benchmark harness`.

### Task 15: Bench script and published numbers
**Files:**
- Create:
  - `scripts/bench.sh`
  - `scripts/bench_report.py`
  - `docs/performance.md`
- Modify:
  - `.gitignore` (add `.bench/`)
  - `docs/development.md`
  - `docs/roadmap.md`
  - `README.md`

Steps:
- [ ] `bench.sh`:
  - `set -euo pipefail`; `swift build -c release`;
  - fixture into `.bench/library-<n>` if missing;
  - for each run, `cp -R` it to `.bench/run`;
  - `launch` runs `--runs` times; the other suites run once each (they loop internally);
  - results go to `.bench/results/`;
  - then `python3 scripts/bench_report.py .bench/results docs/performance.md`.
- [ ] `bench_report.py` merges the launch runs into one sample set and writes a Markdown table (Metric, Median, p95, Target, Met) plus the machine, macOS, NoteIt version, commit and date between the markers. A skipped result shows "not measured" with its reason.
- [ ] `docs/performance.md`: what each metric means, the targets (including linking's and private-ai's rows from spec §8), how to reproduce, the 500-note Apple Notes import time from T11, and the table.
- [ ] Run `./scripts/bench.sh --notes 10000 --runs 10` on an Apple silicon Mac; it must exit 0 and rewrite the table between the markers in `docs/performance.md`. Commit the table. Report any target that was missed in the doc.
- [ ] Update `docs/development.md` (the `NOTEIT_BENCH`, `NOTEIT_BENCH_OUT` and `NOTEIT_BENCH_FIXTURE` env vars, and the script) and `README.md` (link to the numbers). Delete `.bench/run`.
- [ ] Commit `docs: publish performance numbers`.

### Task 15a: Links suite (needs linking)
**Files:**
- Create `Bench/BenchSuites+Links.swift`.
- Modify:
  - `Bench/BenchRunner.swift`
  - `Tests/NoteItTests/BenchFixtureTests.swift`
  - `docs/performance.md`

Steps:
- [ ] `links` measures, on the main actor with `ContinuousClock`:
  - link suggestions: typing a 12-character title one character at a time into linking's `LinkSuggester` over the fixture, 5 rounds;
  - backlinks for the fixture's hub note, 20 times;
  - loading `link-index.json` from `rootURL`, 5 times, after the index is built once.
- [ ] Wait for linking's index to finish building before sampling. If the index or `LinkSuggester` is unavailable, write a "skipped" result with the reason.
- [ ] Write the tests:
  - `testLinksSuiteFindsHubBacklinks` (on a 200-note fixture, the hub's backlink count matches `hubBacklinks`)
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "BenchFixtureTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Run `./scripts/bench.sh --notes 10000 --runs 10`; it must exit 0 and the table must have a measured `links` row (not "not measured"). Commit the updated table, with any missed linking target reported.
- [ ] Commit `feat(bench): add links suite`.

### Task 15b: Semantic suite (needs private-ai)
**Files:**
- Create `Bench/BenchSuites+Semantic.swift`.
- Modify:
  - `Bench/BenchRunner.swift`
  - `Tests/NoteItTests/BenchStatsTests.swift`
  - `docs/performance.md`
  - `docs/development.md`

Steps:
- [ ] `semantic` turns Smart Features on in the copied fixture library, times the first full semantic index build once, records the index size on disk, then runs 20 fixed queries 5 times through `SmartSearchService`, each sample covering query embedding plus search.
- [ ] Without an on-device embedding model, or if Smart Features can't be turned on, it writes a "skipped" result with the reason.
- [ ] It uses the shared `NOTEIT_BENCH_FIXTURE` library. If private-ai's plan still has its own benchmark library, this suite replaces it for published numbers; tell private-ai's owner.
- [ ] Write the tests:
  - `testSemanticSkippedWithoutModel` (with the model lookup stubbed to nil, the result has `skippedReason` and no stats)
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "BenchStatsTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Run `./scripts/bench.sh --notes 10000 --runs 10`; it must exit 0 and the table must have a `semantic` row (measured, or "not measured" with the reason when no on-device model is present). Commit the updated table, with any missed private-ai target reported.
- [ ] Commit `feat(bench): add semantic search suite`.

### Milestone 7: Checklists

### Task 16: Checklist outline, ⌘↩, nesting and checked style
**Files:**
- Create:
  - `Editor/ChecklistOutline.swift`
  - `Editor/NoteItTextView+Checklist.swift`
  - `Tests/NoteItTests/ChecklistOutlineTests.swift`
  - `Tests/NoteItTests/ChecklistEditingTests.swift`
- Modify:
  - `Editor/EditorStyles.swift`
  - `Editor/FormatCommand.swift`
  - `Editor/TextFormatter.swift`
  - `Editor/NoteItTextView.swift`
  - `Editor/MarkdownShortcuts.swift` (only if pasted or typed `- [x]` misses the checked style)
  - `docs/keyboard-shortcuts.md`

Steps:
- [ ] Read `EditorStyle.listMarker(in:)`, `listLevel(of:)`, `TextFormatter.toggleCheckbox`, `applyCheckedStyle`/`removeCheckedStyle` and `NoteItTextView.insertTab`/`insertBacktab` first; the outline builds on them.
- [ ] `ChecklistOutline(_:)` reads the storage's paragraphs into items. A list is a contiguous run of one list kind; quotes, tables and code blocks end a list. `parent` is the nearest earlier item with a lower level in the same list.
- [ ] ⌘↩: add a second `KeyShortcut` entry for `toggleCheckbox` in `FormatCommand.swift`. `MenuShortcutRules` then reserves it. The Format menu keeps showing ⇧⌘U. Quick Capture's panel keeps ⌘↩ as Save because it handles the key first.
- [ ] Nesting:
  - `insertTab`/`insertBacktab` on a list item change the level of the item's `subtreeRange` as one edit, not just the line.
  - Tab does nothing when `canIndent` is false (no beep, no tab character). `EditorStyle.maxListLevel` is 5.
  - Return on an empty nested item outdents it one level; on an empty top-level item it ends the list as today.
- [ ] Checked style: every check path calls the same `TextFormatter` style helper (click, ⇧⌘U, ⌘↩, the VoiceOver action, paste, Markdown and `noteit-doc` import of `- [x]`). Only the item's own paragraph gets the style; nested items keep theirs. With Increase Contrast, checked text uses `secondaryLabelColor`. The checkbox draws filled with the accent color.
- [ ] Write the tests:
  - `ChecklistOutlineTests`: `testItemsLevelsAndParents`, `testSubtreeRangeIncludesNestedItems`, `testCanIndentAtMostOneDeeper`, `testCanIndentStopsAtMaxLevel`, `testListsSplitByKindAndBlocks` (quote, table and code block end a list)
  - `ChecklistEditingTests` (a `NoteItTextView` in a test harness):
    - `testCommandReturnTogglesCurrentLine`
    - `testCommandReturnConvertsPlainLine`
    - `testCommandReturnIsReservedEditorShortcut` (`MenuShortcutRules` rejects ⌘↩ for a menu command)
    - `testTabIndentsSubtree` and `testShiftTabOutdentsSubtree`
    - `testTabBeyondRuleDoesNothing`
    - `testReturnOnEmptyNestedItemOutdents`
    - `testCheckedStyleOnlyOnOwnParagraph`
    - `testEveryCheckPathAppliesStyle` (click, ⇧⌘U, ⌘↩, accessibility action, paste)
    - `testUncheckRemovesStyle`
    - `testCheckIsOneUndoStep`
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ChecklistOutlineTests|ChecklistEditingTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Also run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MarkdownRoundTripTests 2>&1 | tail -20` to confirm imported checklists keep their state; expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Add ⌘↩ (Mark as Checked) to `docs/keyboard-shortcuts.md`.
- [ ] Commit `feat(editor): add checklist nesting and Command-Return toggle`.

### Task 17: Keep checked items at the bottom (parallel with T18)
**Files:**
- Create `Tests/NoteItCoreTests/NoteMetaChecklistFieldTests.swift`, `Tests/NoteItTests/ChecklistFieldSyncTests.swift`.
- Modify:
  - `Sources/NoteItCore/Models/NoteMeta.swift` (the file foundations moves `NoteMeta` into)
  - `Sources/NoteItCore/Models/CodingKeyNames.swift` (foundations Task 3.5)
  - `Model/NoteStore.swift`
  - `Editor/ChecklistOutline.swift`
  - `Editor/NoteItTextView+Checklist.swift`
  - `Views/EditorContainerView.swift`
  - `Palette/PaletteCommandRegistry.swift`
  - `Tests/NoteItTests/ChecklistOutlineTests.swift`
  - `Tests/NoteItTests/ChecklistEditingTests.swift`
  - `Tests/NoteItTests/PaletteCommandRegistryTests.swift`

Steps:
- [ ] Add `NoteMeta.checkedItemsToBottom: Bool?`. It's in the revision fields only when it isn't nil (program §4.5), so existing revisions don't change.
- [ ] Add `"checkedItemsToBottom"` to `NoteMeta.ownedCodingKeys` in `Models/CodingKeyNames.swift`. Without it `RawMetaOverlay` treats the key as unknown and takes it from the last decrypted remote meta, so a local set or clear would be overwritten on export. Foundations' `ModelCodingTests` check (the set equals the encoded keys with every optional set) must keep passing.
- [ ] Tell markdown-storage's owner so it's stored with the other `NoteMeta` fields, and the web and phone owners so their `RawMetaOverlay` keeps it.
- [ ] Add `NoteStore.setCheckedItemsToBottom(_:for:)`, which changes only that field, sets a new revision and saves like other metadata changes.
- [ ] `checkedToBottomOrder()` sorts stably inside each list and level; nested items move with their parent. `placementAfterToggle(of:)` gives the target index: the top of the checked items at the end of the item's level when checking, just after the last unchecked item when unchecking.
- [ ] Editor:
  - With the toggle on, a check in the editor applies the check and the move in one `shouldChangeText`/`didChangeText` group with one undo step ("Check" or "Uncheck").
  - Turning the toggle on sorts every checklist once, as one undo step ("Move Checked Items to Bottom"). Turning it off changes nothing in the text.
  - Checks made through `NoteStore.editBody` don't move items.
- [ ] **Keep Checked Items at Bottom** in the editor header's ⋯ menu, the editor context menu (checklist section) and the palette (`checkedItemsToBottom`), with a check mark when on. It's unavailable for locked notes and Recently Deleted.
- [ ] Write the tests:
  - `NoteMetaChecklistFieldTests`: `testNilFieldKeepsRevision`, `testFieldInRevisionWhenSet`, `testCodableRoundTrip`, `testOwnedCodingKeysIncludeField`
  - `ChecklistFieldSyncTests` (through `NoteStore` and the export path, as `RawMetaStoreTests` does):
    - `testSetOverridesRemoteValue`: apply a remote meta with no `checkedItemsToBottom` key and `"futureField": 1`, call `setCheckedItemsToBottom(true, for:)`, export; the sealed plaintext has `"checkedItemsToBottom": true` and `futureField`;
    - `testClearRemovesRemoteValue`: apply a remote meta with `"checkedItemsToBottom": true` and `"futureField": 1`, call `setCheckedItemsToBottom(false, for:)`, export; the plaintext has no `checkedItemsToBottom` key and still has `futureField`;
    - `testRemoteOverlayRoundTrip`: apply a remote meta with `"checkedItemsToBottom": true` and `"futureField": 1`; the note reads `true`; a local title edit exports both keys unchanged.
  - `ChecklistOutlineTests`: `testCheckedToBottomOrderIsStable`, `testSortStaysWithinListAndLevel`, `testNestedItemsMoveWithParent`, `testPlacementAfterCheckAndUncheck`, `testAlreadySortedReturnsNil`
  - `ChecklistEditingTests`: `testCheckMovesItemWhenOn`, `testUndoRestoresPlaceAndState`, `testTurningOnSortsOnceAsOneUndo`, `testTurningOffKeepsOrder`, `testEditBodyCheckDoesNotMove`, `testThousandItemSortIsOneReplacement`
  - In `PaletteCommandRegistryTests`: the new command is present and unavailable without a selected note.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "NoteMetaChecklistFieldTests|ChecklistFieldSyncTests|ModelCodingTests|ChecklistOutlineTests|ChecklistEditingTests|PaletteCommandRegistryTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run the sync suites to confirm unchanged revisions: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "SyncEngineTests|SyncPlannerTests" 2>&1 | tail -20`, expecting `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Commit `feat(editor): keep checked items at the bottom per note`.

### Task 18: Drag to reorder and Move Item Up/Down (parallel with T17)
**Files:**
- Modify:
  - `Editor/ChecklistOutline.swift`
  - `Editor/NoteItTextView+Checklist.swift`
  - `Editor/NoteItTextView.swift`
  - `Editor/FormatCommand.swift`
  - `Palette/PaletteCommandRegistry.swift`
  - `Design/Tokens.swift`
  - `Tests/NoteItTests/ChecklistOutlineTests.swift`
  - `Tests/NoteItTests/ChecklistEditingTests.swift`
  - `Tests/NoteItTests/PaletteCommandRegistryTests.swift`

Steps:
- [ ] `move(_:before:level:)` returns the single replacement that moves an item's subtree to a new place and level, or nil when the target breaks the nesting rules or lies outside the list.
- [ ] Grip handle: a tracking area per visible checklist paragraph shows the handle in the left margin, outside the text column; `NoteItLayoutManager` (in `NoteItTextView.swift`) draws it and the insertion line. Not drawn when the text view isn't editable (the cheat sheet), in print or in export.
- [ ] Dragging the handle starts an internal drag session; the insertion line's horizontal position picks the level; near the top or bottom edge it autoscrolls; Esc or a drop outside the list cancels. A drop applies the move as one undo step, "Move Item".
- [ ] `moveItemUp` and `moveItemDown` as `FormatCommand`s with no default shortcut, in the editor context menu and palette, and as custom accessibility actions on the item (next to Toggle Checkbox). Each swaps the item's subtree with the previous or next sibling subtree.
- [ ] Write the tests:
  - `ChecklistOutlineTests`: `testMoveSubtreeBeforeTarget`, `testMoveChangesLevelWithinRules`, `testMoveOutsideListReturnsNil`, `testMoveKeepsQuotesAndTablesIntact`
  - `ChecklistEditingTests`: `testMoveItemUpSwapsSubtrees`, `testMoveItemDownAtEndDoesNothing`, `testMoveIsOneUndoStep`, `testMovedCheckedItemKeepsStyle`, `testNoHandleWhenNotEditable`
  - In `PaletteCommandRegistryTests`: `moveItemUp` and `moveItemDown` are present.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ChecklistOutlineTests|ChecklistEditingTests|PaletteCommandRegistryTests" 2>&1 | tail -20` and expect `Executed N tests, with 0 failures`. Run both builds (the debug and the release app build): `swift build 2>&1 | tail -3` and `swift build -c release 2>&1 | tail -3`, each ending with `Build complete!`, no errors and exit 0.
- [ ] Manual check with `NOTEIT_DATA_DIR=.selftest/checklist`: drag an item with nested items to another level, undo it, and check a 300-item list scrolls while dragging. With VoiceOver, use Move Item Down on an item.
- [ ] Commit `feat(editor): drag to reorder checklist items`.

### Task 18a: Milestone 7 docs
- [ ] Update the docs:
  - `docs/keyboard-shortcuts.md`: Tab/⇧Tab nesting rules; Move Item Up/Down (no default).
  - `docs/accessibility.md`: Move Item Up/Down rows in the VoiceOver checklist.
  - `docs/roadmap.md`: checklist polish done.
  - `README.md`: the checklist line in the product tour.
- [ ] Verify: `grep -n "Move Item Up" docs/keyboard-shortcuts.md docs/accessibility.md`, `grep -n "⇧Tab" docs/keyboard-shortcuts.md` and `grep -in "checklist" docs/roadmap.md README.md` each print at least one line.
- [ ] Commit `docs: document checklist polish`.

## Self-review

- **Spec coverage:**

  | Spec section | Tasks |
  |--------------|-------|
  | §1 library settings | T1 |
  | §2 cheat sheet | T6, T7 |
  | §3 floating notes | T8 |
  | §4 board | T9, T10 |
  | §5 typography | T2 |
  | §6 onboarding | T11, T11a |
  | §7 accessibility | T12, T13 (plus card accessibility in T10, Move Item actions in T18) |
  | §8 benchmarks | T14, T15, T15a, T15b |
  | §9 Quick Capture motion | T5 |
  | §10 pinning | T3 |
  | §11 sync status | T4 |
  | §12 checklist polish | T16, T17, T18 |

- **Program contract:**
  - §4: `boards/` registered in `RemoteLayout.prefixes` (depth 1, `.storeKey`) with `layout-keys.json` cases; no board tombstones, boards deleted with their notebook and orphans removed by a Mac; board records keep unknown keys through `RawMetaOverlay` and foundations' per-kind raw-meta lifecycle as kind `boards` (§4.5); `NoteMeta.checkedItemsToBottom` is in revision fields only when set and is in `NoteMeta.ownedCodingKeys`; the notebook record gains nothing (T9, T17).
  - §6: floats and the board pane register with `OpenEditorRegistry` as editors, visible cheat sheets as observers; editor-originated checklist edits go through the text view (T7, T8, T10, T16–T18).
  - §7: `library-settings.json`, `boards/` and `sync-meta-raw/boards/` in `rootURL` (T1, T9).
  - §8: locked notes can't float or be cheat sheets (T7, T8).
  - §9: `cheatSheet` (13) and `toggleFloatingNotes` (14) each added with tile and handler in one task, tested with the program's rules (T7, T8); Pin ⌥⌘P first in `NoteCommands`; zoom ⌃⌘= / ⌃⌘- / ⌃⌘0; sidebar order (T2, T3); the window inspector stays linking's (T10).
  - §10: no Local API routes; `noteit://float` and `noteit://cheat-sheet` through `URLRouteRegistry` (T7, T8).
  - §12: board record, checklist polish, both onboarding paths, Evernote and Notion import, no storage choice in onboarding, shared bench fixture with links and semantic suites (T9, T11, T11a, T14–T18).
- **Frozen rules:**
  - New hotkeys follow the frozen table order and are unbound by default (T7, T8).
  - Menu shortcuts only go through `MenuShortcutCommand` (T2, T3). ⌘↩ is an editor `KeyShortcut`, reserved by `MenuShortcutRules` (T16).
  - Every command is in the palette (T2, T3, T7, T8, T10, T11, T17, T18).
  - Settings stay in existing tabs: Editor (T2) and General (T7, the frozen `GeneralSettingsSection.cheatSheet`, made available).
  - Note bodies are only read and written through `NoteStore` (`body(for:)`, `RichTextEditor`, `editBody`).
- **Types:**
  - `LibrarySettings` and `updateLibrarySettings` are defined in T1 and used by T2, T7, T8 and T10.
  - `CheatSheetHoldLogic` is defined in T6 and used in T7.
  - `EditorRole` is defined in T7 and the `OpenEditorRegistry` observer API comes from foundations task 4.5; `EditorRole` is used in T8 and T10, and T18 checks `isEditable` for the handle.
  - `SurfaceURLRoutes` is created by whichever of T7 and T8 lands first.
  - `NoteAccessibility.cardLabel` is defined in T12. T10 uses a local string until then and switches to it in T12.
  - `BoardLayout` and `BoardGeometry` are defined in T9 and used in T10.
  - `ChecklistOutline` is defined in T16 and extended in T17 and T18.
  - `unsyncedCount` is defined in T4 at both levels; T9 extends it to `boardBases`.
- **Placeholders:** none. Steps that depend on details read from the code at the time: the `EditorStyle` sentinel values in T12 and T16, and the `SyncEngine` state access in T4 and T9.
