import NoteItCore
import SwiftUI

/// Window-level state for renaming, merging and deleting tags: the sheets, progress and the undo toast.
@MainActor
final class TagEditCoordinator: ObservableObject {
    static let shared = TagEditCoordinator()

    struct RenameRequest: Identifiable {
        let tag: String
        var id: String { tag }
    }

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let result: TagEditResult
    }

    @Published var renaming: RenameRequest?
    @Published var pendingDelete: String?
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var toast: Toast?
    @Published var showsSkipped = false
    private var cancelRequested = false
    private var dismissWork: DispatchWorkItem?

    static let toastDuration: TimeInterval = 10
    /// Above this many notes a progress sheet with Cancel appears.
    static let progressThreshold = 200

    func rename(_ tag: String, to target: String, store: NoteStore) {
        let merging = store.tagTree.flattenedPaths.contains(TokenGrammar.normalizedTag(target))
        run(store: store, total: store.notesTagged(tag).count) { progress in
            await store.renameTag(tag, to: target, progress: progress)
        } message: { count in
            merging ? "Merged #\(tag) into #\(target) in \(Self.notes(count))" : "Renamed #\(tag) in \(Self.notes(count))"
        }
    }

    func delete(_ tag: String, store: NoteStore) {
        run(store: store, total: store.notesTagged(tag).count) { progress in
            await store.deleteTag(tag, progress: progress)
        } message: { count in
            "Removed #\(tag) from \(Self.notes(count))"
        }
    }

    func cancel() { cancelRequested = true }

    func undo(store: NoteStore) {
        guard let toast else { return }
        dismissToast()
        let leftAlone = store.undoTagEdit(toast.result)
        if leftAlone > 0 {
            show(Toast(message: "\(Self.notes(leftAlone)) changed since weren’t put back", result: TagEditResult()))
        }
    }

    func dismissToast() {
        dismissWork?.cancel()
        dismissWork = nil
        withAnimation(.snappy(duration: 0.2)) { toast = nil }
    }

    static func notes(_ count: Int) -> String { count == 1 ? "1 note" : "\(count) notes" }

    private func run(store: NoteStore, total: Int, _ work: @escaping (((Int, Int) -> Bool)?) async -> TagEditResult,
                     message: @escaping (Int) -> String) {
        cancelRequested = false
        if total > Self.progressThreshold { progress = (0, total) }
        Task { @MainActor in
            let result = await work { [weak self] done, total in
                guard let self else { return true }
                if self.progress != nil { self.progress = (done, total) }
                return !self.cancelRequested
            }
            progress = nil
            var text = message(result.changed.count)
            if result.untouchedInTrash > 0 { text += ". Notes in Recently Deleted weren’t changed." }
            show(Toast(message: text, result: result))
        }
    }

    private func show(_ toast: Toast) {
        dismissWork?.cancel()
        withAnimation(.snappy(duration: 0.2)) { self.toast = toast }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismissToast() }
        }
        dismissWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration, execute: item)
    }
}

extension Array where Element == TagNode {
    var flattenedPaths: Set<String> {
        var result = Set<String>()
        func visit(_ node: TagNode) {
            result.insert(node.path)
            node.children.forEach(visit)
        }
        forEach(visit)
        return result
    }
}

struct RenameTagSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    let tag: String
    @State private var name: String

    init(tag: String) {
        self.tag = tag
        _name = State(initialValue: tag)
    }

    private var target: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    }

    private var problem: String? {
        guard TokenGrammar.normalizedTag(target) != TokenGrammar.normalizedTag(tag) else { return nil }
        return TagRewriter.renameProblem(from: tag, to: target, tags: store.tagsInUse)
    }

    private var mergeCount: Int? {
        let normalized = TokenGrammar.normalizedTag(target)
        guard normalized != TokenGrammar.normalizedTag(tag), store.tagTree.flattenedPaths.contains(normalized) else { return nil }
        return store.notesTagged(tag).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s12) {
            Text("Rename #\(tag)").font(.headline)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            } else if let mergeCount {
                Text("“#\(target)” already exists. Merge \(TagEditCoordinator.notes(mergeCount)) into it?")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Nested tags change too: #\(tag)/… becomes #\(target.isEmpty ? "…" : target)/….")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mergeCount == nil ? "Rename" : "Merge", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || TokenGrammar.normalizedTag(target) == TokenGrammar.normalizedTag(tag) && target == tag)
            }
        }
        .padding(Tokens.Space.s16)
        .frame(width: 380)
    }

    private func commit() {
        guard problem == nil, target != tag else { return }
        dismiss()
        TagEditCoordinator.shared.rename(tag, to: target, store: store)
    }
}

extension View {
    /// The tag sheets, the progress sheet and the undo toast for the main window.
    func tagEditSupport() -> some View {
        modifier(TagEditSupport())
    }
}

private struct TagEditSupport: ViewModifier {
    @EnvironmentObject private var store: NoteStore
    @ObservedObject private var coordinator = TagEditCoordinator.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $coordinator.renaming) { request in
                RenameTagSheet(tag: request.tag).environmentObject(store)
            }
            .sheet(isPresented: Binding(get: { coordinator.progress != nil }, set: { _ in })) {
                VStack(alignment: .leading, spacing: Tokens.Space.s12) {
                    Text("Updating notes…").font(.headline)
                    ProgressView(value: Double(coordinator.progress?.done ?? 0), total: Double(max(coordinator.progress?.total ?? 1, 1)))
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { coordinator.cancel() }
                    }
                }
                .padding(Tokens.Space.s16)
                .frame(width: 340)
            }
            .confirmationDialog(
                "Remove “#\(coordinator.pendingDelete ?? "")” from \(TagEditCoordinator.notes(store.notesTagged(coordinator.pendingDelete ?? "").count))?",
                isPresented: Binding(get: { coordinator.pendingDelete != nil }, set: { if !$0 { coordinator.pendingDelete = nil } }),
                presenting: coordinator.pendingDelete
            ) { tag in
                Button("Delete Tag", role: .destructive) { coordinator.delete(tag, store: store) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The words stay, only the tag goes.")
            }
            .overlay(alignment: .bottom) {
                if let toast = coordinator.toast {
                    UndoToast(message: toast.message, symbol: "number",
                              secondary: toast.result.skipped.isEmpty ? nil : ("Show Skipped", { coordinator.showsSkipped = true })) {
                        coordinator.undo(store: store)
                    }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                }
            }
            .alert("Notes Not Changed", isPresented: $coordinator.showsSkipped) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(skippedText)
            }
    }

    private var skippedText: String {
        let skipped = coordinator.toast?.result.skipped ?? [:]
        return skipped.prefix(10).map { id, error in
            "\(store.note(with: id)?.displayTitle ?? "Note"): \(error.localizedDescription)"
        }.joined(separator: "\n")
    }
}
