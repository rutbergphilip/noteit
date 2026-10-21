import AppKit
import Foundation

extension Notification.Name {
    /// The one extra NoteStore hook (program §7). Posted for local actions only, never for a change that arrives
    /// through sync. object: the NoteStore; userInfo["noteID"]: UUID; userInfo["kind"]: LocalNoteChangeKind.
    /// created: a local path adds a note (createNote and the paths built on it; sync's importConflictCopy calls
    /// createNote with postsLocalChange: false, so a conflict copy posts nothing). edited: updateBody stores a
    /// changed body (editor save, editBody, Restore Version). deleted: a local action moves a note to Recently
    /// Deleted. Plugins build noteCreated, noteEdited and noteDeleted on it. Owned by the plugins plan; built in
    /// foundations Task 4.5.
    static let localNoteChange = Notification.Name("NoteItLocalNoteChange")
}

enum LocalNoteChangeKind: String, Sendable {
    case created, edited, deleted
}

/// Why `editBody` changed nothing. versionNotSaved: with `.recordCurrent`, the current body couldn't be kept in
/// Version History. Owned by the organise plan; built in foundations Task 4.5.
enum BodyEditError: Error, Equatable, LocalizedError {
    case noteMissing, inTrash, locked, writeBlocked, taskChanged, versionNotSaved

    var errorDescription: String? {
        switch self {
        case .noteMissing: "The note no longer exists."
        case .inTrash: "The note is in Recently Deleted."
        case .locked: "The note is locked."
        case .writeBlocked: "The note can't be changed because its files couldn't be read."
        case .taskChanged: "The task changed before it could be updated."
        case .versionNotSaved: "The current version couldn't be saved, so the note wasn't changed."
        }
    }
}

/// recordCurrent: editBody records the note's current body in Version History exactly once before a change; if that
/// fails it throws versionNotSaved and changes nothing. none: no version. Callers never record one themselves.
enum EditBodyVersioning: Sendable {
    case recordCurrent, none
}

extension NoteStore {
    func postLocalNoteChange(_ id: UUID, _ kind: LocalNoteChangeKind) {
        NotificationCenter.default.post(name: .localNoteChange, object: self,
                                        userInfo: ["noteID": id, "kind": kind])
    }

    /// The one way code outside the editor changes a body, Restore Version included (program §6). Owned by the
    /// organise plan; built in foundations Task 4.5.
    ///
    /// Open note: every open editor first commits its pending edits in registration order, the active one last (its
    /// text wins), and that editor reloads the saved body if its text is older (another editor saved since); then
    /// with `.recordCurrent` the current body is recorded once, the most recent editor's text
    /// storage is edited as one undoable change named `actionName` and saved, and every other open editor reloads the
    /// saved body as it does an external change. Closed note: pending edits are handed over, the current body is
    /// recorded once with `.recordCurrent`, and `edit` is applied to a copy, stored, flushed and announced through
    /// `externallyUpdatedNoteID`. A call that changes nothing (same text, and `extras` nil or equal to
    /// `bodyExtras[id]`) records nothing.
    ///
    /// `extras` is passed only by NoteStore's own code (Restore Version): nil keeps `bodyExtras[id]`, a value
    /// replaces it in the same body write. On the open path, Undo of a call that changed the extras restores the
    /// earlier text and extras in one body write, and Redo reapplies both.
    func editBody(_ id: UUID, actionName: String, versioning: EditBodyVersioning = .recordCurrent,
                  extras: ContainerExtras? = nil,
                  _ edit: (NSMutableAttributedString) throws -> Void) throws {
        guard let meta = note(with: id) else { throw BodyEditError.noteMissing }
        guard meta.deletedAt == nil else { throw BodyEditError.inTrash }
        guard !meta.isLocked else { throw BodyEditError.locked }
        // Reading the body is what finds an unreadable body or sidecar, which blocks writes.
        _ = body(for: id)
        guard !isBodyWriteBlocked(id) else { throw BodyEditError.writeBlocked }

        if let view = OpenEditorRegistry.shared.textView(for: id), view.isEditable,
           let coordinator = view.delegate as? RichTextEditor.Coordinator, coordinator.store === self {
            try editOpenBody(id, in: view, coordinator: coordinator, actionName: actionName, versioning: versioning,
                             extras: extras, edit)
        } else {
            try editClosedBody(id, versioning: versioning, extras: extras, edit)
        }
    }

    private func editClosedBody(_ id: UUID, versioning: EditBodyVersioning, extras: ContainerExtras?,
                                _ edit: (NSMutableAttributedString) throws -> Void) throws {
        handOverPendingEdits(id)
        let current = body(for: id)
        let edited = NSMutableAttributedString(attributedString: current)
        try edit(edited)
        let newExtras = changedExtras(extras, of: id)
        guard !edited.isEqual(to: current) || newExtras != nil else { return }
        try recordCurrentVersion(current, of: id, versioning)
        updateBody(id, edited, extras: newExtras)
        flush()
        externallyUpdatedNoteID = id
    }

    private func editOpenBody(_ id: UUID, in view: NoteItTextView, coordinator: RichTextEditor.Coordinator,
                              actionName: String, versioning: EditBodyVersioning, extras: ContainerExtras?,
                              _ edit: (NSMutableAttributedString) throws -> Void) throws {
        for other in OpenEditorRegistry.shared.textViewsInRegistrationOrder(for: id) where other !== view {
            (other.delegate as? RichTextEditor.Coordinator)?.commit()
        }
        coordinator.commit()
        handOverPendingEdits(id)
        // Another editor's plain save doesn't reload this one, so start from the saved body, not older text.
        coordinator.reloadIfStale()

        let current = view.attributedString()
        let edited = NSMutableAttributedString(attributedString: current)
        try edit(edited)
        let newExtras = changedExtras(extras, of: id)
        let textChanged = !edited.isEqual(to: current)
        guard textChanged || newExtras != nil else { return }
        try recordCurrentVersion(current, of: id, versioning)

        let undo = view.undoManager
        view.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        if let undo {
            registerExtrasUndo(id, restoring: newExtras == nil ? nil : bodyExtras[id] ?? .empty, undo: undo, view: view)
        }
        if textChanged {
            let selection = view.selectedRange()
            view.replace(NSRange(location: 0, length: view.storage.length), with: edited)
            NoteItTextView.refreshTableColors(in: view.storage)
            view.setSelectedRange(view.clamp(selection))
        }
        undo?.setActionName(actionName)
        undo?.endUndoGrouping()
        undo?.setActionName(actionName)

        saveOpenEditor(id, view: view, coordinator: coordinator, extras: newExtras)
    }

    /// `extras` when it differs from the note's current extras, else nil.
    private func changedExtras(_ extras: ContainerExtras?, of id: UUID) -> ContainerExtras? {
        guard let extras, extras != (bodyExtras[id] ?? .empty) else { return nil }
        return extras
    }

    private func recordCurrentVersion(_ current: NSAttributedString, of id: UUID, _ versioning: EditBodyVersioning) throws {
        guard versioning == .recordCurrent else { return }
        let version: NoteVersion?
        if let recordVersionOverride {
            version = recordVersionOverride(current, id)
        } else {
            version = history.record(current, extras: bodyExtras[id] ?? .empty, of: id)
        }
        guard version != nil else { throw BodyEditError.versionNotSaved }
    }

    /// Saves the editor's text, with `extras` when given, in one body write now, and has every other editor for the
    /// note reload it (the originating one already shows it).
    private func saveOpenEditor(_ id: UUID, view: NoteItTextView?, coordinator: RichTextEditor.Coordinator?,
                                extras: ContainerExtras?) {
        if let coordinator, coordinator.hasPendingChanges {
            if let extras { setBodyExtras(extras, for: id) }
            savingProgrammaticEdit = true
            coordinator.commit()
            savingProgrammaticEdit = false
        }
        let text = view?.attributedString() ?? body(for: id)
        updateBody(id, text, extras: extras)
        flush()
        externallyUpdatedNoteID = id
    }

    /// The Undo action of every editBody call on an open note. Registered first in the call's undo group, so it runs
    /// after the text has been reverted; it registers its own inverse for Redo. The save waits until the whole undo
    /// or redo step is done, so the restored text and extras go out in one body write, and it is saved as the
    /// programmatic edit it reverts, not as typing. nil `extras`: the call kept them, and so do undo and redo.
    private func registerExtrasUndo(_ id: UUID, restoring extras: ContainerExtras?, undo: UndoManager,
                                    view: NoteItTextView) {
        undo.registerUndo(withTarget: self) { [weak view] store in
            MainActor.assumeIsolated {
                guard let view else { return }
                store.registerExtrasUndo(id, restoring: extras == nil ? nil : store.bodyExtras[id] ?? .empty, undo: undo, view: view)
                store.saveAfterUndoStep(id, extras: extras, undo: undo, view: view)
            }
        }
    }

    private func saveAfterUndoStep(_ id: UUID, extras: ContainerExtras?, undo: UndoManager, view: NoteItTextView) {
        let once = UndoStepObservation()
        let finish: @Sendable (Notification) -> Void = { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                once.cancel()
                guard let self, let view else { return }
                self.saveOpenEditor(id, view: view, coordinator: view.delegate as? RichTextEditor.Coordinator,
                                    extras: extras)
            }
        }
        let center = NotificationCenter.default
        once.tokens = [
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: undo, queue: nil, using: finish),
            center.addObserver(forName: .NSUndoManagerDidRedoChange, object: undo, queue: nil, using: finish),
        ]
    }
}

/// The two one-shot observers of an undo step; whichever fires first removes both.
private final class UndoStepObservation: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    func cancel() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}
