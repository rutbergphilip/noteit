import AppKit
import Combine
import SwiftUI

/// Bridges the toolbar (SwiftUI) and the active text view.
@MainActor
final class EditorController: ObservableObject {
    @Published private(set) var state = FormattingState()
    weak var textView: NoteItTextView?

    func perform(_ command: FormatCommand) {
        guard let textView, textView.isEditable else { return }
        textView.perform(command)
        refresh()
    }

    func refresh() {
        guard let textView else { return }
        let new = textView.currentFormattingState()
        if new != state { state = new }
    }
}

/// Rich text editor for one note. Edits are committed to `NoteStore` after a short idle period
/// (snapshotting the document and re-deriving title/tags is too costly per keystroke), and
/// synchronously on note switch, teardown, window/app deactivation and termination.
struct RichTextEditor: NSViewRepresentable {
    let noteID: UUID
    var controller: EditorController?
    var isEditable: Bool

    init(noteID: UUID, controller: EditorController? = nil, isEditable: Bool = true) {
        self.noteID = noteID
        self.controller = controller
        self.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator { Coordinator(noteID: noteID, controller: controller ?? EditorController()) }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = NoteItTextView.make()
        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.isEditable = isEditable
        textView.delegate = coordinator
        coordinator.controller.textView = textView
        textView.formattingDidChange = { [weak coordinator] in coordinator?.controller.refresh() }
        coordinator.load()
        coordinator.observeLifecycle()
        #if DEBUG
        EditorSelfTest.startIfRequested()
        StoreSelfTest.startIfRequested()
        #endif
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if let textView = coordinator.textView, textView.isEditable != isEditable {
            if !isEditable { coordinator.commit() }
            textView.isEditable = isEditable
            textView.needsDisplay = true
        }
        if let controller, controller !== coordinator.controller {
            coordinator.controller = controller
            controller.textView = coordinator.textView
            controller.refresh()
        }
        if coordinator.noteID != noteID {
            coordinator.commit(deferred: true)
            coordinator.noteID = noteID
            coordinator.load()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Runs inside a SwiftUI view update: snapshot now, publish to the store on the next turn.
        coordinator.commit(deferred: true)
        coordinator.stopObserving()
        if coordinator.controller.textView === coordinator.textView {
            coordinator.controller.textView = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteID: UUID
        var controller: EditorController
        weak var textView: NoteItTextView?
        private let undo = UndoManager()
        private var isLoading = false
        private var remoteUpdates: AnyCancellable?
        /// Edits not yet written to the store.
        private(set) var hasPendingChanges = false

        static let commitDelay: TimeInterval = 0.3
        /// Number of `NoteStore.updateBody` calls made by editors (self-test instrumentation).
        static var storeCommitCount = 0

        init(noteID: UUID, controller: EditorController) {
            self.noteID = noteID
            self.controller = controller
        }

        func load() {
            guard let textView else { return }
            cancelScheduledCommit()
            hasPendingChanges = false
            isLoading = true
            defer { isLoading = false }
            let body = NoteStore.shared.body(for: noteID)
            textView.storage.setAttributedString(body)
            NoteItTextView.refreshTableColors(in: textView.storage)
            NoteItTextView.normalize(textView.storage, around: NSRange(location: 0, length: textView.storage.length))
            undo.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if body.length == 0 {
                textView.typingAttributes = EditorStyle.attributes(for: .title)
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    window.makeFirstResponder(textView)
                }
            } else {
                var attrs = body.attributes(at: 0, effectiveRange: nil)
                attrs[.link] = nil
                attrs[.attachment] = nil
                textView.typingAttributes = attrs
            }
            textView.needsDisplay = true
            controller.refresh()
        }

        /// Sync replaced this note in the store. Without local edits, show the new text (keeping selection and
        /// scroll). With uncommitted edits, keep them and commit: they get a new revision, so nothing is lost.
        private func remoteUpdateArrived() {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            if hasPendingChanges {
                commit()
                return
            }
            let body = NoteStore.shared.body(for: noteID)
            if body.isEqual(to: textView.attributedString()) { return }
            let selection = textView.selectedRange()
            let origin = scrollView.contentView.bounds.origin
            isLoading = true
            defer { isLoading = false }
            textView.storage.setAttributedString(body)
            NoteItTextView.refreshTableColors(in: textView.storage)
            NoteItTextView.normalize(textView.storage, around: NSRange(location: 0, length: textView.storage.length))
            undo.removeAllActions()
            let length = textView.storage.length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.needsDisplay = true
            controller.refresh()
        }

        /// Writes pending edits to the store. With `deferred`, the text is snapshotted immediately and staged in
        /// the store, which applies it on the next main-queue turn (for callers inside SwiftUI view updates)
        /// or earlier if sync needs to see it.
        func commit(deferred: Bool = false) {
            cancelScheduledCommit()
            guard hasPendingChanges, let textView, !isLoading else { return }
            hasPendingChanges = false
            Self.storeCommitCount += 1
            let id = noteID
            let snapshot = NSAttributedString(attributedString: textView.attributedString())
            if deferred {
                NoteStore.shared.stageEditorCommit(id, snapshot)
            } else {
                NoteStore.shared.updateBody(id, snapshot)
            }
        }

        private func scheduleCommit() {
            hasPendingChanges = true
            cancelScheduledCommit()
            perform(#selector(scheduledCommitFired), with: nil, afterDelay: Self.commitDelay, inModes: [.common])
        }

        private func cancelScheduledCommit() {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(scheduledCommitFired), object: nil)
        }

        @objc private func scheduledCommitFired() {
            commit()
        }

        // MARK: Forced commits

        func observeLifecycle() {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(forceCommit), name: NSApplication.willResignActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(forceCommit), name: NSWindow.didResignKeyNotification, object: nil)
            nc.addObserver(self, selector: #selector(forceCommit), name: NSWindow.willCloseNotification, object: nil)
            nc.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
            nc.addObserver(self, selector: #selector(syncWillApplyRemote), name: .noteItSyncWillApplyRemote, object: nil)
            nc.addObserver(self, selector: #selector(willExportNote), name: .noteItWillExportNote, object: nil)
            // Synchronous (no main-queue hop), so no keystroke can land between the store update and the reload.
            remoteUpdates = NoteStore.shared.$externallyUpdatedNoteID
                .dropFirst()
                .sink { [weak self] id in
                    MainActor.assumeIsolated {
                        guard let self, id == self.noteID else { return }
                        self.remoteUpdateArrived()
                    }
                }
        }

        /// Sync is about to replace or delete a note: hand it our pending edits first so it can see them.
        @objc private func syncWillApplyRemote(_ notification: Notification) {
            guard let id = notification.object as? UUID, id == noteID else { return }
            commit()
        }

        /// Export, print, Share and Copy as Markdown read the note from the store, so it must have our edits.
        @objc private func willExportNote(_ notification: Notification) {
            guard let id = notification.object as? UUID, id == noteID else { return }
            commit()
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            remoteUpdates = nil
            cancelScheduledCommit()
        }

        @objc private func forceCommit(_ notification: Notification) {
            if let window = notification.object as? NSWindow, window !== textView?.window { return }
            commit()
        }

        /// The app delegate's `applicationWillTerminate` is itself a willTerminate observer registered
        /// at launch, so it flushes *before* this runs; flush again after committing.
        @objc private func willTerminate(_ notification: Notification) {
            let hadChanges = hasPendingChanges
            commit()
            if hadChanges { NoteStore.shared.flush() }
        }

        // MARK: NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            if !isLoading { scheduleCommit() }
            controller.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.refresh()
        }

        func textViewDidChangeTypingAttributes(_ notification: Notification) {
            controller.refresh()
        }

        /// No spelling/grammar markers on #hashtags or code.
        func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range: NSRange) -> Int {
            guard let storage = textView.textStorage, range.location < storage.length else { return value }
            let ns = storage.string as NSString
            var start = range.location
            let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            while start > 0, let scalar = Unicode.Scalar(ns.character(at: start - 1)), wordChars.contains(scalar) {
                start -= 1
            }
            if start > 0, ns.character(at: start - 1) == 0x23 /* # */ { return 0 }
            var isCode = false
            let end = min(NSMaxRange(range), storage.length)
            storage.enumerateAttribute(.font, in: NSRange(location: range.location, length: max(end - range.location, 1))) { font, _, stop in
                if let font = font as? NSFont, EditorStyle.isMonospaced(font) { isCode = true; stop.pointee = true }
            }
            return isCode ? 0 : value
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}
