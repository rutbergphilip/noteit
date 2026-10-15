import AppKit

/// What a capture ended with; each outcome maps to one toast.
enum CaptureOutcome: Equatable {
    case saved(noteID: UUID, notebookName: String?, title: String)
    case nothingSelected
    case notTrusted
    case clipboardEmpty
    case noteItFrontmost
}

enum CaptureToastButton: String, Equatable {
    case allowAccess
    case captureClipboard

    var title: String {
        switch self {
        case .allowAccess: "Allow Access…"
        case .captureClipboard: "Capture Clipboard"
        }
    }
}

enum CaptureToastEvent: Equatable {
    case body
    case button(CaptureToastButton)
}

struct CaptureToastContent: Equatable {
    enum Tone: Equatable { case success, neutral, warning }

    var symbol: String
    var tone: Tone
    var title: String
    var message: String?
    var buttons: [CaptureToastButton] = []
    /// Clicking the notice opens the saved note, which brings NoteIt forward.
    var opensNoteOnClick = false
    /// Stands in until the result replaces it; ignores clicks.
    var isPending = false

    init(symbol: String, tone: Tone, title: String, message: String? = nil, buttons: [CaptureToastButton] = [],
         opensNoteOnClick: Bool = false, isPending: Bool = false) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.message = message
        self.buttons = buttons
        self.opensNoteOnClick = opensNoteOnClick
        self.isPending = isPending
    }

    static let saving = CaptureToastContent(symbol: "tray.and.arrow.down", tone: .neutral, title: "Saving…",
                                            isPending: true)

    func opensNoteIt(on event: CaptureToastEvent) -> Bool {
        event == .body && opensNoteOnClick
    }

    init(_ outcome: CaptureOutcome) {
        switch outcome {
        case let .saved(_, notebookName, title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(symbol: "checkmark", tone: .success,
                      title: "Saved to \(notebookName ?? "NoteIt")",
                      message: trimmed.isEmpty ? "Untitled" : trimmed, opensNoteOnClick: true)
        case .nothingSelected:
            self.init(symbol: "text.cursor", tone: .neutral, title: "Nothing selected",
                      message: "Select some text, then try again.")
        case .notTrusted:
            self.init(symbol: "hand.raised.fill", tone: .warning, title: "Allow NoteIt to read selected text",
                      message: "Or save what's on the clipboard instead.",
                      buttons: [.captureClipboard, .allowAccess])
        case .clipboardEmpty:
            self.init(symbol: "clipboard", tone: .neutral, title: "Nothing on the clipboard",
                      message: "Copy some text, then try again.")
        case .noteItFrontmost:
            self.init(symbol: "macwindow", tone: .neutral, title: "Select text in another app",
                      message: "Capture Selection saves text from the app you're using.")
        }
    }
}

/// Runs Capture Selection (global hotkey), the Capture to NoteIt Service and Capture Clipboard.
@MainActor
final class CaptureController {
    @MainActor
    struct Environment {
        var frontmostApplication: () -> NSRunningApplication?
        var isNoteIt: (NSRunningApplication) -> Bool
        var isTrusted: () -> Bool
        var readSelection: (NSRunningApplication) async -> SelectionReadResult
        var resolveSource: (NSRunningApplication, Bool) async -> CaptureSource
        var clipboardText: () -> String?
        var store: () -> NoteStore
        var defaults: UserDefaults
        var showToast: (CaptureToastContent, @escaping (CaptureToastEvent) -> Void) -> Void
        var requestAccess: () -> Void
        var openNote: (UUID) -> Void
        var requestBrowserConsent: (String) -> Void

        static var live: Environment {
            Environment(
                frontmostApplication: { NSWorkspace.shared.frontmostApplication },
                isNoteIt: { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier },
                isTrusted: { AccessibilityAccess.isTrusted },
                readSelection: { await SelectionReader.readSelection(from: $0) },
                resolveSource: { await SourceResolver.resolve(app: $0, includeBrowserLinks: $1) },
                clipboardText: { NSPasteboard.general.string(forType: .string) },
                store: { NoteStore.shared },
                defaults: .standard,
                showToast: { CaptureToastController.shared.show($0, onEvent: $1) },
                requestAccess: { AccessibilityAccess.requestAccess() },
                openNote: { id in
                    WindowRouter.showMainWindow()
                    NoteStore.shared.reveal(id)
                },
                requestBrowserConsent: { BrowserPageReader.requestConsentIfNeeded(bundleID: $0) }
            )
        }
    }

    static let shared = CaptureController(environment: .live)

    private let environment: Environment
    private(set) var isCapturing = false

    init(environment: Environment) {
        self.environment = environment
    }

    var includesBrowserLinks: Bool {
        environment.defaults.object(forKey: PrefKey.captureIncludesBrowserLinks) as? Bool ?? true
    }

    /// Global hotkey entry point. The front app is recorded right away; a press while a capture is
    /// still running is ignored.
    func captureSelection() {
        guard !isCapturing, let app = environment.frontmostApplication() else { return }
        if environment.isNoteIt(app) {
            present(.noteItFrontmost, app: nil)
            return
        }
        isCapturing = true
        Task { await self.runCapture(from: app) }
    }

    /// Captures the selection of `app`. Returns nil if another capture is still running.
    @discardableResult
    func capture(from app: NSRunningApplication) async -> CaptureOutcome? {
        guard !isCapturing else { return nil }
        isCapturing = true
        return await runCapture(from: app)
    }

    /// Saves text handed over by the Services menu, crediting the app that sent it.
    @discardableResult
    func captureServiceText(_ text: String?, from app: NSRunningApplication?) async -> CaptureOutcome {
        let text = text ?? ""
        guard !Self.isBlank(text) else {
            present(.nothingSelected, app: nil)
            return .nothingSelected
        }
        let source: CaptureSource
        if let app {
            source = await environment.resolveSource(app, includesBrowserLinks)
        } else {
            source = CaptureSource(appName: "", bundleID: nil, windowTitle: nil, pageURL: nil, pageTitle: nil, documentURL: nil)
        }
        let outcome = save(text, source: source) ?? .nothingSelected
        present(outcome, app: app)
        return outcome
    }

    /// Without Accessibility nothing is read or resolved, so no browser Automation prompt appears on top of
    /// the notice; the source is resolved only if the user captures the clipboard instead.
    private func runCapture(from app: NSRunningApplication) async -> CaptureOutcome {
        defer { isCapturing = false }
        guard environment.isTrusted() else {
            present(.notTrusted, app: app)
            return .notTrusted
        }
        let resolve = environment.resolveSource
        let includeLinks = includesBrowserLinks
        let resolving = Task { await resolve(app, includeLinks) }
        let result = await environment.readSelection(app)
        if result == .notTrusted {
            resolving.cancel()
            present(.notTrusted, app: app)
            return .notTrusted
        }
        let source = await resolving.value
        let finished = outcome(for: result, source: source)
        present(finished, app: app)
        return finished
    }

    /// Capture Clipboard: saves the clipboard text, crediting the app the capture started in. A "Saving…"
    /// notice takes the place of the clicked one right away and stays until the result replaces it.
    /// Returns nil, showing nothing, while another capture is running.
    @discardableResult
    func captureClipboard(from app: NSRunningApplication) -> Task<CaptureOutcome, Never>? {
        guard !isCapturing else { return nil }
        let text = environment.clipboardText() ?? ""
        guard !Self.isBlank(text) else {
            present(.clipboardEmpty, app: nil)
            return Task { .clipboardEmpty }
        }
        isCapturing = true
        environment.showToast(.saving) { _ in }
        let includeLinks = includesBrowserLinks
        return Task {
            defer { self.isCapturing = false }
            let source = await self.environment.resolveSource(app, includeLinks)
            let saved = self.save(text, source: source) ?? .clipboardEmpty
            self.present(saved, app: app)
            return saved
        }
    }

    func outcome(for result: SelectionReadResult, source: CaptureSource) -> CaptureOutcome {
        switch result {
        case .text(let text):
            return save(text, source: source) ?? .nothingSelected
        case .empty:
            return .nothingSelected
        case .notTrusted:
            return .notTrusted
        }
    }

    /// Saves a new note to the notebook for new notes, without selecting or opening it. Only once something
    /// was saved may macOS ask to let NoteIt read browser page links, for the next capture.
    func save(_ text: String, source: CaptureSource) -> CaptureOutcome? {
        guard !Self.isBlank(text) else { return nil }
        let store = environment.store()
        let notebookID = store.defaultNotebookIDForNewNotes
        let selection = CapturedSelection(text: text, source: source)
        let meta = store.createNote(in: notebookID, initial: CaptureFormatter.noteContent(for: selection))
        if includesBrowserLinks, let bundleID = source.bundleID {
            environment.requestBrowserConsent(bundleID)
        }
        return .saved(noteID: meta.id, notebookName: store.notebook(with: notebookID)?.name, title: meta.title)
    }

    func handle(_ event: CaptureToastEvent, outcome: CaptureOutcome, app: NSRunningApplication?) {
        switch event {
        case .body:
            if case let .saved(noteID, _, _) = outcome { environment.openNote(noteID) }
        case .button(.allowAccess):
            environment.requestAccess()
        case .button(.captureClipboard):
            guard let app else { return }
            captureClipboard(from: app)
        }
    }

    private func present(_ outcome: CaptureOutcome, app: NSRunningApplication?) {
        environment.showToast(CaptureToastContent(outcome)) { [weak self] event in
            self?.handle(event, outcome: outcome, app: app)
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
