import AppKit
import Combine
import SwiftUI

/// The inspector's tabs. Other panels append tabs here.
enum InspectorTab: String, CaseIterable, Identifiable {
    case links
    case outline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .links: "Links"
        case .outline: "Outline"
        }
    }
}

/// The main window's inspector: Links and Outline for the selected note (spec §7, §9).
struct LinksPanelView: View {
    @EnvironmentObject private var store: NoteStore
    @AppStorage(PrefKey.inspectorTab) private var tabRaw = PrefDefault.inspectorTab
    let noteID: UUID?

    private var tab: Binding<InspectorTab> {
        Binding(get: { InspectorTab(rawValue: tabRaw) ?? .links }, set: { tabRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: tab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let noteID, let note = store.note(with: noteID) {
                switch tab.wrappedValue {
                case .links: LinksTab(note: note, index: store.linkIndex)
                case .outline: OutlineTab(note: note)
                }
            } else {
                placeholder("No Note Selected")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private func placeholder(_ text: String, tip: String? = nil) -> some View {
    VStack(spacing: 4) {
        Text(text).foregroundStyle(.secondary)
        if let tip { Text(tip).font(.system(size: 11)).foregroundStyle(.tertiary) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
}

// MARK: - Links

private struct LinksTab: View {
    @EnvironmentObject private var store: NoteStore
    let note: NoteMeta
    @ObservedObject var index: LinkIndex
    @StateObject private var mentions = MentionsModel()
    @AppStorage(PrefKey.unlinkedMentionsExpanded) private var mentionsExpanded = false

    var body: some View {
        let backlinks = store.backlinks(to: note.id)
        let outgoing = store.outgoingLinks(from: note.id)
        List {
            if let progress = index.rebuildProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding links… \(progress.done.formatted()) of \(progress.total.formatted())")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Section("Backlinks (\(backlinks.count))") {
                if backlinks.isEmpty {
                    Text("No notes link here yet").foregroundStyle(.secondary).font(.system(size: 12))
                }
                ForEach(backlinks) { backlink in
                    BacklinkRow(backlink: backlink)
                }
            }
            Section {
                DisclosureGroup(isExpanded: $mentionsExpanded) {
                    MentionsList(model: mentions, note: note)
                } label: {
                    HStack {
                        Text(mentions.results.map { "Unlinked Mentions (\($0.count))" } ?? "Unlinked Mentions")
                        Spacer()
                        if mentionsExpanded, let results = mentions.results, !results.isEmpty {
                            Button("Link All") { mentions.confirmingLinkAll = true }
                                .controlSize(.small)
                                .disabled(mentions.isLinking)
                        }
                    }
                }
            }
            Section("In This Note (\(outgoing.count))") {
                if outgoing.isEmpty {
                    Text(note.isLocked ? "This note is locked" : "No links in this note")
                        .foregroundStyle(.secondary).font(.system(size: 12))
                }
                ForEach(Array(outgoing.enumerated()), id: \.offset) { _, item in
                    OutgoingRow(source: note.id, item: item)
                }
            }
        }
        .listStyle(.sidebar)
        .task(id: MentionsModel.Key(note: note.id, title: note.title, version: index.version, expanded: mentionsExpanded)) {
            guard mentionsExpanded else { mentions.clear(); return }
            await mentions.load(note.id, store: store)
        }
        .alert(linkAllTitle, isPresented: $mentions.confirmingLinkAll) {
            Button("Link All") { Task { await mentions.linkAll(note.id, store: store) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each changed note keeps its current version in Version History.")
        }
    }

    private var linkAllTitle: String {
        let notes = mentions.results?.count ?? 0
        let count = mentions.results?.reduce(0) { $0 + $1.count } ?? 0
        return "Link \(count) \(count == 1 ? "mention" : "mentions") in \(notes) \(notes == 1 ? "note" : "notes")?"
    }
}

@MainActor
final class MentionsModel: ObservableObject {
    struct Key: Equatable {
        var note: UUID
        var title: String
        var version: Int
        var expanded: Bool
    }

    static let shownLimit = 100

    @Published private(set) var results: [MentionResult]?
    @Published private(set) var searched = true
    @Published var showAll = false
    @Published var confirmingLinkAll = false
    @Published private(set) var isLinking = false
    @Published private(set) var outcome: (message: String, result: LinkRewriteResult?)?
    private var noteID: UUID?

    func clear() {
        results = nil
    }

    func load(_ id: UUID, store: NoteStore) async {
        if noteID != id {
            noteID = id
            showAll = false
            outcome = nil
            results = nil
        }
        searched = store.mentionsAreSearched(for: id)
        guard searched else { results = []; return }
        let found = await store.unlinkedMentions(of: id)
        guard !Task.isCancelled, noteID == id else { return }
        results = found
    }

    func link(_ source: UUID, of id: UUID, store: NoteStore) async {
        _ = await store.linkMentions(of: id, in: [source], versioning: EditBodyVersioning.none)
    }

    func linkAll(_ id: UUID, store: NoteStore) async {
        guard let results, !results.isEmpty else { return }
        isLinking = true
        let (linked, result) = await store.linkMentions(of: id, in: results.map(\.source), versioning: .recordCurrent)
        isLinking = false
        let notes = result.notes.count
        var message = "Linked \(linked) \(linked == 1 ? "mention" : "mentions") in \(notes) \(notes == 1 ? "note" : "notes")."
        if result.skipped > 0 {
            message += result.skipped == 1 ? " 1 note couldn't be changed." : " \(result.skipped) notes couldn't be changed."
        }
        outcome = (message, result.notes.isEmpty ? nil : result)
    }

    func undo(store: NoteStore) {
        guard let result = outcome?.result else { return }
        let leftAlone = store.undoLinkRewrite(result)
        outcome = (leftAlone == 0 ? "Mentions unlinked again."
                   : "\(leftAlone) \(leftAlone == 1 ? "note was" : "notes were") edited since and left as \(leftAlone == 1 ? "it is" : "they are").", nil)
    }
}

private struct MentionsList: View {
    @EnvironmentObject private var store: NoteStore
    @ObservedObject var model: MentionsModel
    let note: NoteMeta

    var body: some View {
        if let outcome = model.outcome {
            HStack {
                Text(outcome.message).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if outcome.result != nil {
                    Button("Undo") { model.undo(store: store) }.controlSize(.small)
                }
            }
        }
        if !model.searched {
            Text("Titles this short aren't searched.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let results = model.results {
            if results.isEmpty {
                Text("No unlinked mentions").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            let shown = model.showAll ? results : Array(results.prefix(MentionsModel.shownLimit))
            ForEach(shown) { mention in
                MentionRow(mention: mention, title: note.title) {
                    Task { await model.link(mention.source, of: note.id, store: store) }
                }
            }
            if !model.showAll, results.count > MentionsModel.shownLimit {
                Button("Show All (\(results.count))") { model.showAll = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MentionRow: View {
    @EnvironmentObject private var store: NoteStore
    let mention: MentionResult
    let title: String
    let link: () -> Void

    var body: some View {
        let meta = store.note(with: mention.source)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button { store.navigate(to: mention.source, heading: nil) } label: {
                    Text(meta?.displayTitle ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Button("Link", action: link)
                    .controlSize(.small)
                    .accessibilityLabel("Link the mentions in “\(meta?.displayTitle ?? "")”")
            }
            ForEach(Array(mention.contexts.enumerated()), id: \.offset) { _, context in
                contextText(context, bold: title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private func contextText(_ context: String, bold: String) -> Text {
    guard !bold.isEmpty, let range = context.range(of: bold, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
    else { return Text(context) }
    return Text(context[..<range.lowerBound]) + Text(context[range]).bold() + Text(context[range.upperBound...])
}

private struct BacklinkRow: View {
    @EnvironmentObject private var store: NoteStore
    let backlink: Backlink

    var body: some View {
        let meta = store.note(with: backlink.source)
        let notebook = store.notebook(with: meta?.notebookID)?.name
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(meta?.displayTitle ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let notebook {
                    Text(notebook).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ForEach(Array(backlink.occurrences.enumerated()), id: \.offset) { _, occurrence in
                Button {
                    RichTextEditor.pendingCaret[backlink.source] = occurrence.location
                    store.navigate(to: backlink.source, heading: nil)
                } label: {
                    contextText(occurrence.context, bold: occurrence.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(meta?.displayTitle ?? ""): \(occurrence.context)")
                .accessibilityHint("Opens the note at the link")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct OutgoingRow: View {
    @EnvironmentObject private var store: NoteStore
    let source: UUID
    let item: OutgoingLink

    var body: some View {
        let link = item.link
        let resolution = link.map { store.resolve($0, from: source) }
        HStack(spacing: 6) {
            Image(systemName: symbol(resolution)).foregroundStyle(.secondary).font(.system(size: 11))
            Button {
                if let link { store.followLink(link, from: source) }
            } label: {
                Text(item.text.isEmpty ? item.url.absoluteString : item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(isLive(resolution) ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if case .unresolved(let title) = resolution {
                Button("Create") {
                    let meta = store.createNoteForLink(title: title, from: source)
                    if let link { store.rewriteLinks(in: source, matching: link, to: meta.id) }
                }
                .controlSize(.small)
                .accessibilityLabel("Create note “\(title)”")
            }
        }
    }

    private func isLive(_ resolution: LinkResolution?) -> Bool {
        if case .note = resolution { return true }
        return false
    }

    private func symbol(_ resolution: LinkResolution?) -> String {
        switch resolution {
        case .note: "doc.text"
        case .unresolved: "doc.badge.plus"
        case .deleted: "trash"
        case .missing, nil: "questionmark.circle"
        }
    }
}

// MARK: - Outline

@MainActor
final class OutlineModel: ObservableObject {
    @Published private(set) var items: [OutlineItem] = []
    @Published private(set) var current: Int?
    private(set) weak var textView: NoteItTextView?
    private var noteID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var lastScrollUpdate = Date.distantPast
    private var attachTask: Task<Void, Never>?

    func attach(to noteID: UUID, store: NoteStore) {
        self.noteID = noteID
        detach()
        guard store.note(with: noteID)?.isLocked == false else {
            items = []
            current = nil
            return
        }
        guard let view = OpenEditorRegistry.shared.textView(for: noteID) else {
            items = OutlineExtractor.items(in: store.body(for: noteID))
            current = nil
            attachTask = Task { [weak self, weak store] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, let store, !Task.isCancelled, self.noteID == noteID,
                      OpenEditorRegistry.shared.textView(for: noteID) != nil else { return }
                self.attach(to: noteID, store: store)
            }
            return
        }
        textView = view
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSText.didChangeNotification, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        if let clip = view.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            })
        }
        refresh()
    }

    func detach() {
        attachTask?.cancel()
        refreshWork?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        textView = nil
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func scrolled() {
        let now = Date()
        guard now.timeIntervalSince(lastScrollUpdate) >= 0.1 else { return }
        lastScrollUpdate = now
        updateCurrent()
    }

    private func refresh() {
        guard let textView, let storage = textView.textStorage else { return }
        let new = OutlineExtractor.items(in: storage)
        if new != items { items = new }
        updateCurrent()
    }

    private func rect(for item: OutlineItem) -> NSRect? {
        textView?.lineRect(at: item.range.location)
    }

    private func updateCurrent() {
        guard let textView else { return }
        let top = textView.visibleRect.minY + 4
        var found: Int?
        for (index, item) in items.enumerated() {
            guard let rect = rect(for: item) else { break }
            if rect.minY <= top { found = index } else { break }
        }
        if found == nil, !items.isEmpty { found = 0 }
        if found != current { current = found }
    }

    /// Scrolls the heading to the top third and puts the caret at its start; with `section`, selects up to the
    /// next heading of the same or a higher level.
    func go(to index: Int, section: Bool) {
        guard let textView, items.indices.contains(index), let length = textView.textStorage?.length else { return }
        let item = items[index]
        var selection = NSRange(location: item.range.location, length: 0)
        if section {
            let end = items[(index + 1)...].first { $0.level <= item.level }?.range.location ?? length
            selection = NSRange(location: item.range.location, length: end - item.range.location)
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(selection)
        textView.scrollToTopThird(item.range.location)
        updateCurrent()
    }
}

private struct OutlineTab: View {
    @EnvironmentObject private var store: NoteStore
    let note: NoteMeta
    @StateObject private var model = OutlineModel()

    var body: some View {
        Group {
            if note.isLocked {
                placeholder("This note is locked")
            } else if model.items.isEmpty {
                placeholder("No headings yet", tip: "Use ⌥⌘2 for a heading.")
            } else {
                List {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        Button {
                            model.go(to: index, section: NSEvent.modifierFlags.contains(.command))
                        } label: {
                            Text(item.text)
                                .font(.system(size: item.level == 0 ? 13 : 12, weight: item.level == 0 ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.leading, CGFloat(item.level) * 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(model.current == index ? Color.accentColor.opacity(0.15) : Color.clear)
                        .accessibilityAddTraits(model.current == index ? .isSelected : [])
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onAppear { model.attach(to: note.id, store: store) }
        .onChange(of: note.id) { _, id in model.attach(to: id, store: store) }
        .onDisappear { model.detach() }
    }
}
