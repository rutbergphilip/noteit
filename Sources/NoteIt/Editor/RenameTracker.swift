import Combine
import Foundation
import SwiftUI

/// Watches the open note's title and offers to update the text of links to it after the user renames it in the
/// editor (spec §8). Titles changed any other way (sync, Restore Version, the Local API) only move the baseline.
@MainActor
final class RenameTracker: ObservableObject {
    struct Prompt: Equatable {
        var noteID: UUID
        var oldTitle: String
        var newTitle: String
        var noteCount: Int
    }

    struct Outcome {
        var message: String
        var result: LinkRewriteResult?
    }

    static var idleDelay: Duration = .seconds(2)

    @Published private(set) var prompt: Prompt?
    @Published private(set) var outcome: Outcome?
    @Published private(set) var isUpdating = false

    weak var store: NoteStore? {
        didSet {
            guard store !== oldValue else { return }
            commits = store?.editorTitleCommits.sink { [weak self] commit in
                self?.titleChanged(commit.title, of: commit.id)
            }
        }
    }
    private var commits: AnyCancellable?
    var defaults: UserDefaults = .standard
    private var noteID: UUID?
    private var baseline = ""
    private var latest = ""
    private var waitTask: Task<Void, Never>?
    private var outcomeTask: Task<Void, Never>?

    func open(_ noteID: UUID?, title: String) {
        guard noteID != self.noteID else { return }
        waitTask?.cancel()
        self.noteID = noteID
        baseline = title
        latest = title
        prompt = nil
        outcome = nil
    }

    /// The open note's stored title, from any source. A title the editor didn't commit becomes the new baseline.
    func titleObserved(_ title: String, of noteID: UUID) {
        guard noteID == self.noteID, title != latest else { return }
        waitTask?.cancel()
        prompt = nil
        baseline = title
        latest = title
    }

    func titleChanged(_ title: String, of noteID: UUID) {
        guard noteID == self.noteID, title != latest else { return }
        latest = title
        prompt = nil
        waitTask?.cancel()
        guard title != baseline else { return }
        waitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            await self?.titleSettled()
        }
    }

    private func titleSettled() async {
        guard let store, let noteID else { return }
        let old = baseline
        let new = latest
        let mode = defaults.string(forKey: PrefKey.linkRenameUpdates) ?? PrefDefault.linkRenameUpdates
        let candidates = mode == "never" ? [] : store.renameCandidates(for: noteID, oldTitle: old)
        guard !candidates.isEmpty, !new.trimmingCharacters(in: .whitespaces).isEmpty else {
            baseline = new
            return
        }
        let prompt = Prompt(noteID: noteID, oldTitle: old, newTitle: new, noteCount: candidates.count)
        if mode == "always" {
            await update(prompt, confirmation: true)
        } else {
            self.prompt = prompt
        }
    }

    func update() {
        guard let prompt else { return }
        Task { await update(prompt, confirmation: false) }
    }

    func notNow() {
        guard let prompt else { return }
        baseline = prompt.newTitle
        self.prompt = nil
    }

    private func update(_ prompt: Prompt, confirmation: Bool) async {
        guard let store else { return }
        self.prompt = nil
        isUpdating = true
        let result = await store.rewriteLinkText(targeting: prompt.noteID, from: prompt.oldTitle, to: prompt.newTitle)
        isUpdating = false
        if noteID == prompt.noteID { baseline = prompt.newTitle }
        show(Outcome(message: Self.message(for: result), result: result.notes.isEmpty ? nil : result),
             for: confirmation ? .seconds(3) : .seconds(10))
    }

    func undo() {
        guard let store, let result = outcome?.result else { return }
        let leftAlone = store.undoLinkRewrite(result)
        baseline = latest
        let message = leftAlone == 0 ? "Links restored."
            : leftAlone == 1 ? "1 note was edited since and was left as it is."
            : "\(leftAlone) notes were edited since and were left as they are."
        show(Outcome(message: message, result: nil), for: .seconds(4))
    }

    func dismissOutcome() {
        outcomeTask?.cancel()
        outcome = nil
    }

    private func show(_ outcome: Outcome, for duration: Duration) {
        self.outcome = outcome
        outcomeTask?.cancel()
        outcomeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.outcome = nil
        }
    }

    static func message(for result: LinkRewriteResult) -> String {
        var text = result.updated == 1 ? "Updated 1 link." : "Updated \(result.updated) links."
        if result.skipped == 1 {
            text += " 1 note couldn't be changed."
        } else if result.skipped > 1 {
            text += " \(result.skipped) notes couldn't be changed."
        }
        return text
    }
}
