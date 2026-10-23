import AppKit
import NoteItCore
import SwiftUI

/// Keeps a note's word and character counts current: from the open editor while there is one (recounted 0.3 s
/// after typing stops), otherwise from the saved body.
@MainActor
final class NoteInfoModel: ObservableObject {
    @Published private(set) var statistics = NoteStatistics(words: 0, characters: 0)
    private var noteID: UUID?
    private var observer: NSObjectProtocol?
    private var refreshWork: DispatchWorkItem?
    private var attachTask: Task<Void, Never>?

    func attach(to noteID: UUID, store: NoteStore) {
        self.noteID = noteID
        detach()
        guard store.note(with: noteID)?.isLocked == false else {
            statistics = NoteStatistics(words: 0, characters: 0)
            return
        }
        guard let view = OpenEditorRegistry.shared.textView(for: noteID) else {
            statistics = NoteStatistics(text: store.body(for: noteID).string)
            attachTask = Task { [weak self, weak store] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let store, !Task.isCancelled, self.noteID == noteID,
                      OpenEditorRegistry.shared.textView(for: noteID) != nil else { return }
                self.attach(to: noteID, store: store)
            }
            return
        }
        observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh(view) }
        }
        refresh(view)
    }

    func detach() {
        attachTask?.cancel()
        refreshWork?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func scheduleRefresh(_ view: NSTextView?) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            MainActor.assumeIsolated { self?.refresh(view) }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refresh(_ view: NSTextView?) {
        guard let view else { return }
        let new = NoteStatistics(text: view.string)
        if new != statistics { statistics = new }
    }
}

/// The inspector's Info tab: counts, dates, notebook and tags for the selected note.
struct NoteInfoTab: View {
    @EnvironmentObject private var store: NoteStore
    let note: NoteMeta
    @StateObject private var model = NoteInfoModel()

    var body: some View {
        Group {
            if note.isLocked {
                Text("This note is locked")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Text") {
                        row("Words", model.statistics.words.formatted())
                        row("Characters", model.statistics.characters.formatted())
                        row("Reading time", model.statistics.readingTimeText)
                    }
                    Section("Note") {
                        row("Created", note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        row("Last edited", note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        row("Notebook", store.notebook(with: note.notebookID)?.name ?? "None")
                        if note.tags.isEmpty {
                            row("Tags", "None")
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Tags").foregroundStyle(.secondary).font(.system(size: 12))
                                Text(note.tags.map { "#\($0)" }.joined(separator: "  "))
                                    .font(Tokens.Font.cardMeta)
                                    .foregroundStyle(Tokens.Color.accent)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onAppear { model.attach(to: note.id, store: store) }
        .onChange(of: note.id) { _, id in model.attach(to: id, store: store) }
        .onDisappear { model.detach() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}
