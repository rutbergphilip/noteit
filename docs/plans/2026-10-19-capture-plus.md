# Capture Plus Implementation Plan

**Goal:** Add five capture paths to NoteIt: Screenshot to Text (region selection plus on-device text recognition, including optional background recognition of images already in notes), voice notes with on-device transcription, an "Append to Today" hotkey panel over `linking`'s daily notes, email-in over IMAP, and heuristic auto titles for every capture.

**Architecture:** Capture features live next to the existing capture code in `Sources/NoteIt/Capture/` and reuse `CaptureController`'s outcome and toast flow. New notes are created with `NoteStore.createNote` and `createImportedNote`; every change to an existing note's text goes through `NoteStore.editBody` (foundations, from `organise`). Image text is kept in a separate local index (`attachment-text.json` in `NoteStore.rootURL`) maintained by an indexer registered with the `DerivedIndex` registry (foundations task 4.4). Capture Plus registers an `ImageTextProviding` provider (the protocol is `organise`'s, defined in wave 1 with no provider), and `organise`'s search reads it for its "Found in an image" match source. The IMAP and MIME code lives in a new library target `NoteItMail` (Foundation and Network only) so it can be tested without AppKit. The app-side mail code (`Sources/NoteIt/MailIn/`) turns parsed messages into notes. Append to Today is a panel over `linking`'s `DailyLogAppender` (built in foundations); Capture Plus has no daily-note or append code of its own. The program design ([2026-10-19-program-design.md](../specs/2026-10-19-program-design.md)) is the contract this plan follows.

**Tech Stack:** Swift 5 language mode on the Swift 6.3 toolchain, macOS 14 minimum. Uses Vision (`VNRecognizeTextRequest`), Speech (`SFSpeechRecognizer`, and `SpeechAnalyzer` on macOS 26 when the compiler supports it), AVFoundation (`AVAudioRecorder`, `AVAssetExportSession`, `AVAudioPlayer`), Network.framework (`NWConnection` with TLS), Security (Keychain, certificate fingerprints), and `/usr/sbin/screencapture`. No new third-party dependencies.

**Spec:** [docs/specs/2026-10-19-capture-plus-design.md](../specs/2026-10-19-capture-plus-design.md)

---

## Conventions for every task

- Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Suite> 2>&1 | tail -20`. Expected: `Test Suite '<Suite>' passed` with 0 failures. Run the full suite (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`) at the end of every milestone.
- Builds: `swift build 2>&1 | tail -5` and, at the end of each milestone, `swift build -c release 2>&1 | tail -5`. Both must end with `Build complete!` and add no new warnings.
- Manual runs never touch real data. Start the app with `NOTEIT_DATA_DIR=<project>/.selftest/<name> swift run NoteIt`. Permission-dependent features (screen recording, microphone, speech) need the app bundle: build it with `NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` and then open `.selftest/app/NoteIt.app` with the same `NOTEIT_DATA_DIR` (for example `NOTEIT_DATA_DIR="$PWD/.selftest/<name>" .selftest/app/NoteIt.app/Contents/MacOS/NoteIt`).
- Store tests use a temporary directory: `NoteStore(location: LibraryLocation(url: tmp, seedsFreshLibrary: false))`. Follow the pattern in `Tests/NoteItTests/CaptureControllerTests.swift` (injected `Environment`, no real system calls).
- System services (screencapture, Vision, Speech, AVAudioRecorder, Network, Keychain) are always behind a protocol or a closure in an `Environment` struct so tests can replace them.
- New global hotkeys go at their positions in the program's frozen hotkey table (`screenshotToText` 9, `recordVoiceNote` 10, `appendToToday` 11), whatever order the plans merge in, and are unbound by default. The task that adds a case also updates the `ShortcutsSettingsView` tile switch and the `AppDelegate` handler switch. Bindings are saved by raw value, so positions don't affect saved bindings.
- Code outside the editor never changes note text directly: it calls `NoteStore.editBody`. Nothing in this plan calls `handOverPendingEdits`, `updateBody` or sets `externallyUpdatedNoteID` itself.
- Derived and per-Mac files (`attachment-text.json`, `mail-in-state.json`, `capture-pending/`) live in `NoteStore.rootURL`, never in a Markdown library's `contentRootURL`.
- Helpers, extensions and entitlements go through the embeds table in `scripts/build_app.sh` (added by `automation` in foundations task 5.5). This plan adds no helpers or extensions; its one entitlement goes in `Resources/NoteIt.entitlements`, which the app's row uses.
- New commands get a palette entry in `PaletteCommandRegistry`. Menu items added in this plan have no default menu shortcut, so `App/MenuShortcuts.swift` does not change.
- User-facing strings are plain English, sentence case for messages, title case for menu items and buttons.
- One Conventional Commit per task, scope `capture`, `mail`, `search` or `docs`, for example `feat(capture): add screenshot capturer`. Do not push.
- Debug hooks added in this plan only work in debug builds (`#if DEBUG`): `NOTEIT_DEBUG_SCREENSHOT_FILE` (use this PNG instead of running screencapture), `NOTEIT_DEBUG_VOICE_FILE` (use this audio file instead of recording), `NOTEIT_MAIL_LIVE_TEST` (opt-in live IMAP test, see Task 23).

## File structure

```
Package.swift                                   modify: NoteItMail target, NoteItMailTests, NoteIt depends on NoteItMail
Sources/NoteItMail/
  MailMessage.swift                             parsed message model (headers, parts, attachments)
  IMAPCommand.swift                             command builder, literal and quoting rules
  IMAPResponseParser.swift                      tagged/untagged responses, FETCH, literals, capabilities
  IMAPTransport.swift                           protocol IMAPTransport
  NWIMAPTransport.swift                         NWConnection TLS transport, fingerprint check
  IMAPClient.swift                              login, select, search, fetch, store, move
  ModifiedUTF7.swift                            mailbox name encoding (RFC 3501 5.1.3)
  MIMEParser.swift                              multipart tree, headers, RFC 2047 words
  MIMEDecoding.swift                            base64, quoted-printable, charsets
Sources/NoteIt/Capture/
  CaptureCommands.swift                         single entry point for hotkeys, menus, palette, menu bar
  CaptureLimits.swift                           size and time limits
  CapturePermissions.swift                      screen recording, microphone, speech checks
  CaptureTitler.swift                           heuristic titles, CaptureTitleRefining protocol and registration
  ScreenshotCapturer.swift                      screencapture subprocess
  TextRecognizer.swift                          Vision text recognition
  RecognizedTextLayout.swift                    lines -> paragraphs (pure)
  ScreenshotNoteBuilder.swift                   image + text + source -> NSAttributedString
  ScreenshotCaptureController.swift             flow, outcomes, toasts
  AttachmentTextIndexer.swift                   background recognition of existing images
  VoiceRecorder.swift                           AVAudioRecorder wrapper, CAF -> m4a
  VoiceRecorderPanel.swift                      floating recorder panel
  Transcriber.swift                             Transcriber protocol, SF and SpeechAnalyzer
  TranscriptChunker.swift                       chunk boundaries, paragraph rules (pure)
  TranscriptionQueue.swift                      persisted pending jobs
  VoiceNoteController.swift                     flow, outcomes, toasts
  TranscriptPlacement.swift                     placeholder replacement inside an editBody closure (pure)
  AppendTodayController.swift                   availability, calls linking's DailyLogAppender
  AppendTodayPanel.swift                        single-line panel
Sources/NoteIt/MailIn/
  MailInConfiguration.swift                     settings model (JSON in UserDefaults)
  MailInKeychain.swift                          password and pinned fingerprint
  MailInState.swift                             mail-in-state.json, imported hashes
  MailInStatus.swift                            status enum, backoff
  MailHTMLSanitizer.swift                       allowlist sanitizer
  MailNoteBuilder.swift                         MailMessage -> note body
  MailInController.swift                        scheduling, check run, status
Sources/NoteIt/Model/
  AttachmentTextStore.swift                     attachment-text.json
  NoteStore+CapturePlus.swift                   imageText, imageAttachments
Sources/NoteIt/Editor/
  AudioAttachmentCell.swift                     play/pause pill for audio attachments
Sources/NoteIt/Settings/
  MailInSettingsSection.swift                   Email to NoteIt section
  MailInSetupSheet.swift                        account setup sheet
  CapturePlusSettingsRows.swift                 text recognition and voice rows
Tests/NoteItMailTests/
  IMAPResponseParserTests.swift
  IMAPCommandTests.swift
  IMAPClientTests.swift                         scripted fake transport
  ModifiedUTF7Tests.swift
  MIMEParserTests.swift
  Fixtures/                                     .eml and IMAP transcript fixtures
  IMAPLiveTests.swift                           skipped unless NOTEIT_MAIL_LIVE_TEST is set
Tests/NoteItTests/
  CaptureTitlerTests.swift
  RecognizedTextLayoutTests.swift
  ScreenshotCaptureControllerTests.swift
  AttachmentTextStoreTests.swift
  AttachmentTextIndexerTests.swift
  ImageTextSearchTests.swift
  AppendTodayControllerTests.swift
  TranscriptPlacementTests.swift
  TranscriptChunkerTests.swift
  VoiceNoteControllerTests.swift
  MailHTMLSanitizerTests.swift
  MailNoteBuilderTests.swift
  MailInControllerTests.swift
```

Modified files:

- `Sources/NoteIt/Hotkeys/HotkeyAction.swift`: three new cases at positions 9–11.
- `Sources/NoteIt/Settings/ShortcutsSettingsView.swift`: tile colours for the three cases.
- `Sources/NoteIt/App/AppDelegate.swift`: hotkey dispatch, indexer registration, mail-in start, recovery of pending recordings.
- `Sources/NoteIt/App/NoteItApp.swift`: File › Capture submenu in `NoteItCommands`.
- `Sources/NoteIt/Capture/CaptureController.swift`: new `CaptureOutcome` cases and `CaptureToastButton` cases, `saved` gains `detail`.
- `Sources/NoteIt/Capture/CaptureFormatter.swift`: source line extracted into `sourceLine(for:title:)` and `sourceLine(linkingTo:label:appName:)` (reused by `web-clipper`); titles go through `CaptureTitler`.
- `Sources/NoteIt/Palette/PaletteController+Global.swift`: `TransientSurfaceHider.Surface.voiceRecorder` (Task 16) and `.appendToday` (Task 20).
- `Sources/NoteIt/Design/Tokens.swift`: hotkey tile colours, Append to Today panel size.
- `Sources/NoteIt/Palette/PaletteCommandRegistry.swift`: four commands.
- `Sources/NoteIt/Model/NoteStore.swift`: owns an `AttachmentTextStore`; no new hooks (the indexer uses the `DerivedIndex` registry).
- `organise`'s search: Capture Plus registers its `ImageTextProviding` provider, which turns on the "Found in an image" match source (Task 10).
- `Sources/NoteIt/Settings/Preferences.swift`: new `PrefKey` and `PrefDefault` values.
- `Sources/NoteIt/Settings/GeneralSettingsView.swift` (already a scrolling form, foundations task 6.5): new rows in the `capture` section, the Email to NoteIt section in the `emailIn` case, and `GeneralSettingsSection.emailIn.isAvailable` set to true (Task 27).
- `Sources/NoteIt/MenuBar/MenuBarView.swift`: footer buttons for screenshot and voice note.
- `Sources/NoteIt/Editor/NoteItTextView.swift`: audio attachment cell, "Insert Transcript" context menu item.
- `scripts/build_app.sh`: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`. No new embeds rows.
- `Resources/NoteIt.entitlements`: `com.apple.security.device.audio-input`, signed through the app's embeds row.
- `docs/architecture.md`, `docs/known-limitations.md`, `docs/roadmap.md`, `docs/keyboard-shortcuts.md`, `docs/development.md`, `README.md`.

## Frozen interfaces

These signatures are fixed once their task lands. Later tasks and other sub-projects build on them. Bodies are left out.

Consumed, not defined here (frozen by foundations and the owning plans): `NoteStore.persistNow(_ id: UUID) throws` (foundations; returns once that note's body, with its sidecar, and the library metadata are durable, throws on any failure), `NoteStore.editBody(_:actionName:versioning:extras:_:)` (with `versioning: EditBodyVersioning = .recordCurrent` and `extras: ContainerExtras? = nil`, which only `NoteStore` itself passes), `EditBodyVersioning` and `OpenEditorRegistry` (organise, foundations task 4.5), the `DerivedIndex` protocol and `NoteStore.registerDerivedIndex(_:)` (organise, foundations task 4.4; hooks `noteChanged(_:body:)`, `noteRemoved(_:)`, `metadataChanged(_:)`, `rebuild(notes:body:)`, `flush()`), `ImageTextProviding` (`func imageText(for noteID: UUID) -> String?`) and `NoteStore.registerImageTextProvider(_:)` (organise, wave 1), `NoteBodyStorage` (foundations task 4.1), `NoteStore.dailyNote(for:createIfMissing:)`, `DailyLogAppender` and `DailyLogError` (linking, foundations task 4.6), `DailyNotes.isAvailable`, `DailyLogLine`, `TextFold.fold`, `CaptureTitle` and `GeneralSettingsSection` (`NoteItCore`), `NoteMeta.isLocked` (sync-security, foundations task 4.3), `AttachmentLimit.maxBytes` (`NoteItDoc`). Capture Plus code reaches `DailyLogAppender` through a closure in `AppendTodayController.Environment`, so its exact signature stays `linking`'s.

```swift
// Sources/NoteIt/Hotkeys/HotkeyAction.swift (positions 9-11 of the frozen table)
case openToday            // 7, linking
case showTasks            // 8, organise
case screenshotToText     // 9
case recordVoiceNote      // 10
case appendToToday        // 11
case askNotes             // 12, private-ai

// Sources/NoteIt/Capture/CaptureController.swift
enum CaptureOutcome: Equatable {
    case saved(noteID: UUID, notebookName: String?, title: String, detail: String? = nil)
    case nothingSelected, notTrusted, clipboardEmpty, noteItFrontmost
    case screenRecordingNotAllowed
    case clipboardHasNoImage
    case microphoneNotAllowed
    case savedWithoutTranscript(noteID: UUID, notebookName: String?, title: String, reason: String)
    case appended(noteID: UUID, dayTitle: String, line: String)
    case dailyNotesUnavailable
    case offerImageTextIndexing
    case needsAppBundle
    case screenshotNotSaved(noteID: UUID)        // persistNow threw; the PNG stays in capture-pending/
}
enum CaptureToastButton: String, Equatable {
    case allowAccess, captureClipboard, useClipboardImage, allowScreenRecording, openPrivacySettings
    case turnOnImageText, notNow
    case tryAgain
}

// Sources/NoteIt/Capture/CaptureLimits.swift
enum CaptureLimits {                                  // the attachment cap is NoteItDoc's AttachmentLimit.maxBytes
    static let maxPNGBytes = 8 * 1024 * 1024
    static let maxRecognitionPixels = 4096
    static let maxRecognizedCharacters = 100_000
    static let maxRecordingDuration: TimeInterval = 45 * 60
    static let minRecordingDuration: TimeInterval = 1
    static let screenshotTimeout: TimeInterval = 5 * 60
    static var pendingDirectory: URL { get }          // <data folder>/capture-pending
}

// Sources/NoteIt/Capture/CapturePermissions.swift
enum CapturePermissionStatus: Equatable { case allowed, denied, notDetermined, allowedAfterRestart }
protocol CapturePermission {
    var status: CapturePermissionStatus { get }
    func request() async -> CapturePermissionStatus
}
struct ScreenRecordingPermission: CapturePermission
struct MicrophonePermission: CapturePermission
struct SpeechRecognitionPermission: CapturePermission
enum AppBundleCheck { static var isRunningFromAppBundle: Bool { get } }

// Sources/NoteIt/Capture/CaptureTitler.swift
enum CaptureKind: Equatable { case screenshot, voiceNote, email(senderName: String?, senderAddress: String) }
struct CaptureTitleInput {
    var kind: CaptureKind
    var text: String?            // recognised text, transcript or email body text
    var subject: String?
    var pageTitle: String?
    var windowTitle: String?
    var date: Date
}
enum CaptureTitler {
    static let maxLength = 60
    static func title(for input: CaptureTitleInput, locale: Locale = .current) -> String
    static func meaningfulLine(in text: String) -> String?
    static func cleanSubject(_ subject: String) -> String
    static func shorten(_ text: String, to maxLength: Int = maxLength) -> String
    static func replaceTitle(in body: NSMutableAttributedString, ifEqualTo expected: String, with title: String) -> Bool  // title paragraph only, keeps its attributes
}
@MainActor protocol CaptureTitleRefining {                // owned here; private-ai provides the model-based implementation
    func refinedTitle(for noteID: UUID, kind: CaptureKind, heuristicTitle: String) async -> String?
}
@MainActor enum CaptureTitleRefinement {
    static var refiner: CaptureTitleRefining?                 // set by private-ai at launch; nil keeps heuristic titles
    static func refineIfUnchanged(noteID: UUID, kind: CaptureKind, heuristicTitle: String, store: NoteStore) async
}

// Sources/NoteIt/Capture/CaptureFormatter.swift (extracted from the private source line code)
extension CaptureFormatter {
    static func sourceLine(for source: CaptureSource, title: String) -> NSAttributedString
    static func sourceLine(linkingTo url: URL, label: String?, appName: String?) -> NSAttributedString   // reused by web-clipper
}

// Sources/NoteIt/Capture/ScreenshotCapturer.swift
enum ScreenshotResult: Equatable { case image(URL), cancelled, notAllowed, failed(String) }
protocol ScreenshotCapturing { func captureRegion(to url: URL) async -> ScreenshotResult }
struct ScreencaptureProcessCapturer: ScreenshotCapturing     // /usr/sbin/screencapture -i -x -o <url>

// Sources/NoteIt/Capture/TextRecognizer.swift
struct RecognizedLine: Equatable { var text: String; var box: CGRect; var confidence: Float }  // box in normalised Vision coordinates
protocol TextRecognizing { func recognize(_ image: CGImage, languages: [String]) async throws -> [RecognizedLine] }
struct VisionTextRecognizer: TextRecognizing                  // VNRecognizeTextRequest, revision 3, .accurate

// Sources/NoteIt/Capture/RecognizedTextLayout.swift
enum RecognizedTextLayout {
    static let minConfidence: Float = 0.3
    static func paragraphs(from lines: [RecognizedLine]) -> [String]
    static func text(from lines: [RecognizedLine]) -> String   // paragraphs joined by "\n\n", capped
}

// Sources/NoteIt/Capture/ScreenshotNoteBuilder.swift
enum ScreenshotNoteBuilder {
    static func encodedImage(from url: URL) throws -> (data: Data, fileName: String)   // PNG <= 8 MB else JPEG 0.85, <= AttachmentLimit.maxBytes
    static func body(title: String, image: Data, fileName: String,
                     text: String, source: CaptureSource?) -> NSAttributedString
}

// Sources/NoteIt/Model/AttachmentTextStore.swift
struct AttachmentTextFile: Codable, Equatable {
    static let currentVersion = 1
    static let engine = "vision-text-3"
    var version: Int
    var engine: String
    var images: [String: String]                  // sha256 hex -> folded text
    var notes: [UUID: NoteEntry]
    struct NoteEntry: Codable, Equatable { var updatedAt: Date; var shas: [String] }
}
@MainActor final class AttachmentTextStore {
    init(url: URL)                                // <NoteStore.rootURL>/attachment-text.json
    func text(forNote id: UUID) -> String?        // folded, images joined by " "
    func needsWork(noteID: UUID, updatedAt: Date) -> Bool
    func record(noteID: UUID, updatedAt: Date, images: [(sha: String, foldedText: String?)])
    func remove(noteID: UUID)
    func deleteAll()
    func save() throws
}

// Sources/NoteIt/Model/NoteStore+CapturePlus.swift
struct ImageAttachmentRef: Equatable { var sha256: String; var data: Data; var fileName: String }
extension NoteStore {
    func imageText(for id: UUID) -> String?      // nil when imageTextIndexing is off or the note is locked; backs the provider below
    func imageAttachments(in id: UUID) async -> [ImageAttachmentRef]   // via NoteBodyStorage; [] for locked notes
}

// Sources/NoteIt/Capture/AttachmentTextImageProvider.swift — registered at launch with NoteStore.registerImageTextProvider(_:)
@MainActor final class AttachmentTextImageProvider: ImageTextProviding {
    init(store: NoteStore)
    func imageText(for noteID: UUID) -> String?  // forwards to NoteStore.imageText(for:)
}

// Sources/NoteIt/Capture/AttachmentTextIndexer.swift
@MainActor final class AttachmentTextIndexer: ObservableObject, DerivedIndex {
    struct Progress: Equatable { var done: Int; var total: Int }
    @Published private(set) var progress: Progress?
    init(store: NoteStore, textStore: AttachmentTextStore, recognizer: TextRecognizing, environment: Environment = .live)
    // DerivedIndex: noteChanged schedules a pass 10 s later, noteRemoved drops the entry (also on lock),
    // metadataChanged marks a restored note, rebuild clears and re-reads everything, flush saves attachment-text.json.
    // All are no-ops while off.
    func catchUp(after delay: TimeInterval = 30)
    func stopAndDeleteIndex()
}

// Sources/NoteIt/Capture/TranscriptPlacement.swift (pure; runs inside an editBody closure)
enum TranscriptPlacement {
    static let placeholder = "Transcribing…"
    static func place(_ paragraphs: [String], in body: NSMutableAttributedString, afterAttachmentNamed fileName: String)
    static func removePlaceholder(in body: NSMutableAttributedString, afterAttachmentNamed fileName: String)
}

// Sources/NoteIt/Capture/AppendTodayController.swift
struct AppendTodayResult: Equatable { var noteID: UUID; var dayTitle: String; var line: String }
@MainActor final class AppendTodayController {
    struct Environment {
        var isAvailable: () -> Bool                              // DailyNotes.isAvailable
        var append: (String, Date) throws -> AppendTodayResult?  // wraps DailyLogAppender; nil when the text is empty
        var now: () -> Date
    }
    static let shared: AppendTodayController
    var isAvailable: Bool { get }
    func show()
    func submit(_ text: String) -> CaptureOutcome?               // .appended, .dailyNotesUnavailable, or nil (beep)
}

// Sources/NoteIt/Capture/TranscriptChunker.swift
struct TranscriptSegment: Equatable { var text: String; var start: TimeInterval; var end: TimeInterval }
enum TranscriptChunker {
    static func chunkBoundaries(levels: [Float], windowDuration: TimeInterval, totalDuration: TimeInterval) -> [ClosedRange<TimeInterval>]
    static func paragraphs(from segments: [TranscriptSegment]) -> [String]   // new paragraph after 2 s pause or 5 sentences
}

// Sources/NoteIt/Capture/Transcriber.swift
enum TranscriberError: Error, Equatable { case notAllowed, onDeviceUnavailable, modelNotInstalled, failed(String) }
protocol Transcriber: Sendable {
    var engineName: String { get }
    func transcribe(fileAt url: URL, locale: Locale) async throws -> [TranscriptSegment]
}
struct SFSpeechTranscriber: Transcriber                     // requiresOnDeviceRecognition = true, addsPunctuation = true
#if compiler(>=6.2)
@available(macOS 26, *) struct SpeechAnalyzerTranscriber: Transcriber
#endif
enum TranscriberFactory { static func make(locale: Locale) -> Transcriber }

// Sources/NoteIt/Capture/VoiceRecorder.swift
protocol VoiceRecording: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var averagePower: Float { get }
    func start(to url: URL) throws
    func stop() -> URL?
    func cancel()
}
enum VoiceFileExporter { static func exportM4A(from caf: URL, to m4a: URL) async throws }

// Sources/NoteIt/Capture/TranscriptionQueue.swift
struct TranscriptionJob: Codable, Equatable { var noteID: UUID; var audioFileName: String; var placeholder: String; var locale: String }
@MainActor final class TranscriptionQueue {
    init(url: URL, store: NoteStore, transcriber: @escaping (Locale) -> Transcriber)
    func enqueue(_ job: TranscriptionJob)
    func resumePending()
}

// Sources/NoteItMail/IMAPTransport.swift
public protocol IMAPTransport: AnyObject, Sendable {
    func connect() async throws
    func send(_ bytes: Data) async throws
    func receive() async throws -> Data          // next chunk, empty at end of stream
    func close()
}
public enum IMAPTransportError: Error, Equatable {
    case unreachable(String), timeout, closed
    case untrustedCertificate(sha256: String)
    case fingerprintMismatch(expected: String, actual: String)
}
public final class NWIMAPTransport: IMAPTransport {
    public init(host: String, port: UInt16 = 993, pinnedSHA256: String?, connectTimeout: TimeInterval = 15)
}

// Sources/NoteItMail/IMAPClient.swift
public struct IMAPMessageSummary: Equatable, Sendable {
    public var uid: UInt32; public var size: Int; public var flags: Set<String>
    public var from: String?; public var messageID: String?; public var authenticationResults: [String]
}
public enum IMAPError: Error, Equatable {
    case authenticationFailed, loginDisabled, noSuchMailbox(String)
    case server(String), protocolViolation(String), commandTimeout
}
public actor IMAPClient {
    public init(transport: IMAPTransport, commandTimeout: TimeInterval = 30)
    public func connect() async throws -> Set<String>             // capabilities
    public func login(user: String, password: String) async throws
    public struct SelectedMailbox: Equatable, Sendable {
        public var uidValidity: UInt32; public var exists: Int; public var unseen: Int?
        public var allowsNewKeywords: Bool                          // PERMANENTFLAGS contains \*
    }
    public var capabilities: Set<String> { get }
    public func select(_ mailbox: String) async throws -> SelectedMailbox
    public func countUnseen() async throws -> Int
    public func create(_ mailbox: String) async throws
    public func searchUnseen(excludingKeyword keyword: String) async throws -> [UInt32]
    public func fetchSummaries(_ uids: [UInt32]) async throws -> [IMAPMessageSummary]
    public func fetchMessage(_ uid: UInt32, timeout: TimeInterval = 120) async throws -> Data
    public func addFlags(_ flags: [String], to uid: UInt32) async throws
    public var canMove: Bool { get }                              // MOVE or UIDPLUS advertised
    public func move(_ uid: UInt32, to mailbox: String) async throws   // UID MOVE, or UID COPY + \Deleted + UID EXPUNGE
    public func logout() async
}

// Sources/NoteItMail/MIMEParser.swift, MailMessage.swift
public struct MailAddress: Equatable, Sendable { public var name: String?; public var address: String }
public struct MailAttachment: Equatable, Sendable {
    public var fileName: String; public var mimeType: String; public var data: Data
    public var contentID: String?; public var isInline: Bool
}
public struct MailMessage: Equatable, Sendable {
    public var from: MailAddress?; public var subject: String?; public var date: Date?; public var messageID: String?
    public var plainText: String?; public var html: String?; public var attachments: [MailAttachment]
}
public enum MIMEParser { public static func parse(_ raw: Data) throws -> MailMessage }
public enum ModifiedUTF7 {
    public static func encode(_ name: String) -> String
    public static func decode(_ name: String) -> String?
}

// Sources/NoteIt/MailIn/*
struct MailInConfiguration: Codable, Equatable {
    enum AfterSaving: Codable, Equatable { case markRead, move(folder: String) }
    var isEnabled: Bool; var host: String; var port: UInt16; var user: String; var folder: String
    var allowedSenders: [String]; var acceptsAnySender: Bool
    var afterSaving: AfterSaving; var notebookID: UUID?; var intervalMinutes: Int    // 5, 15, 30, 60
    var pinnedCertificateSHA256: String?
}
enum MailInStatus: Equatable {
    case off, checking, offline(host: String), signInFailed
    case idle(lastCheck: Date, saved: Int, skipped: Int)
    case untrustedCertificate(fingerprint: String)
    case folderMissing(name: String)
    case serverError(message: String)
}
enum MailInBackoff { static func delay(afterFailures count: Int, interval: TimeInterval) -> TimeInterval }  // 1, 2, 4 ... 60 min
enum MailInKeychain {                                       // service io.github.rutbergphilip.noteit.mail-in
    static func password(for account: String) -> String?
    static func setPassword(_ password: String?, for account: String) throws   // account "<user>@<host>"
}
enum MailHTMLSanitizer { static func sanitize(_ html: String) -> String }
enum MailNoteBuilder {
    static func body(for message: MailMessage, title: String) -> NSAttributedString
    static func title(for message: MailMessage) -> String
}
@MainActor final class MailInController: ObservableObject {
    static let shared: MailInController
    @Published private(set) var status: MailInStatus
    func start()
    func checkNow()
    func stop(deletingCredentials: Bool)
    func trustCertificate(_ fingerprint: String)
    func createMissingFolder()
}
```

## Tasks

Markers: **[P]** can run in parallel with the other [P] tasks in the same milestone. **[S]** must run after the tasks it names. Milestones 2, 4, 5 and 6 depend only on Milestone 1 and can be developed in parallel on separate branches. Milestone 3 needs Task 6 from Milestone 2. When two milestones touch the same file (`CaptureCommands.swift`, `AppDelegate.swift`, `GeneralSettingsView.swift`), each only replaces its own function body or adds its own section, so merges stay mechanical. The General tab is already a scrolling form with frozen sections (foundations task 6.5); Capture Plus only adds rows and its Email-in section.

### Milestone 1: Shared plumbing and auto titles

### Task 0: General settings as a scrolling form

Moved to foundations (task 6.5). The General tab and `GeneralSettingsSection` exist before this plan starts; Tasks 12 and 27 add to them.

### Task 1: Limits, preferences and new outcomes [S: none]

**Files:**
- Create: `Sources/NoteIt/Capture/CaptureLimits.swift`
- Modify: `Sources/NoteIt/Settings/Preferences.swift`, `Sources/NoteIt/Capture/CaptureController.swift`, `Sources/NoteIt/Capture/CaptureToast.swift`
- Test: `Tests/NoteItTests/CaptureControllerTests.swift`

- [ ] Add `CaptureLimits` with the values in Frozen interfaces. `pendingDirectory` is `<NoteStore.rootURL>/capture-pending`, created on first use, excluded from sync and from Time Machine with `URLResourceValues.isExcludedFromBackup = true`. The attachment cap is `AttachmentLimit.maxBytes` from `NoteItDoc`; `CaptureLimits` has no copy.
- [ ] Add `PrefKey` and `PrefDefault` values: `imageTextIndexing` (false), `imageTextIndexingOffered` (false), `textRecognitionLanguages` ([] = automatic), `screenshotCopiesText` (false), `voiceTranscription` (true), `voiceTranscriptionLocale` ("" = system), `mailInConfiguration` (no value).
- [ ] Change `CaptureOutcome.saved` to carry `detail: String? = nil`, and add the new cases and `CaptureToastButton` cases from Frozen interfaces. Update every existing `.saved(` pattern match (`CaptureController.handle`, `CaptureToastContent`, tests) to the new shape.
- [ ] Map each new outcome to a `CaptureToastContent` with the text in spec §1 "Notices". When `detail` is set it replaces the note title as the message. `.appended` opens the note when clicked. `.offerImageTextIndexing` shows **Turn On** and **Not Now**; **Turn On** sets `imageTextIndexing`. `.allowScreenRecording` and `.openPrivacySettings` open `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` and `?Privacy_Microphone`.
- [ ] Tests: `saved` with `detail` shows the detail; each new outcome produces the expected title, message and buttons; old outcomes are unchanged.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CaptureControllerTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(capture): add capture limits, preferences and outcomes`

### Task 2: CaptureTitler [P]

**Files:**
- Create: `Sources/NoteIt/Capture/CaptureTitler.swift`
- Modify: `Sources/NoteIt/Capture/CaptureFormatter.swift`
- Test: `Tests/NoteItTests/CaptureTitlerTests.swift`, `Tests/NoteItTests/CaptureFormatterTests.swift`

- [ ] Write the failing tests first, one per rule in spec §5:
  - source order for each kind (screenshot falls back from text to page title to window title to "Screenshot <date>");
  - meaningful line skips list markers, headings, quotes, lines with fewer than 3 letters, URL-only, email-only, date-only and mostly-digit lines, and only looks at the first 10 non-empty lines;
  - subject cleaning strips repeated `Re:`/`Fwd:`/`Fw:`/`AW:`/`SV:`/`VS:`/`WG:` and a leading `[tag]` in any case; an empty result goes to the next source;
  - a sentence end before 60 characters cuts without an ellipsis; otherwise a word-boundary cut with `…`; trailing `:`, `;`, `,` removed;
  - fallback dates use `Date.FormatStyle(date: .abbreviated, time: .shortened)` with an injected `en_GB` locale and fixed time zone.
- [ ] Implement `CaptureTitler`.
- [ ] Add the `CaptureTitleRefining` protocol and `CaptureTitleRefinement`. Capture Plus owns both; `private-ai` provides the model-based refiner and sets `CaptureTitleRefinement.refiner` at launch. `refineIfUnchanged` asks the refiner, and when it returns a title, applies it through `NoteStore.editBody(id, actionName: "Change Title")` with `CaptureTitler.replaceTitle(in:ifEqualTo:with:)` so a title the user changed is left alone. No refiner or a nil answer does nothing.
- [ ] Tests for refinement with a fake refiner: an unchanged title is replaced; a title the user edited is kept; no refiner keeps the heuristic title; a locked or deleted note is left alone (`editBody` refuses).
- [ ] `CaptureTitler.shorten` builds on `CaptureTitle.truncated` (`NoteItCore`, moved there by foundations task 1.3) and adds only the sentence-end and trailing-punctuation rules; `CaptureFormatter` keeps calling `CaptureTitle.truncated`, so its titles don't change. `CaptureTitle.maxLength` stays 60.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'CaptureTitlerTests|CaptureFormatterTests' 2>&1 | tail -20` passes, and the existing `CaptureFormatterTests` pass unchanged.
- [ ] Commit: `feat(capture): add heuristic capture titles`

### Task 3: Permissions, Info.plist and entitlements [P]

**Files:**
- Create: `Sources/NoteIt/Capture/CapturePermissions.swift`
- Modify: `scripts/build_app.sh`, `Resources/NoteIt.entitlements`

- [ ] Implement the three `CapturePermission` types from spec §1 "Permissions". `ScreenRecordingPermission` returns `.allowedAfterRestart` when `request()` was called in this session and preflight is still false; remember that in memory only.
- [ ] `AppBundleCheck.isRunningFromAppBundle` is true when `Bundle.main.bundleURL.pathExtension == "app"` and the Info.plist has `NSMicrophoneUsageDescription`.
- [ ] In `scripts/build_app.sh`, next to `NSAppleEventsUsageDescription`, add `plist_str NSMicrophoneUsageDescription "NoteIt records voice notes when you ask it to."` and `plist_str NSSpeechRecognitionUsageDescription "NoteIt turns your voice notes into text on this Mac. Audio never leaves your Mac."`.
- [ ] Add `<key>com.apple.security.device.audio-input</key><true/>` to `Resources/NoteIt.entitlements`. It reaches the signature through the app's row in the embeds table (foundations); add no rows and no separate `codesign` call.
- [ ] Verify: `swift build 2>&1 | tail -5` ends with `Build complete!`; `NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` succeeds and `plutil -p .selftest/app/NoteIt.app/Contents/Info.plist | grep -E 'Microphone|SpeechRecognition'` prints both keys; `codesign -d --entitlements - .selftest/app/NoteIt.app 2>&1 | grep audio-input` prints the entitlement; `codesign --verify --strict .selftest/app/NoteIt.app` passes.
- [ ] Commit: `feat(capture): add capture permission checks and usage strings`

### Task 4: Hotkeys, menu, palette and menu bar entry points [S: Task 1]

**Files:**
- Create: `Sources/NoteIt/Capture/CaptureCommands.swift`
- Modify: `Sources/NoteIt/Hotkeys/HotkeyAction.swift`, `Sources/NoteIt/Settings/ShortcutsSettingsView.swift`, `Sources/NoteIt/Design/Tokens.swift`, `Sources/NoteIt/App/AppDelegate.swift`, `Sources/NoteIt/App/NoteItApp.swift`, `Sources/NoteIt/Palette/PaletteCommandRegistry.swift`, `Sources/NoteIt/MenuBar/MenuBarView.swift`
- Test: the wave 0 frozen hotkey table tests, `Tests/NoteItTests/PaletteCommandRegistryTests.swift`

- [ ] Add `screenshotToText`, `recordVoiceNote`, `appendToToday` to `HotkeyAction` at positions 9, 10 and 11 of the frozen table (after `showTasks`, before `askNotes` if present), with the titles, descriptions and symbols in spec §1. They have no default binding.
- [ ] In the same change, add the three cases to the `ShortcutsSettingsView` tile switch with new `Tokens.Color.tileScreenshotToText`, `tileRecordVoiceNote` and `tileAppendToToday` colours.
- [ ] Add `@MainActor enum CaptureCommands` with `screenshotToText()`, `recordVoiceNote()`, `appendToToday()`, `checkMailNow()`, `isAppendToTodayAvailable` and `isMailInEnabled`. This is the only place that hotkeys, menus, palette and menu bar call. Until a feature's milestone lands, its function calls `NSSound.beep()`; each later milestone replaces one body.
- [ ] Add the three cases to the `HotkeyManager.shared.handler` switch in `AppDelegate`.
- [ ] In `NoteItCommands` (`CommandGroup(replacing: .newItem)`), add a **Capture** `Menu` after the Open group (Open Quickly, Open Today's Note, Daily Note for Date…) and before the **Share** submenu, as the program's menu table sets out, with **Screenshot to Text**, **New Voice Note** and **Append to Today…** without keyboard shortcuts. **Append to Today…** is hidden while `isAppendToTodayAvailable` is false.
- [ ] Add palette commands `screenshotToText`, `newVoiceNote`, `appendToToday` with `available: CaptureCommands.isAppendToTodayAvailable`, and `checkMailNow` with `available: CaptureCommands.isMailInEnabled`. Keywords: "ocr", "scan", "text from image"; "audio", "dictate", "record"; "daily", "journal", "log"; "email", "imap", "inbox".
- [ ] Add two `IconButton`s to the menu bar footer (`text.viewfinder`, `mic.fill`) with help text "Screenshot to Text" and "New Voice Note".
- [ ] Tests: the wave 0 hotkey table tests pass with the three cases in their frozen positions (unique raw values, first six unchanged, no default binding); the palette lists the four ids, hides `checkMailNow` when mail-in is off and `appendToToday` when daily notes are unavailable.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'HotkeyActionTests|PaletteCommandRegistryTests' 2>&1 | tail -20` passes.
- [ ] Manual: `NOTEIT_DATA_DIR=<project>/.selftest/capture-plus swift run NoteIt`. Settings > Shortcuts lists the three new actions unbound with their tiles; File › Capture shows the three items; a previously bound Capture Selection hotkey still works.
- [ ] Commit: `feat(capture): add entry points for capture plus commands`

### Milestone 2: Screenshot to Text

### Task 5: Screenshot capturer [P]

**Files:**
- Create: `Sources/NoteIt/Capture/ScreenshotCapturer.swift`
- Test: `Tests/NoteItTests/ScreenshotCapturerTests.swift`

- [ ] `ScreencaptureProcessCapturer` runs `/usr/sbin/screencapture -i -x -o <url>` with `Process`, behind an injected `ProcessRunning` closure `(URL, [String]) async -> Int32`.
- [ ] Map results: exit 0 with a non-empty file → `.image(url)`; exit 0 or 1 without a file → `.cancelled` (Esc); a file that is empty, or `CGPreflightScreenCaptureAccess()` false after the run with no file → `.notAllowed`; any other exit → `.failed("screencapture exited with <code>")`. Terminate the process after `CaptureLimits.screenshotTimeout` and return `.cancelled`.
- [ ] `#if DEBUG`: when `NOTEIT_DEBUG_SCREENSHOT_FILE` is set, copy that file to `url` and return `.image(url)` without running the process.
- [ ] Tests with a fake runner: arguments are exactly `["-i", "-x", "-o", path]`; each exit and file case maps as above; the timeout path returns `.cancelled`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScreenshotCapturerTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(capture): add region screenshot capturer`

### Task 6: Text recognition and layout [P]

**Files:**
- Create: `Sources/NoteIt/Capture/TextRecognizer.swift`, `Sources/NoteIt/Capture/RecognizedTextLayout.swift`
- Test: `Tests/NoteItTests/RecognizedTextLayoutTests.swift`, `Tests/NoteItTests/TextRecognizerTests.swift`

- [ ] `VisionTextRecognizer`: `VNRecognizeTextRequest`, `revision = VNRecognizeTextRequestRevision3`, `recognitionLevel = .accurate`, `usesLanguageCorrection = true`. Empty `languages` → `automaticallyDetectsLanguage = true`; otherwise set `recognitionLanguages` filtered by `supportedRecognitionLanguages()`. Downscale images whose longer side is over `CaptureLimits.maxRecognitionPixels` first. Run the request on a detached task.
- [ ] `RecognizedTextLayout.paragraphs(from:)` implements spec §2.2: drop lines under 0.3 confidence; sort top to bottom, then left to right; start a new paragraph when the vertical gap is over 1.2× the median line height or the left edge shifts by more than 5% of the width; join a line ending in `-` with the next line without a space when the next starts with a lower-case letter; otherwise join with a space. `text(from:)` joins paragraphs with `"\n\n"` and caps at `CaptureLimits.maxRecognizedCharacters` on a word boundary.
- [ ] Layout tests with hand-built `RecognizedLine` arrays: two columns, a heading followed by a paragraph, hyphenation, low-confidence lines dropped, cap applied.
- [ ] One recogniser test renders "Quarterly report 2026" in 32 pt Helvetica into a `CGContext`, runs `VisionTextRecognizer`, and checks the folded result contains "quarterly report".
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecognizedTextLayoutTests|TextRecognizerTests' 2>&1 | tail -20` passes.
- [ ] Commit: `feat(capture): add on-device text recognition`

### Task 7: Screenshot note body [P]

**Files:**
- Create: `Sources/NoteIt/Capture/ScreenshotNoteBuilder.swift`
- Modify: `Sources/NoteIt/Capture/CaptureFormatter.swift`
- Test: `Tests/NoteItTests/ScreenshotNoteBuilderTests.swift`, `Tests/NoteItTests/CaptureFormatterTests.swift`

- [ ] Extract the source line, which Capture Plus owns and `web-clipper` reuses. Add internal `sourceLine(linkingTo url: URL, label: String?, appName: String?)`: `From <label or host> in <appName>`, label linked, " in …" left out when `appName` is nil, label single-lined with `label(for:)` as the fallback. Add internal `sourceLine(for source: CaptureSource, title: String)`, which uses it for the page and document cases and keeps the unlinked `From <App> — <window>` / `From another app` path. The private `sourceLine(for capture:)` calls `sourceLine(for: capture.source, title: title(for: capture))`. Capture Selection's output stays byte for byte the same. This extraction merges before `web-clipper`'s note builder task, which calls `sourceLine(linkingTo:label:appName:)` (program §2, wave 2 order).
- [ ] `CaptureFormatterTests`: the existing cases pass unchanged; new cases cover `sourceLine(linkingTo:label:appName:)` with and without a label and an app name.

- [ ] `encodedImage(from:)`: keep the PNG when it is at most `CaptureLimits.maxPNGBytes`; else JPEG at 0.85; if still over `AttachmentLimit.maxBytes` (`NoteItDoc`), scale down by 0.75 steps until it fits. File names are `Screenshot yyyy-MM-dd HH.mm.ss.png` or `.jpg`.
- [ ] `body(...)`: title paragraph (styled like `CaptureFormatter.noteContent`), the image as `NSTextAttachment(fileWrapper:)`, the recognised text as body paragraphs, an empty paragraph, then `CaptureFormatter.sourceLine(for:title:)` when a source exists. Existing `CaptureFormatterTests` must still pass. No text → no text paragraphs.
- [ ] Tests: a small PNG stays PNG; a large noisy image becomes JPEG under the limit; the body has exactly one attachment whose `fileWrapper.regularFileContents` equals the encoded data; paragraph order matches spec §2.3; a round trip through RTFD (`NoteStore.createNote` then `body(for:)`) keeps the attachment.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScreenshotNoteBuilderTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(capture): build screenshot notes with image and text`

### Task 8: Screenshot to Text flow [S: Tasks 1-7]

**Files:**
- Create: `Sources/NoteIt/Capture/ScreenshotCaptureController.swift`
- Modify: `Sources/NoteIt/Capture/CaptureCommands.swift`
- Test: `Tests/NoteItTests/ScreenshotCaptureControllerTests.swift`

- [ ] `ScreenshotCaptureController.shared` with an `Environment` (capturer, recogniser, permission, source resolver, pasteboard, store, now) like `CaptureController`. Ignore the command while a capture is already running.
- [ ] Flow (spec §2.1–2.2): record the frontmost app; if screen recording is not allowed, show `.screenRecordingNotAllowed`; run the capturer into `CaptureLimits.pendingDirectory/<uuid>.png`; `.cancelled` → nothing; resolve the source with `SourceResolver.resolve(app:includeBrowserLinks:)` only when Accessibility is trusted; recognise with the `textRecognitionLanguages` preference; build the title with `CaptureTitler` and the body with `ScreenshotNoteBuilder`; save with `store.createNote(in: store.defaultNotebookIDForNewNotes, initial:)`, write the marker `<uuid>.note-id` (the note's UUID) next to the PNG, then `persist(note.id)` (`store.persistNow` in the app); record the image text in `AttachmentTextStore` when Milestone 3 is present and `imageTextIndexing` is on; delete the PNG, then the marker, only after `persist` returns; show `.saved` with `detail` "No text found in the image" or "Couldn't read text in the image" when relevant; then call `CaptureTitleRefinement.refineIfUnchanged` with the heuristic title.
- [ ] Save failure (spec §2.3): when `persist` throws, keep the PNG and its marker and show `.screenshotNotSaved(noteID:)` (text in spec §1 "Notices"). The clipboard path writes its image to `capture-pending/<uuid>.png` with a marker at this point, so it is kept the same way. **Try Again** calls `persist` on the same note ID (it never creates a second note) and, once it returns, records the image text, deletes the PNG and marker and shows `.saved`; another throw shows the notice again. Closing the notice deletes nothing: the PNG and marker stay until a later `persist(noteID)` returns. The controller retries `persist` for every kept PNG at the start of the next Screenshot to Text, every 5 minutes while one is kept (the `Environment`'s clock), and at launch, and deletes the PNG and marker once it returns. The `Environment` gains `persist: (UUID) throws -> Void`.
- [ ] Launch recovery (spec §2.3), before the first retry: for each `capture-pending/<uuid>.png` with a marker, if the store has the marker's note, retry `persist` on it (never a second note); if it doesn't (the note never reached disk), build the note again from the PNG as in the clipboard path (recognition, title, body, no source line), rewrite the marker with the new note's UUID, then `persist` and delete as above. A failure leaves the PNG and marker for the next retry, with no notice at launch. A `.png` without a marker never became a note; recovery imports it the same way (new note, marker written, then saved and deleted), so a capture is never dropped.
- [ ] Offer (spec §2.3), a one-time notice: after a successful save, when `imageTextIndexing` is off and `imageTextIndexingOffered` is false, set `imageTextIndexingOffered` and show `.offerImageTextIndexing` after the saved notice. **Turn On** sets `imageTextIndexing` (the indexer then catches up, Task 11).
- [ ] When `screenshotCopiesText` is on and text was found, also put the text on `NSPasteboard.general`.
- [ ] `.useClipboardImage` reads the first image from the pasteboard and runs the same flow from recognition; no image → `.clipboardHasNoImage`.
- [ ] Replace the `CaptureCommands.screenshotToText()` body.
- [ ] Tests with fakes: cancel saves nothing; not allowed shows the right outcome; success creates one note with the expected title, attachment and text; recognition error still saves with the detail; clipboard path with and without an image; the pending PNG is gone afterwards; `testPersistFailureKeepsPNG` (a failing `persist` leaves the PNG, shows `.screenshotNotSaved` and records no image text); `testTryAgainPersistsSameNote` (**Try Again** with a working `persist` makes no second note, then deletes the PNG and shows `.saved`); `testDismissedFailureKeepsPNGUntilSaved` (closing the notice after a failing `persist` keeps the PNG and marker; the next retry with a working `persist` saves the same note, makes no second one, and only then deletes the PNG and marker); `testLaunchRecoveryReimportsUnsavedPNG` (a PNG whose marker names a note the store doesn't have becomes exactly one note, and its PNG and marker go after `persist` returns; a PNG whose marker names an existing note makes no new note); a second call while busy is ignored; the offer appears after the first success only, never when the setting is already on, and not on a later capture after **Not Now**.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScreenshotCaptureControllerTests 2>&1 | tail -20` passes; `swift build -c release 2>&1 | tail -5` ends with `Build complete!`.
- [ ] Manual (app bundle): bind a hotkey, select a region of a web page, check the note in Inbox has the image, readable text and a source line; deny Screen Recording in System Settings and check the notice and the clipboard fallback.
- [ ] Commit: `feat(capture): add screenshot to text`

### Milestone 3: Image text in search

### Task 9: Attachment text store [P]

**Files:**
- Create: `Sources/NoteIt/Model/AttachmentTextStore.swift`
- Test: `Tests/NoteItTests/AttachmentTextStoreTests.swift`

- [ ] `AttachmentTextStore` loads `<NoteStore.rootURL>/attachment-text.json` (`AttachmentTextFile`), never a path under a Markdown library's `contentRootURL`. A missing file, a different `version` or a different `engine` starts empty, so a later engine change re-reads every image.
- [ ] `record` stores folded text per sha256 (`TextFold.fold`, `NoteItCore`) and the note's `updatedAt` and image list. An image with no text is stored as `""` so it isn't read again. `text(forNote:)` joins the non-empty texts of the note's images. Images no note refers to are dropped on `save()`.
- [ ] `save()` writes atomically and is debounced by the caller. The file is local only. Like `search-index.json`, it sits in the store's root folder, which sync never uploads; sync works on notes and notebooks only.
- [ ] Tests: round trip; version and engine mismatch reset; `needsWork` true for unknown notes and changed `updatedAt`; shared images across notes are stored once; unreferenced images are pruned; `deleteAll` removes the file.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AttachmentTextStoreTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(search): add local store for text found in images`

### Task 10: Store APIs and the image text provider [S: Task 9]

**Files:**
- Create: `Sources/NoteIt/Model/NoteStore+CapturePlus.swift`, `Sources/NoteIt/Capture/AttachmentTextImageProvider.swift`
- Modify: `Sources/NoteIt/Model/NoteStore.swift` (owns the `AttachmentTextStore`), `Sources/NoteIt/App/AppDelegate.swift` (registers the provider)
- Test: `Tests/NoteItTests/ImageTextSearchTests.swift`

- [ ] Give `NoteStore` an `attachmentText: AttachmentTextStore` at `rootURL/attachment-text.json`, created next to `searchIndex`. Entry removal goes through the indexer's `noteRemoved` (Task 11), not a new hook in `NoteStore.swift`.
- [ ] `imageText(for:)` returns `attachmentText.text(forNote:)`, or nil when `imageTextIndexing` is off or `meta.isLocked` is true.
- [ ] `imageAttachments(in:)` returns `[]` for locked notes. Otherwise it reads the body through `NoteBodyStorage` off the main actor, walks `.attachment` runs, keeps attachments whose file wrapper has image contents (`NSImage(data:)` or a UTType conforming to `.image`), and returns sha256 (CryptoKit `SHA256`, lower-case hex), data and file name. It never reads note files directly, so RTFD and Markdown libraries behave the same.
- [ ] Search is `organise`'s: do not change `notes(for:search:)`, the search index or `ImageTextProviding`. Add `AttachmentTextImageProvider`, which conforms to `organise`'s `ImageTextProviding` and forwards to `NoteStore.imageText(for:)`, and register it at launch with `NoteStore.registerImageTextProvider(_:)`. `organise`'s "Found in an image" match source appears only once a provider is registered; a note matched only by its image text is then listed with that label instead of a snippet. The palette and Local API search use the same search and need no change.
- [ ] Tests: with no provider registered, "Found in an image" never appears; with the provider registered, a note whose only match is in its image text is found by the list search and by `PaletteModel`, labelled "Found in an image"; turning `imageTextIndexing` off hides it; locking the note hides it and `imageText(for:)` returns nil; `imageAttachments(in:)` returns one entry per image, skips PDFs and audio, and returns nothing for a locked note; hashes match `shasum -a 256` of the data.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ImageTextSearchTests|PaletteModelTests|RecentlyDeletedTests' 2>&1 | tail -20` passes.
- [ ] Commit: `feat(search): provide text found in images to search`

### Task 11: Background indexer [S: Tasks 6, 10]

**Files:**
- Create: `Sources/NoteIt/Capture/AttachmentTextIndexer.swift`
- Modify: `Sources/NoteIt/App/AppDelegate.swift`
- Test: `Tests/NoteItTests/AttachmentTextIndexerTests.swift`

- [ ] `AttachmentTextIndexer` follows spec §2.4 and conforms to `DerivedIndex`. `Environment` holds `now`, `sleep`, `isLowPowerMode` (`ProcessInfo.processInfo.isLowPowerModeEnabled`), `thermalState` and `preferenceEnabled`.
- [ ] `DerivedIndex` hooks (program §7): `noteChanged(_:body:)` (sent on body changes and creation, never for a locked note) marks the note and coalesces a pass to 10 s after the last change; `noteRemoved(_:)` removes the note's entry (the registry also calls it when a note is locked); `metadataChanged(_:)` (the only hook for metadata-only changes: pin, move, tag, trash, restore) does nothing except mark a note restored from Recently Deleted like a changed one; `rebuild(notes:body:)` deletes the file and re-reads every unlocked note; `flush()` saves `attachment-text.json`. While `preferenceEnabled` is false every hook returns at once and no file is written.
- [ ] A run: list live notes, drop locked notes (`meta.isLocked`), keep those where `needsWork` is true, newest first; for each, get `imageAttachments(in:)`; skip images already in the store by sha256, images under 64 px on the short side and over 50 megapixels; recognise one image at a time with a 100 ms pause; record and save every 10 notes and at the end. Update `progress` for Settings.
- [ ] Pause while Low Power Mode is on or the thermal state is `.serious` or `.critical`; resume on `NSProcessInfoPowerStateDidChange` and `ProcessInfo.thermalStateDidChangeNotification`.
- [ ] The indexer is registered with `NoteStore.registerDerivedIndex(_:)` once per store open, in the store-open step in `AppDelegate` (right after `NoteStore.shared` is opened and before anything else uses the store), whether `imageTextIndexing` is on or off. It is never unregistered; while the preference is off it stays registered and dormant. After registering, `AppDelegate` calls `catchUp(after: 30)` when `imageTextIndexing` is on. Turning the preference on calls `catchUp(after: 30)`; turning it off calls `stopAndDeleteIndex()`. Do not add a save hook to `NoteStore.swift`.
- [ ] `ScreenshotCaptureController` records its text directly when the setting is on, so the new note isn't read twice.
- [ ] Tests with a fake recogniser, clock and registry: only changed notes are read; shared images are read once; tiny and huge images are skipped; locked notes are never read and locking a note removes its entry; Low Power Mode pauses and resumes; with the setting off, hooks do nothing and no file appears; turning off deletes the file; `rebuild` re-reads everything; progress reaches `total`.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AttachmentTextIndexerTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(search): read text in existing images in the background`

### Task 12: Text recognition settings [S: Task 11]

**Files:**
- Create: `Sources/NoteIt/Settings/CapturePlusSettingsRows.swift`
- Modify: `Sources/NoteIt/Settings/GeneralSettingsView.swift`

- [ ] The General tab is already a scrolling form (foundations task 6.5). In the `GeneralSettingsSection.capture` section add the rows from spec §1 "Settings": **Find text in images** (off by default) with the progress line, **Text recognition languages** (Automatic, or a multi-select list from `supportedRecognitionLanguages()`), **Copy screenshot text to the clipboard**, and the Screen Recording status row with **Allow Access…** or **Restart NoteIt**. Use `SettingsFootnote` for help text.
- [ ] Verify: `swift build 2>&1 | tail -5` ends with `Build complete!`. Manual: open Settings > General with a test library of 20 notes with images; the toggle starts off and no `attachment-text.json` exists; turning it on, the progress line counts up and disappears; a locked note's images are not counted; turning the toggle off removes `attachment-text.json`.
- [ ] Commit: `feat(capture): add text recognition settings`

### Milestone 4: Voice notes

### Task 13: Transcript chunking and paragraphs [P]

**Files:**
- Create: `Sources/NoteIt/Capture/TranscriptChunker.swift`
- Test: `Tests/NoteItTests/TranscriptChunkerTests.swift`

- [ ] `chunkBoundaries(levels:windowDuration:totalDuration:)` takes RMS levels per window (for example 0.1 s) and returns chunks of at most 60 s, each cut at the quietest 0.5 s stretch between 45 and 60 s into the chunk; recordings under 60 s are one chunk.
- [ ] `paragraphs(from:)` starts a new paragraph after a gap of 2 s or more between segments, or after 5 sentences; trims spaces; drops empty segments.
- [ ] Tests: 30 s → one chunk; 150 s of steady noise with a silent dip at 50 s cuts at 50 s; no dip → cut at 60 s; paragraph rules for pauses and sentence counts.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TranscriptChunkerTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(capture): add transcript chunking`

### Task 14: Transcribers [S: Task 13]

**Files:**
- Create: `Sources/NoteIt/Capture/Transcriber.swift`
- Test: `Tests/NoteItTests/TranscriberTests.swift`

- [ ] `SFSpeechTranscriber`: for each chunk, export the time range with `AVAssetExportSession` to a pending file, run `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition = true` and `addsPunctuation = true`, map `SFTranscriptionSegment`s to `TranscriptSegment`s offset by the chunk start. Throw `.onDeviceUnavailable` when `supportsOnDeviceRecognition` is false and `.notAllowed` when authorisation is denied.
- [ ] `SpeechAnalyzerTranscriber` inside `#if compiler(>=6.2)` and `@available(macOS 26, *)`: `SpeechTranscriber` with the locale and `SpeechAnalyzer` over the file; no chunking needed. If the locale's assets are not installed, throw `.modelNotInstalled`; installing happens only from the **Download…** button (Task 18) through `AssetInventory`.
- [ ] `TranscriberFactory.make(locale:)` returns the macOS 26 engine when available and installed, otherwise the SF engine. The locale is `voiceTranscriptionLocale` or `Locale.current`.
- [ ] Tests: the factory picks the SF engine when the macOS 26 engine is unavailable (inject an availability closure); `SFSpeechTranscriber` maps segments and offsets from a fake recogniser closure. The real engines are covered by the manual check in Task 17 because they need permissions.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TranscriberTests 2>&1 | tail -20` passes; `swift build -c release 2>&1 | tail -5` ends with `Build complete!` (CI on macos-15 compiles the `#if compiler` branch out if its compiler is older).
- [ ] Commit: `feat(capture): add on-device transcribers`

### Task 15: Voice recorder [P]

**Files:**
- Create: `Sources/NoteIt/Capture/VoiceRecorder.swift`
- Test: `Tests/NoteItTests/VoiceRecorderTests.swift`

- [ ] `AVVoiceRecorder: VoiceRecording` wraps `AVAudioRecorder` with `kAudioFormatMPEG4AAC`, 1 channel, 44.1 kHz, 64 kbps, metering on, writing CAF to `CaptureLimits.pendingDirectory/<uuid>.caf`. It stops itself at `CaptureLimits.maxRecordingDuration`.
- [ ] `VoiceFileExporter.exportM4A(from:to:)` uses `AVAssetExportPresetPassthrough` with `.m4a` output.
- [ ] `#if DEBUG`: when `NOTEIT_DEBUG_VOICE_FILE` is set, `start` copies that file and `stop` returns it, so the rest of the flow runs without a microphone.
- [ ] `PendingRecordings.leftovers()` lists CAF files in the pending folder older than the current session, for the recovery notice.
- [ ] Tests: export of a generated 2 s AAC file (written with `AVAudioFile`) produces a playable `.m4a` of the same duration ±0.1 s; leftovers lists only CAF files.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VoiceRecorderTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(capture): add voice recorder`

### Task 16: Recorder panel [P]

**Files:**
- Create: `Sources/NoteIt/Capture/VoiceRecorderPanel.swift`
- Modify: `Sources/NoteIt/Palette/PaletteController+Global.swift`
- Test: `Tests/NoteItTests/PaletteGlobalTests.swift`

- [ ] `VoiceRecorderPanel` is a 300 × 64 pt non-activating `NSPanel` subclass like `QuickCapturePanel` (`canBecomeKey` true, `canBecomeMain` false), at the top right of the screen with the mouse, on all Spaces. It shows a red dot, elapsed time, a level meter from `averagePower`, **Stop** (Return) and **Cancel** (Esc). At 44 minutes the time turns orange with "1 minute left".
- [ ] Add `TransientSurfaceHider.Surface.voiceRecorder`; call `surfaceWillAppear` and `surfaceDidClose` from the panel so NoteIt hides again if it was hidden.
- [ ] Tests: the hider treats the new surface like `captureToast` (existing `PaletteGlobalTests` pattern).
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PaletteGlobalTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(capture): add voice recorder panel`

### Task 17: Voice note flow and transcription queue [S: Tasks 14-16]

**Files:**
- Create: `Sources/NoteIt/Capture/TranscriptionQueue.swift`, `Sources/NoteIt/Capture/VoiceNoteController.swift`, `Sources/NoteIt/Capture/TranscriptPlacement.swift`
- Modify: `Sources/NoteIt/Capture/CaptureCommands.swift`, `Sources/NoteIt/App/AppDelegate.swift`
- Test: `Tests/NoteItTests/VoiceNoteControllerTests.swift`, `Tests/NoteItTests/TranscriptPlacementTests.swift`

- [ ] `VoiceNoteController.shared` with an `Environment` (recorder, permissions, app bundle check, store, queue, now). The hotkey toggles: first press starts, second press stops. Not in an app bundle → `.needsAppBundle`. Microphone denied → `.microphoneNotAllowed`.
- [ ] On stop: under 1 s → discard silently; else export to `.m4a`, create the note with the fallback title "Voice Note <date>", the audio attachment and the placeholder paragraph "Transcribing…", write the marker `CaptureLimits.pendingDirectory/<uuid>.note-id` (the note's ID) next to the CAF, and call `persist(note.id)` (`store.persistNow` in the app; the `Environment` gains `persist: (UUID) throws -> Void`). Only after it returns: delete the marker, then the CAF (the attachment is the exported `.m4a`, already in the persisted body; if a CAF were itself the attachment source it would be deleted only once the attachment is in the persisted body), and enqueue a `TranscriptionJob` when `voiceTranscription` is on. If `persist` throws, the CAF and the marker stay, no job is enqueued, and the recording goes through the recovery notice below.
- [ ] `TranscriptPlacement` (pure, works on an `NSMutableAttributedString`): `place` replaces the paragraph that is exactly "Transcribing…" after the named attachment with body-styled paragraphs, or, when it's gone, appends a "Transcript" subheading and the paragraphs at the end; `removePlaceholder` removes the placeholder paragraph if it's still there. There are no `appendParagraphs` or `replaceParagraph` store primitives.
- [ ] `TranscriptionQueue` persists jobs in `CaptureLimits.pendingDirectory/transcriptions.json` and runs one at a time. On success it makes one call to `NoteStore.editBody(noteID, actionName: "Insert Transcript")` whose closure runs `TranscriptPlacement.place` and, if the title is still the fallback, `CaptureTitler.replaceTitle` with the transcript title, so the whole change is one undo step whether or not the note is open. Then it calls `CaptureTitleRefinement.refineIfUnchanged`. On failure it removes the placeholder through `editBody` and shows `.savedWithoutTranscript` with the reason. If `editBody` refuses (note locked or in Recently Deleted), the job is dropped. `resumePending()` runs at launch.
- [ ] At launch, leftover CAF files show the notice **Recover voice recording?** with **Save as Note** and **Delete**. Ignoring the notice keeps the file, and the notice appears again at every launch. Leftover recordings are never deleted by age or by any automatic cleanup; only **Delete** removes one (with its marker), and **Save as Note** removes it after the note is saved. A CAF with a `.note-id` marker whose note is still in the store is saved by calling `persist` on that note, never by creating a second one; otherwise **Save as Note** creates the note as on stop. Either way the CAF and marker are removed only after `persist` returns.
- [ ] Replace the `CaptureCommands.recordVoiceNote()` body.
- [ ] Tests with fakes: short recordings are discarded; a normal recording creates one note with one `.m4a` attachment and the placeholder; a finished job replaces the placeholder and sets the title; an edited placeholder gets a "Transcript" section instead; with the note open in an editor (registered in `OpenEditorRegistry`) the transcript lands in the text view and one ⌘Z undoes it; a locked note drops the job; failure shows `.savedWithoutTranscript`; jobs survive a new `TranscriptionQueue` instance on the same file; an ignored recovery notice keeps the CAF and shows the notice again on the next launch, even when the file is older than 7 days; **Delete** removes the CAF; **Save as Note** creates the note and then removes the CAF; `testVoicePersistFailureKeepsRecording` (`persist` throws: CAF and marker stay, no job is enqueued, the recovery notice offers the recording, and **Save as Note** persists the same note without creating a second). `TranscriptPlacementTests` cover the placement rules on plain attributed strings.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'VoiceNoteControllerTests|TranscriptPlacementTests' 2>&1 | tail -20` passes.
- [ ] Manual (app bundle, `NOTEIT_DATA_DIR=<project>/.selftest/voice`): record 20 s of speech; the note appears at once with "Transcribing…", then the text replaces it with Wi-Fi turned off.
- [ ] Commit: `feat(capture): add voice notes with on-device transcription`

### Task 18: Audio attachments in the editor and voice settings [S: Task 17]

**Files:**
- Create: `Sources/NoteIt/Editor/AudioAttachmentCell.swift`
- Modify: `Sources/NoteIt/Editor/NoteItTextView.swift`, `Sources/NoteIt/Settings/CapturePlusSettingsRows.swift`, `Sources/NoteIt/Settings/GeneralSettingsView.swift`

- [ ] `AudioAttachmentCell` draws a pill with play/pause, file name and duration for attachments whose UTType conforms to `.audio`; clicking plays with `AVAudioPlayer`, one at a time. Set it where `fitAttachments` handles image attachments. Export is unchanged (`NSTextAttachment.exportContents` already writes the file).
- [ ] Context menu on an audio attachment: **Insert Transcript** inserts the "Transcribing…" placeholder after it through `NoteStore.editBody` and enqueues a job for that attachment; the result lands through the same `editBody` path as Task 17.
- [ ] Settings rows (spec §1): **Transcribe voice notes**, **Language** (System or a locale from `SFSpeechRecognizer.supportedLocales()` that supports on-device recognition), Microphone and Speech Recognition status rows, and on macOS 26 the **Download…** button with progress for the speech model.
- [ ] Verify: `swift build 2>&1 | tail -5` ends with `Build complete!`. Manual: the pill plays and pauses; Insert Transcript works on a dropped `.m4a`; RTFD round trip keeps the file.
- [ ] Commit: `feat(capture): play audio attachments and add voice settings`

### Milestone 5: Append to Today

### Task 19: Append to Today controller over linking's appender [P]

This milestone needs `linking`'s `DailyLogAppender` and `NoteStore+Daily`, built in foundations. Capture Plus adds no daily-note lookup, no line formatter (`DailyLogLine` is in `NoteItCore`), no fallback daily note and no append primitive. It adds no URL, CLI command, App Intent or Local API route: `automation` routes `noteit://append?daily=today&text=`, `noteit today`, `noteit append --today`, the "Append to Daily Note" Shortcuts action and `POST /v1/daily/append` to the same appender.

**Files:**
- Create: `Sources/NoteIt/Capture/AppendTodayController.swift`
- Modify: `Sources/NoteIt/Capture/CaptureCommands.swift` (`isAppendToTodayAvailable`)
- Test: `Tests/NoteItTests/AppendTodayControllerTests.swift`

- [ ] `AppendTodayController.Environment.live` wraps `linking`'s `DailyLogAppender`: `isAvailable` reads `DailyNotes.isAvailable` (`NoteItCore`), which `linking` flips when it ships; `append` passes the text and the time and maps the appender's result (note ID, day title, line added) to `AppendTodayResult`. The appender picks or creates the day's note and writes the line; the controller never edits the note.
- [ ] `submit(_:)`: unavailable → `.dailyNotesUnavailable`; text empty after trimming → nil (the panel beeps); otherwise call `append` with `environment.now()` at that moment and return `.appended(noteID:dayTitle:line:)`. `DailyLogError.emptyText` from the appender is treated like empty text (nil, the panel beeps); any other error is shown with the appender's message.
- [ ] `show()` with daily notes unavailable shows `.dailyNotesUnavailable` instead of the panel. `CaptureCommands.isAppendToTodayAvailable` returns `isAvailable`, so the menu item and palette command hide.
- [ ] Tests with a fake environment: unavailable shows the notice and calls nothing; empty text calls nothing; the time passed is the time of submit, not of `show()`; the result maps to `.appended`. One integration test with a temporary store and the real appender checks the line lands in the day's note as `- HH:mm text` (the `DailyLogLine` format) and that an open editor shows it.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppendTodayControllerTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(capture): append to today through the daily log appender`

### Task 20: Append to Today panel [S: Task 19]

**Files:**
- Create: `Sources/NoteIt/Capture/AppendTodayPanel.swift`
- Modify: `Sources/NoteIt/Capture/CaptureCommands.swift`, `Sources/NoteIt/Design/Tokens.swift`, `Sources/NoteIt/Palette/PaletteController+Global.swift`
- Test: `Tests/NoteItTests/QuickCaptureDismissalTests.swift`, `Tests/NoteItTests/PaletteGlobalTests.swift`

- [ ] `AppendTodayPanel` follows `QuickCapturePanel` and `AppendTodayController` drives it like `QuickCaptureController`: 480 × 52 pt (`Tokens.Size.appendTodayWidth`/`appendTodayHeight`), one single-line `TextField` (pasted line breaks and tabs become spaces) with the placeholder "Add to today's note" and the date on the right, 22% down the screen with the mouse, Return adds, Esc and clicking outside close, the draft is kept until added or cleared. Add `TransientSurfaceHider.Surface.appendToday` and use it like `.voiceRecorder`.
- [ ] Return calls `AppendTodayController.submit` and shows the outcome toast; nil beeps and keeps the panel open.
- [ ] Replace the `CaptureCommands.appendToToday()` body.
- [ ] Tests: dismissal rules match Quick Capture (add cases to the existing suite); the draft survives close and reopen; the draft is cleared after a successful append.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'QuickCaptureDismissalTests|AppendTodayControllerTests|PaletteGlobalTests' 2>&1 | tail -20` passes; `swift build -c release 2>&1 | tail -5` ends with `Build complete!`.
- [ ] Manual: with NoteIt hidden, press the hotkey in another app, type a line, press Return; NoteIt stays hidden, the toast says "Added to <date>", and the daily note ends with the `14:03 <line>` entry in the daily log format. Before `linking`'s daily notes are present, File › Capture has no Append to Today… item and the hotkey shows "Daily notes aren't available yet".
- [ ] Commit: `feat(capture): add append to today panel`

### Milestone 6: Email to NoteIt

### Task 21: NoteItMail target, IMAP commands and response parser [P]

**Files:**
- Modify: `Package.swift`
- Create: `Sources/NoteItMail/IMAPCommand.swift`, `Sources/NoteItMail/IMAPResponseParser.swift`, `Sources/NoteItMail/ModifiedUTF7.swift`
- Test: `Tests/NoteItMailTests/IMAPCommandTests.swift`, `Tests/NoteItMailTests/IMAPResponseParserTests.swift`, `Tests/NoteItMailTests/ModifiedUTF7Tests.swift`, `Tests/NoteItMailTests/Fixtures/`

- [ ] In `Package.swift` add `.target(name: "NoteItMail")`, `.testTarget(name: "NoteItMailTests", dependencies: ["NoteItMail"], resources: [.copy("Fixtures")])`, and add `"NoteItMail"` to the `NoteIt` target's dependencies. No new package dependencies.
- [ ] `IMAPCommand` builds tagged commands (`A001` …), quotes strings, sends literals for strings with CR, LF, `"` or non-ASCII, and builds the commands listed in spec §4.2. `AUTHENTICATE PLAIN` encodes `\0user\0password` in base64; it uses SASL-IR when advertised.
- [ ] `IMAPResponseParser` is incremental: `append(_ bytes: Data)` then `next() -> IMAPResponse?`. It handles tagged `OK/NO/BAD` with response codes (`[UIDVALIDITY n]`, `[PERMANENTFLAGS (...)]`, `[CAPABILITY ...]`, `[TRYCREATE]`), untagged `CAPABILITY`, `EXISTS`, `SEARCH`, `FETCH` with `UID`, `FLAGS`, `RFC822.SIZE`, `BODY[...]` literals, `NIL`, quoted strings with escapes, nested lists, and `+` continuations. Data split at any byte gives the same result.
- [ ] `ModifiedUTF7` encodes and decodes mailbox names per RFC 3501 section 5.1.3.
- [ ] Fixtures: transcripts recorded from Dovecot, iCloud, Fastmail and Gmail with credentials and addresses replaced by `user@example.com`.
- [ ] Tests: every fixture parses; splitting each fixture at every byte position gives the same responses; literals with CRLF inside; `ModifiedUTF7` round trips "Notes/Inkorg", "Räkningar", "日本語", "&" → "&-".
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'IMAPCommandTests|IMAPResponseParserTests|ModifiedUTF7Tests' 2>&1 | tail -20` passes.
- [ ] Commit: `feat(mail): add IMAP command builder and response parser`

### Task 22: MIME parser [P]

**Files:**
- Create: `Sources/NoteItMail/MailMessage.swift`, `Sources/NoteItMail/MIMEParser.swift`, `Sources/NoteItMail/MIMEDecoding.swift`
- Test: `Tests/NoteItMailTests/MIMEParserTests.swift`, `Tests/NoteItMailTests/Fixtures/*.eml`

- [ ] Implement spec §4.3 parsing: header unfolding, RFC 2047 encoded words (B and Q, adjacent words joined), RFC 2231 parameters including continuations, nested `multipart/mixed`, `alternative` and `related`, base64, quoted-printable, 7bit/8bit, charsets via `CFStringConvertIANACharSetNameToEncoding` with UTF-8 fallback. Date headers parse RFC 5322 dates with `en_US_POSIX`.
- [ ] `plainText` and `html` come from the first matching parts of the best alternative; parts with `Content-ID` referenced from HTML are `isInline`; other parts with a file name are attachments.
- [ ] Fixtures: Apple Mail with inline image, Gmail forward, Outlook with `windows-1252`, ISO-8859-1 plain text, a newsletter with tracking pixels, a message with `filename*=utf-8''r%C3%A4kning.pdf`, a message without a Message-ID.
- [ ] Tests: each fixture's subject, sender, text, HTML presence, attachment names, sizes and inline flags; malformed boundaries throw instead of crashing.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MIMEParserTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(mail): add MIME parser`

### Task 23: IMAP client and TLS transport [S: Task 21]

**Files:**
- Create: `Sources/NoteItMail/IMAPTransport.swift`, `Sources/NoteItMail/NWIMAPTransport.swift`, `Sources/NoteItMail/IMAPClient.swift`
- Test: `Tests/NoteItMailTests/IMAPClientTests.swift`, `Tests/NoteItMailTests/IMAPLiveTests.swift`

- [ ] `NWIMAPTransport`: `NWConnection` with `NWProtocolTLS.Options`, `sec_protocol_options_set_min_tls_protocol_version(.TLSv12)`, and a verify block that evaluates the system trust with `SecTrustEvaluateWithError`. If that fails and `pinnedSHA256` matches the SHA-256 of the leaf certificate, accept; if it fails without a pin, fail with `.untrustedCertificate(sha256:)`; if a pin is set and doesn't match, fail with `.fingerprintMismatch`. Connect timeout 15 s.
- [ ] `IMAPClient` (actor) runs one command at a time with a 30 s timeout (120 s for `fetchMessage`), reads the greeting, gets capabilities, refuses `LOGINDISABLED`, maps `NO` on login to `.authenticationFailed`, `NO [TRYCREATE]` or `NO` on `SELECT` to `.noSuchMailbox`. `move` uses `UID MOVE` when advertised, else `UID COPY`, `UID STORE +FLAGS.SILENT (\Deleted)` and `UID EXPUNGE <uid>`; it never sends a plain `EXPUNGE`. The password is never written to logs; debug logging redacts the `AUTHENTICATE` and `LOGIN` lines.
- [ ] Tests with a scripted `IMAPTransport` that expects exact client lines and replies from fixtures: login with SASL-IR, without SASL-IR, and with `LOGIN` only; `LOGINDISABLED`; wrong password; missing folder; search and fetch of summaries and a full message; flags with and without new keyword support; move with MOVE, with UIDPLUS, and `canMove` false without either; a command timeout.
- [ ] `IMAPLiveTests` runs only when `NOTEIT_MAIL_LIVE_TEST` is set to `host:user:folder` with the password in `NOTEIT_MAIL_LIVE_PASSWORD`; otherwise it calls `XCTSkip`. It logs in, selects the folder and counts unread messages without changing anything.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'IMAPClientTests|IMAPLiveTests' 2>&1 | tail -20` passes with the live test skipped.
- [ ] Commit: `feat(mail): add IMAP client over TLS`

### Task 24: Mail-in configuration, Keychain and state [P]

**Files:**
- Create: `Sources/NoteIt/MailIn/MailInConfiguration.swift`, `Sources/NoteIt/MailIn/MailInKeychain.swift`, `Sources/NoteIt/MailIn/MailInState.swift`, `Sources/NoteIt/MailIn/MailInStatus.swift`
- Test: `Tests/NoteItTests/MailInStateTests.swift`

- [ ] `MailInConfiguration` is stored as JSON under `PrefKey.mailInConfiguration`. Defaults: port 993, folder "NoteIt", mark as read, notebook nil (= notebook for new notes), 15 minutes, allowed senders seeded with the user name when it contains `@`.
- [ ] `MailInKeychain` uses `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` with service `io.github.rutbergphilip.noteit.mail-in` and `kSecAttrAccessibleAfterFirstUnlock`. It does not use `Sync/Keychain.swift`, so `Keychain.deleteAll()` leaves it alone.
- [ ] `MailInState` reads and writes `<NoteStore.rootURL>/mail-in-state.json`: `uidValidity`, `lastCheck`, `lastResult`, and the SHA-256 of up to 2,000 imported Message-IDs (oldest dropped). `messageKey(for:)` hashes the Message-ID, or `Date`+`From`+`Subject`+size when there is none.
- [ ] `MailInStatus` text follows the table in spec §4.5. `MailInBackoff.delay` returns 1, 2, 4, 8, 16, 32, 60, 60 … minutes and the normal interval once a check succeeds.
- [ ] `isAllowed(sender:)`: case-insensitive exact address or `@domain` entry; empty list blocks all; `acceptsAnySender` allows all.
- [ ] Tests: configuration round trip; sender rules; state keeps the last 2,000 keys; key fallback without Message-ID; backoff sequence; Keychain tests use a unique test service name and clean up.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MailInStateTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(mail): add email-in configuration and state`

### Task 25: HTML sanitizer and mail note builder [S: Tasks 2, 22]

**Files:**
- Create: `Sources/NoteIt/MailIn/MailHTMLSanitizer.swift`, `Sources/NoteIt/MailIn/MailNoteBuilder.swift`
- Test: `Tests/NoteItTests/MailHTMLSanitizerTests.swift`, `Tests/NoteItTests/MailNoteBuilderTests.swift`

- [ ] `MailHTMLSanitizer.sanitize` parses with `XMLDocument(xmlString:options: .documentTidyHTML)` and removes `script`, `style`, `link`, `iframe`, `object`, `embed`, `form`, `meta` and every `on*` attribute. `img` with `cid:` is replaced by a `data:` URL from the matching inline part (the builder passes them in); any other `img` becomes `<a href="src">[image]</a>`. Unparseable HTML falls back to the plain text part. HTML over 2 MB is not converted; the plain text part (or the HTML stripped of tags) is used instead.
- [ ] `MailNoteBuilder.body` follows spec §4.3: HTML through `AppleNotesImporter.convert(html:title:)`, else plain text paragraphs; cap at `CaptureFormatter.maxSelectionLength`; up to 20 file attachments of at most `AttachmentLimit.maxBytes` (`NoteItDoc`) each, with a "Skipped attachment: <name> (too large)" line for the rest; source line "From <name or address> by email · <date>". `title(for:)` uses `CaptureTitler` with `.email`.
- [ ] Tests: no `http` image URL survives sanitizing any fixture; tracking pixels become links; inline images become attachments; the 21st attachment is skipped with a line; titles strip `Re:`/`Fwd:`; the source line format.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'MailHTMLSanitizerTests|MailNoteBuilderTests|AppleNotesHTMLTests' 2>&1 | tail -20` passes.
- [ ] Commit: `feat(mail): turn email messages into notes`

### Task 26: Mail-in controller [S: Tasks 23-25]

**Files:**
- Create: `Sources/NoteIt/MailIn/MailInController.swift`
- Modify: `Sources/NoteIt/App/AppDelegate.swift`, `Sources/NoteIt/Capture/CaptureCommands.swift`
- Test: `Tests/NoteItTests/MailInControllerTests.swift`

- [ ] `MailInController.shared` with an `Environment` (client factory, Keychain, state, store, clock, path monitor, wake notifications). `start()` runs at launch when enabled; checks run on the interval, 30 s after wake, and when `NWPathMonitor` reports the network back, never more than once a minute and never two at once.
- [ ] A check (5-minute limit): connect, log in, select the folder, `UID SEARCH UNSEEN UNKEYWORD $NoteIt`, fetch summaries, filter by sender, `dmarc=fail`, size and `MailInState`, take the 25 oldest, then for each: fetch, parse, build, `createImportedNote(body:title:notebookID:createdAt:updatedAt:)` with the date rule from spec §4.3, then `persist(note.id)` (`store.persistNow` in the app; the `Environment` gains `persist: (UUID) throws -> Void`), and only after it returns record the key, then mark as read or move. If `persist` throws, the key is not recorded and nothing is sent to the server for that message, so it stays eligible; the controller keeps `messageKey → noteID` in memory, and a later check that meets the same key while that note is still in the store calls `persist` on it instead of creating a second note. The check stops after the first `persist` failure with `.serverError(message: "Couldn't save the note")` (retry at the next interval). After the check, call `CaptureTitleRefinement.refineIfUnchanged` for each saved note. Count saved and skipped; log failures without message content.
- [ ] Map errors to `MailInStatus`: unreachable or timeout → `.offline` with backoff; `.authenticationFailed` → `.signInFailed` (stop); `.untrustedCertificate` → stop with the fingerprint; `.noSuchMailbox` → `.folderMissing`; `NO`/`BAD` → `.serverError` (retry at the next interval). `trustCertificate` saves the fingerprint in the configuration and checks again; `createMissingFolder` sends `CREATE` and checks again.
- [ ] `stop(deletingCredentials: true)` removes the password and `mail-in-state.json` and keeps the notes.
- [ ] Replace `CaptureCommands.checkMailNow()` and `isMailInEnabled`.
- [ ] Tests with a fake client: only allowed, unread, unseen-by-NoteIt messages become notes; a Message-ID seen before is skipped even if the server lost the flag; flags or move are sent only after `persist` returns; `testPersistFailureKeepsMessageEligible` (a failing `persist` records no key and sends no `STORE`, `MOVE`, `COPY` or `EXPUNGE`); `testRetryAfterPersistFailureDoesNotDuplicate` (the next check with a working `persist` makes no second note, then records the key and marks the message); a failing flag doesn't cause a second import; 30 messages → 25 then 5; each error maps to its status; backoff timing; turning off deletes the password and state.
- [ ] Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MailInControllerTests 2>&1 | tail -20` passes.
- [ ] Commit: `feat(mail): check a mailbox and save new messages as notes`

### Task 27: Email-in settings and status [S: Task 26]

**Files:**
- Create: `Sources/NoteIt/Settings/MailInSettingsSection.swift`, `Sources/NoteIt/Settings/MailInSetupSheet.swift`
- Modify: `Sources/NoteIt/Settings/GeneralSettingsView.swift`, `Sources/NoteIt/MenuBar/MenuBarView.swift`

- [ ] Fill the `GeneralSettingsSection.emailIn` case of the General form and set its `isAvailable` to true; the section sits at its frozen place, after Capture. Update `GeneralSettingsSectionTests` so the available set includes `emailIn`. The section (spec §4.6): off state with **Set Up Email-in…**; the setup sheet with presets (iCloud Mail, Fastmail, Gmail, Other), host, user name, password, folder, **Test Connection** showing "<n> unread messages in <folder> will become notes.", and **Turn On**; the connected state with account, folder, allowed senders, Accept mail from anyone (with its warning), After saving, Save to, Check every, **Check Now**, **Turn Off…**, the status line and the one-Mac note.
- [ ] Show the **Trust This Certificate** button with the fingerprint for `.untrustedCertificate`, and **Create Folder** for `.folderMissing`.
- [ ] Show one status line in the menu bar panel footer only for failure states.
- [ ] Verify: `swift build -c release 2>&1 | tail -5` ends with `Build complete!`.
- [ ] Manual with a test account and `NOTEIT_DATA_DIR=<project>/.selftest/mail`: set up, test the connection, send three messages (one from a blocked sender, one with an attachment, one HTML newsletter), click Check Now; two notes appear with the right titles, the blocked message stays unread, the server shows the others as read with `$NoteIt`; change the password to a wrong one → "Sign-in failed"; turn off → the Keychain item is gone (`security find-generic-password -s io.github.rutbergphilip.noteit.mail-in` finds nothing).
- [ ] Commit: `feat(mail): add email-in settings`

### Milestone 7: Docs and final checks

### Task 28: Documentation [S: Milestones 1-6]

**Files:**
- Modify: `docs/architecture.md`, `docs/known-limitations.md`, `docs/roadmap.md`, `docs/keyboard-shortcuts.md`, `docs/development.md`, `README.md`

- [ ] `docs/architecture.md`: add `capture-pending/`, `attachment-text.json` and `mail-in-state.json` to the storage tree under the data folder (`NoteStore.rootURL`); extend the Capture section with the four new paths and the `NoteItMail` target.
- [ ] `docs/known-limitations.md`: Screen Recording grant needs a relaunch; voice notes need the app bundle; transcription quality depends on the installed on-device model; email-in needs app-specific passwords and port 993; Append to Today needs daily notes from `linking`; Find text in images is off until turned on.
- [ ] `docs/roadmap.md`: tick screenshot to text and voice notes; add email-in and Append to Today.
- [ ] `docs/keyboard-shortcuts.md`: the three new global hotkeys (unbound by default), the File › Capture submenu, and the panel keys (Return, Esc).
- [ ] `docs/development.md`: `NOTEIT_DEBUG_SCREENSHOT_FILE`, `NOTEIT_DEBUG_VOICE_FILE`, `NOTEIT_MAIL_LIVE_TEST`, `NOTEIT_MAIL_LIVE_PASSWORD`, and that permission features need `scripts/build_app.sh`.
- [ ] `README.md`: one line each for the new capture features in the feature list.
- [ ] Verify: `grep -rn 'NOTEIT_DEBUG_SCREENSHOT_FILE' docs/development.md` finds the entry; links in changed docs resolve (`grep -o '](\.\./[^)]*)' docs/*.md`).
- [ ] Commit: `docs: describe capture plus features`

### Task 29: Full verification [S: Task 28]

- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`: all suites pass, `IMAPLiveTests` skipped.
- [ ] `swift build -c release 2>&1 | tail -5` ends with `Build complete!` with no new warnings.
- [ ] `NOTEIT_INSTALL_DIR="$PWD/.selftest/app" ./scripts/build_app.sh` builds and signs; open `.selftest/app/NoteIt.app` with `NOTEIT_DATA_DIR="$PWD/.selftest/capture-plus-final"` (`NOTEIT_DATA_DIR="$PWD/.selftest/capture-plus-final" .selftest/app/NoteIt.app/Contents/MacOS/NoteIt`) and run each manual check from Tasks 8, 12, 17, 18, 20 and 27 once more.
- [ ] Check that sync never uploads `attachment-text.json`, `mail-in-state.json` or `capture-pending/` (connect a test sync account, list the remote files).
- [ ] Check Settings > Shortcuts, the File menu and the palette all show the new commands, and Capture Selection still works with an existing binding.

## Self-review

- **Spec coverage.**
  - Spec §1 (shared pieces): Tasks 1, 3 and 4.
  - §2 Screenshot to Text: Tasks 5–8, with background reading and search in Tasks 9–12.
  - §3 Voice notes: Tasks 13–18.
  - §4 Email-in: Tasks 21–27.
  - §5 Auto titles: Task 2, used in Tasks 8, 17, 25 and 26 (refinement after save).
  - §6 Append to Today: Tasks 19–20.
  - General settings form: foundations task 6.5 (formerly Task 0); this plan adds rows (Task 12) and the Email-in section (Task 27).
  - Docs: Task 28.
- **Frozen decisions.**
  - The three hotkeys sit at positions 9–11 of the frozen table, are unbound, and each lands with its `ShortcutsSettingsView` tile and `AppDelegate` handler case.
  - The menu items are in the File › Capture submenu; every command is in the palette.
  - `App/MenuShortcuts.swift` is untouched because the new menu items have no default shortcut.
  - New notes use `createNote` and `createImportedNote`; every change to an existing note goes through `NoteStore.editBody`. There are no `appendParagraphs` or `replaceParagraph` primitives.
  - Append to Today calls `linking`'s `DailyLogAppender`; Capture Plus has no daily-note provider, fallback daily note or appender. URL, CLI, Shortcuts and Local API entry points are `automation`'s.
  - The image text indexer is a `DerivedIndex`; its file is in `NoteStore.rootURL`; locked notes are left out; it is off by default and offered once, in a one-time notice, after the first Screenshot to Text. Search, `ImageTextProviding` and the "Found in an image" label are `organise`'s; Capture Plus registers the provider.
  - Capture Plus owns `CaptureTitleRefining`; `private-ai` provides the implementation.
  - Capture Plus owns the `CaptureFormatter.sourceLine` extraction that `web-clipper` reuses. Both are in wave 2; Task 7 merges before the clipper task that calls `sourceLine(linkingTo:label:appName:)`.
  - The General tab is the scrolling form from foundations task 6.5; Capture Plus adds rows to `capture` and flips `emailIn.isAvailable`.
  - The 25 MB cap is `NoteItDoc`'s `AttachmentLimit.maxBytes`. No new embeds rows; the microphone entitlement goes through the app's row.
- **Dependencies.**
  - No third-party packages are added.
  - `NoteItMail` uses Foundation and Network only.
  - The macOS 26 speech engine is behind `#if compiler(>=6.2)` and `@available(macOS 26, *)`, so the macos-15 CI build compiles.
- **Testability.**
  - Every system service is behind a protocol or `Environment`, and the unit tests need no permissions, network or microphone.
  - Real Vision runs in one test.
  - Real IMAP runs only in the opt-in live test.
- **Privacy.**
  - Text recognition and transcription stay on the Mac.
  - Sanitized email HTML never loads remote content.
  - The mail password lives under its own Keychain service and is never logged.
  - `attachment-text.json`, `mail-in-state.json` and `capture-pending/` stay local.
- **Interface consistency.** Names in Frozen interfaces match the tasks: `CaptureOutcome.saved(... detail:)`, `appended(noteID:dayTitle:line:)`, `AppendTodayController`, `TranscriptPlacement`, `CaptureTitleRefinement`, `AttachmentTextStore`, `IMAPClient.SelectedMailbox`, `MailInConfiguration.pinnedCertificateSHA256`.
- **Risks to watch.**
  - `screencapture -i` behaviour differs slightly between macOS versions (Task 5 checks by exit code and file, not output).
  - `SFSpeechRecognizer` on-device support varies by locale (Task 14 reports `.onDeviceUnavailable` instead of falling back to the server).
  - `XMLDocument` HTML tidying is lenient but slow on very large newsletters; Task 25 caps the HTML input at 2 MB.
