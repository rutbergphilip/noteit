import AppKit
import NoteItAPI
import NoteItCore

/// Runs `noteit://` links: parses them with `URLCommand.parse`, asks before a link changes notes, runs the command
/// through `AutomationService` and calls the link's x-callback-url callbacks.
@MainActor
final class URLSchemeHandler: NSObject {
    /// Everything that touches the UI or the outside world, so tests can replace it.
    struct Environment {
        /// Shows the question with Allow and Don't Allow; true for Allow.
        var confirm: @MainActor (String) -> Bool
        var notify: @MainActor (String) -> Void
        var openCallback: @MainActor (URL) -> Void
        var showNote: @MainActor (UUID, String?) -> Void
        var showSaved: @MainActor (NoteMeta, String?) -> Void
        var showSearch: @MainActor (String) -> Void
        var showSettings: @MainActor (SettingsView.Tab) -> Void
        var dailyAvailable: @MainActor () -> Bool

        static var live: Environment {
            Environment(
                confirm: URLSchemeHandler.askToAllow,
                notify: URLSchemeHandler.showNotice,
                openCallback: { NSWorkspace.shared.open($0) },
                showNote: URLSchemeHandler.reveal,
                showSaved: { meta, notebookName in
                    let outcome = CaptureOutcome.saved(noteID: meta.id, notebookName: notebookName, title: meta.title)
                    CaptureToastController.shared.show(CaptureToastContent(outcome)) { event in
                        if event == .body { URLSchemeHandler.reveal(meta.id, heading: nil) }
                    }
                },
                showSearch: { query in
                    WindowRouter.showMainWindow()
                    NoteStore.shared.selection = .allNotes
                    NoteStore.shared.searchText = query
                    WindowRouter.focusSearch()
                },
                showSettings: { SettingsTabRouter.show($0) },
                dailyAvailable: { DailyNotes.isAvailable }
            )
        }
    }

    static let shared = URLSchemeHandler(service: .shared, registry: .shared, defaults: .standard, environment: .live)

    static let unknownLinkMessage = "NoteIt doesn't know this link."

    let service: AutomationService
    let registry: URLRouteRegistry
    let defaults: UserDefaults
    var environment: Environment

    init(service: AutomationService, registry: URLRouteRegistry, defaults: UserDefaults, environment: Environment) {
        self.service = service
        self.registry = registry
        self.defaults = defaults
        self.environment = environment
    }

    /// Installs the `kAEGetURL` handler, so SwiftUI never opens a window for a link.
    func install() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        handle(url)
    }

    /// Runs everything up to and including the question synchronously, so the modal alert never runs inside a
    /// main-actor job. Returns the task that finishes an allowed change, if there is one.
    @discardableResult
    func handle(_ url: URL) -> Task<Void, Never>? {
        switch URLCommand.parse(url) {
        case .success(let (command, callback)):
            return run(command, callback: callback)
        case .failure(let error):
            let failure: AutomationError
            switch error {
            case .tooLarge: failure = .tooLarge
            case .unknownHost, .invalid: failure = .invalidInput(Self.unknownLinkMessage)
            }
            report(failure, callback: Self.callbacks(of: url))
            return nil
        }
    }

    // MARK: Commands

    private func run(_ command: URLCommand, callback: XCallback) -> Task<Void, Never>? {
        do {
            switch command {
            case let .note(id, heading):
                try showNote(id, heading: heading, callback: callback)
            case let .noteTitle(title, heading):
                if let meta = service.findByTitle(title) {
                    try show(meta, heading: heading, callback: callback)
                } else {
                    environment.showSearch(title)
                    succeed(callback, note: nil)
                }
            case let .open(.id(id)):
                try showNote(id, heading: nil, callback: callback)
            case let .open(.title(title)):
                if let meta = service.findByTitle(title) {
                    try show(meta, heading: nil, callback: callback)
                } else {
                    environment.showSearch(title)
                    succeed(callback, note: nil)
                }
            case let .search(query):
                environment.showSearch(query)
                succeed(callback, note: nil)
            case let .settings(tab):
                environment.showSettings(SettingsView.Tab(rawValue: tab) ?? .general)
                succeed(callback, note: nil)
            case .daily:
                try requireDailyNotes()
                guard let meta = try service.daily(date: service.now(), create: true) else { throw AutomationError.notFound }
                try show(meta, heading: nil, callback: callback)
            case let .new(title, text, notebook, tags, open):
                try create(title: title, text: text, notebook: notebook, tags: tags, open: open, callback: callback)
            case let .append(target, text, position, timestamp):
                return try append(to: target, text: text, position: position, timestamp: timestamp, callback: callback)
            case .shareInbox:
                // Never asks: the user pressed Save in the Share sheet. Importing comes with automation Task 24.
                throw AutomationError.invalidInput(Self.unknownLinkMessage)
            case let .registered(host, url):
                guard let handler = registry.handler(for: host) else {
                    throw AutomationError.invalidInput(Self.unknownLinkMessage)
                }
                handler(url)
            }
        } catch {
            fail(error, callback: callback)
        }
        return nil
    }

    private func fail(_ error: any Error, callback: XCallback) {
        switch error {
        case let failure as ConcealedFailure:
            report(failure.error, callback: callback, concealed: true)
        case let error as AutomationError:
            if error == .cancelled {
                if let cancel = callback.cancel { environment.openCallback(cancel) }
            } else {
                report(error, callback: callback)
            }
        default:
            report(.invalidInput(Self.unknownLinkMessage), callback: callback)
        }
    }

    /// With a web callback a note that can't be shown gets a local notice and a bare `x-success`, the same as a
    /// note that is shown, so the page can't tell whether it exists.
    private func showNote(_ id: UUID, heading: String?, callback: XCallback) throws(AutomationError) {
        do {
            try show(try service.note(id), heading: heading, callback: callback)
        } catch {
            guard Self.hasWebCallback(callback) else { throw error }
            environment.notify(error.message)
            succeed(callback, note: nil)
        }
    }

    private func show(_ meta: NoteMeta, heading: String?, callback: XCallback) throws(AutomationError) {
        try service.ensureReady()
        environment.showNote(meta.id, meta.isLocked ? nil : heading)
        succeed(callback, note: meta)
    }

    private func create(title: String?, text: String, notebook: String?, tags: [String], open: Bool,
                        callback: XCallback) throws {
        let ref = notebook.map { UUID(uuidString: $0).map(NotebookRef.id) ?? .name($0) }
        let notebookName: String?
        do {
            try service.ensureReady()
            notebookName = try service.resolveNotebook(ref).flatMap { service.store.notebook(with: $0)?.name }
        } catch {
            let question = switch ref {
            case .name(let name): "A link wants to create a note in “\(name)”."
            case .id, .none: "A link wants to create a note."
            }
            try concealFromWeb(error, callback: callback, question: question)
        }
        try askFirst("A link wants to create a note in “\(notebookName ?? "NoteIt")”.", callback: callback)
        let meta = try service.create(title: title, body: text, format: .text, notebook: ref, tags: tags, pinned: false)
        if open {
            environment.showNote(meta.id, nil)
        } else {
            environment.showSaved(meta, notebookName)
        }
        succeed(callback, note: meta)
    }

    private func append(to target: URLCommand.AppendTarget, text: String, position: AppendPosition, timestamp: Bool,
                        callback: XCallback) throws -> Task<Void, Never>? {
        if target == .daily {
            try appendToDaily(text: text, timestamp: timestamp, callback: callback)
            return nil
        }
        let meta: NoteMeta
        do {
            meta = try appendTarget(target)
        } catch {
            let question = switch target {
            case .id: "A link wants to add text to a note."
            case .title(let title): "A link wants to add text to “\(title)”."
            case .daily: "A link wants to add text to today's daily note."
            }
            try concealFromWeb(error, callback: callback, question: question)
        }
        try askFirst("A link wants to add text to “\(meta.displayTitle)”.", callback: callback)
        return Task {
            do {
                let result = try await service.append(meta.id, text: text, format: .text, position: position,
                                                      timestamp: timestamp, ifRevision: nil)
                succeed(callback, note: result)
            } catch {
                fail(error, callback: callback)
            }
        }
    }

    /// Through `DailyLogAppender`, which creates the day's note if needed, so nothing is created before the question.
    private func appendToDaily(text: String, timestamp: Bool, callback: XCallback) throws {
        let question = "A link wants to add text to today's daily note."
        // One reading of the clock, so the note the user approves is the one written to, even across midnight.
        let day = service.now()
        let existing: NoteMeta?
        do {
            try requireDailyNotes()
            existing = try service.daily(date: day, create: false)
            if let existing {
                if existing.isLocked { throw AutomationError.noteLocked }
                if service.store.isBodyWriteBlocked(existing.id) { throw AutomationError.noteUnreadable }
            }
        } catch let error as AutomationError {
            try concealFromWeb(error, callback: callback, question: question)
        }
        try askFirst(existing.map { "A link wants to add text to “\($0.displayTitle)”." } ?? question, callback: callback)
        let meta = try service.appendToDaily(text: text, format: .plain, timestamp: timestamp, date: day)
        succeed(callback, note: meta)
    }

    private func appendTarget(_ target: URLCommand.AppendTarget) throws(AutomationError) -> NoteMeta {
        try service.ensureReady()
        let meta: NoteMeta
        switch target {
        case .id(let id):
            meta = try service.note(id)
        case .title(let title):
            guard let match = service.findByTitle(title) else { throw .noteTitleNotFound }
            meta = match
        case .daily:
            throw .invalidInput(Self.unknownLinkMessage)
        }
        if meta.deletedAt != nil { throw .noteDeleted }
        if meta.isLocked { throw .noteLocked }
        if service.store.isBodyWriteBlocked(meta.id) { throw .noteUnreadable }
        return meta
    }

    /// A failure before the question would tell a web page whether a note or notebook exists, or is locked. With
    /// an `http(s)` callback the link asks anyway, in words taken only from the link, and then fails with
    /// `not_changed`, so the page sees the same as for Don't Allow or a later failure.
    private func concealFromWeb(_ error: AutomationError, callback: XCallback, question: String) throws -> Never {
        guard Self.hasWebCallback(callback) else { throw error }
        try askFirst(question, callback: callback)
        throw ConcealedFailure(error: error)
    }

    private struct ConcealedFailure: Error { var error: AutomationError }

    static func hasWebCallback(_ callback: XCallback) -> Bool {
        [callback.success, callback.error, callback.cancel].contains { $0.map { !XCallback.mayReceiveNoteDetails($0) } ?? false }
    }

    private func requireDailyNotes() throws(AutomationError) {
        guard environment.dailyAvailable() else { throw .dailyNotesUnavailable }
    }

    /// Links with a web callback always ask, so a page never learns about a note without the user's consent.
    private func askFirst(_ question: String, callback: XCallback) throws(AutomationError) {
        guard Self.hasWebCallback(callback) || !defaults.bool(forKey: PrefKey.urlSchemeChangesWithoutAsking) else { return }
        guard environment.confirm(question) else { throw .cancelled }
    }

    // MARK: Callbacks

    private func succeed(_ callback: XCallback, note: NoteMeta?) {
        guard let success = callback.success else { return }
        var items: [URLQueryItem] = []
        if let note, XCallback.mayReceiveNoteDetails(success) {
            items = [URLQueryItem(name: "id", value: note.id.uuidString),
                     URLQueryItem(name: "title", value: note.title),
                     URLQueryItem(name: "url", value: AutomationService.link(for: note.id).absoluteString)]
        }
        environment.openCallback(URLCommand.callbackURL(success, adding: items))
    }

    /// Calls x-error when the link has one; otherwise shows the error, so a link never fails silently. A
    /// `concealed` error reaches x-error only as `not_changed`, and is always shown, so the user sees why.
    private func report(_ error: AutomationError, callback: XCallback, concealed: Bool = false) {
        if concealed { environment.notify(error.message) }
        guard let failure = callback.error else {
            if !concealed { environment.notify(error.message) }
            return
        }
        let sent = concealed ? AutomationError.notChanged : error
        var items = [URLQueryItem(name: "errorCode", value: sent.callbackCode)]
        if XCallback.mayReceiveNoteDetails(failure) {
            items.append(URLQueryItem(name: "errorMessage", value: sent.message))
        }
        environment.openCallback(URLCommand.callbackURL(failure, adding: items))
    }

    /// The callbacks of a link that didn't parse, read through a link that always does.
    static func callbacks(of url: URL) -> XCallback {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return XCallback() }
        components.queryItems = components.queryItems?.filter { $0.name.lowercased().hasPrefix("x-") }
        components.host = "daily"
        components.path = ""
        components.fragment = nil
        guard let probe = components.url, case let .success((_, callback)) = URLCommand.parse(probe) else { return XCallback() }
        return callback
    }

    // MARK: Live UI

    private static func askToAllow(_ question: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func showNotice(_ message: String) {
        CaptureToastController.shared.show(CaptureToastContent(symbol: "link", tone: .warning, title: message)) { _ in }
    }

    /// Shows the note in the main window, with the caret at `heading` when the note has one.
    static func reveal(_ id: UUID, heading: String?) {
        let store = NoteStore.shared
        WindowRouter.showMainWindow()
        if let heading, let location = headingLocation(heading, in: store.body(for: id)) {
            if let textView = OpenEditorRegistry.shared.textView(for: id) {
                textView.setSelectedRange(NSRange(location: location, length: 0))
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            } else {
                RichTextEditor.pendingCaret[id] = location
            }
        }
        if store.note(with: id)?.deletedAt != nil {
            store.searchText = ""
            store.selection = .recentlyDeleted
            store.selectedNoteID = id
        } else {
            store.reveal(id)
        }
    }

    /// The start of the first title, heading or subheading paragraph whose text is `heading`, ignoring case.
    static func headingLocation(_ heading: String, in body: NSAttributedString) -> Int? {
        let wanted = heading.trimmingCharacters(in: .whitespaces)
        let text = body.string as NSString
        var found: Int?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { line, range, _, stop in
            guard let line, range.length > 0,
                  line.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame else { return }
            let kind = EditorStyle.blockKind(paragraphStyle: body.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                                             font: body.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            guard kind == .title || kind == .heading || kind == .subheading else { return }
            found = range.location
            stop.pointee = true
        }
        return found
    }
}
