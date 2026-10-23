import AppKit
import Foundation
import NoteItCore

/// One round of a flush's writes to a Markdown library's content folder: bodies, then folders and front matter,
/// then idle renames, then deleted notes' files. Built on the main thread from a snapshot, run on the store's IO
/// queue, and its result applied back on the main thread.
struct MarkdownWritePass: @unchecked Sendable {
    struct Body {
        var meta: NoteMeta
        var text: NSAttributedString
        var extras: ContainerExtras
        var notebook: Notebook?
    }

    struct Result: @unchecked Sendable {
        var failedBodies: [UUID: Error] = [:]
        var failedUpdates: [UUID: Error] = [:]
        var trashed: Set<UUID> = []
    }

    var bodies: [Body] = []
    var layout = false
    var notebookIDs: Set<UUID> = []
    var metadata: [(meta: NoteMeta, notebook: Notebook?)] = []
    var renames: [NoteMeta] = []
    var trash: [UUID] = []

    var isEmpty: Bool { bodies.isEmpty && !layout && trash.isEmpty }

    func run(on storage: MarkdownBodyStorage) -> Result {
        var result = Result()
        for body in bodies {
            do {
                let temp = try storage.prepareTemp(body.text, extras: body.extras, meta: body.meta)
                try storage.installTemp(temp, for: body.meta, notebook: body.notebook)
            } catch {
                result.failedBodies[body.meta.id] = error
            }
        }
        if layout, storage.contentRootExists {
            do { try storage.reconcileNotebooks() } catch { NSLog("NoteIt: couldn't update notebook folders: \(error)") }
            for (meta, notebook) in metadata {
                do { try storage.writeMetadataOnly(for: meta, notebook: notebook) } catch { result.failedUpdates[meta.id] = error }
            }
            // Deepest first, so a parent's folder is empty by the time it goes; a folder that couldn't go keeps its
            // record and is tried again on the next flush.
            let gone = storage.index.allNotebookFolders.filter { !notebookIDs.contains($0.key) }
                .sorted { MarkdownBodyStorage.depth(of: $0.value) > MarkdownBodyStorage.depth(of: $1.value) }
            for (id, _) in gone {
                do { try storage.removeNotebook(id: id) } catch { NSLog("NoteIt: couldn't remove a notebook folder: \(error)") }
            }
            for meta in renames {
                do { try storage.renameForTitle(meta) } catch { result.failedUpdates[meta.id] = error }
            }
            try? storage.index.save()
        }
        for id in trash {
            do {
                try storage.moveToTrash(id)
                result.trashed.insert(id)
            } catch {
                NSLog("NoteIt: failed to move deleted note \(id) to trash: \(error)")
            }
        }
        return result
    }
}

/// Work queued on a Markdown store's IO queue. Its result is applied on the main thread exactly once: by the
/// main-queue hop that follows it, or earlier by a caller that waited for it.
final class MarkdownIOJob: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var apply: (() -> Void)?
    private(set) var isApplied = false
    var isWritePass = false

    func finished(_ apply: @escaping () -> Void) {
        lock.withLock { self.apply = apply }
        done.signal()
        DispatchQueue.main.async { MainActor.assumeIsolated { self.applyResult() } }
    }

    /// Waits at most `timeout` for the work and applies its result; false when it hasn't finished.
    @MainActor
    func wait(upTo timeout: TimeInterval) -> Bool {
        if isApplied { return true }
        guard done.wait(timeout: .now() + max(timeout, 0)) == .success else { return false }
        done.signal()
        applyResult()
        return true
    }

    @MainActor
    private func applyResult() {
        let apply = lock.withLock { () -> (() -> Void)? in
            defer { self.apply = nil }
            return self.apply
        }
        guard let apply else { return }
        isApplied = true
        apply()
    }
}
