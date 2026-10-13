import AppKit
import SwiftUI

/// Content of the menu bar (status item) panel.
struct MenuBarView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var highlighted: UUID?
    @State private var focusToken = 0
    @State private var draft = ""
    @State private var draftNotebook: UUID?
    @State private var savedNotice: String?
    @State private var hovered: UUID?
    @StateObject private var windowBox = WindowBox()
    @ObservedObject private var sync = SyncController.shared

    private static let recentLimit = 12

    var body: some View {
        VStack(spacing: 0) {
            header
            PanelSearchField(
                text: $query,
                focusToken: focusToken,
                onMove: move,
                onSubmit: openHighlighted,
                onCancel: { query.isEmpty ? closePanel() : (query = "") }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if !isSearching {
                composer
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Divider()
            noteList
            Divider()
            if sync.isConfigured {
                MenuBarSyncRow()
                Divider()
            }
            footer
        }
        .frame(width: Tokens.Size.menuBarPanelWidth, height: Tokens.Size.menuBarPanelHeight)
        .background(WindowReader { window in
            windowBox.attach(window)
        })
        .onAppear { prepareForDisplay() }
        .onChange(of: windowBox.openCount) { prepareForDisplay() }
        .onChange(of: query) {
            highlighted = isSearching ? visibleNotes.first?.id : nil
        }
        .capturesOpenWindow()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView(size: 24)
            Text("NoteIt")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                closePanel()
                WindowRouter.showMainWindow()
            } label: {
                Text("Open NoteIt")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open the main window (⌘O)")
            .keyboardShortcut("o", modifiers: .command)

            IconButton(symbol: "gearshape", help: "Settings… (⌘,)") { showSettings() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Quick note composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Jot down a quick note…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Tokens.Font.row)
                .lineLimit(1...4)
                .onSubmit(saveDraft)

            HStack(spacing: 6) {
                NotebookMenuPicker(selection: $draftNotebook, store: store)
                Spacer()
                if let savedNotice {
                    Label(savedNotice, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.Color.success)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open in Quick Capture") {
                    let text = draft
                    draft = ""
                    closePanel()
                    QuickCaptureController.shared.show(body: draftIsEmptyText(text) ? nil : text)
                }
                Button(action: saveDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(draftIsEmpty ? Color.secondary : Color.accentColor)
                .disabled(draftIsEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save note (⌘↩)")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: Tokens.Size.hairline)
        )
        .animation(.easeOut(duration: 0.2), value: savedNotice)
    }

    private var draftIsEmpty: Bool { draftIsEmptyText(draft) }

    private func draftIsEmptyText(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func saveDraft() {
        guard let meta = store.captureNote(title: "", body: draft, in: draftNotebook) else { return }
        draft = ""
        let name = store.notebook(with: meta.notebookID)?.name
        savedNotice = name.map { "Saved to \($0)" } ?? "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            MainActor.assumeIsolated { savedNotice = nil }
        }
    }

    // MARK: - Notes list

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var pinnedNotes: [NoteMeta] {
        store.notes.filter(\.isPinned).sorted { $0.updatedAt > $1.updatedAt }
    }

    private var recentNotes: [NoteMeta] {
        Array(store.notes.filter { !$0.isPinned }.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.recentLimit))
    }

    private var searchResults: [NoteMeta] {
        Array(store.notes(for: .allNotes, search: query).prefix(50))
    }

    /// Notes in keyboard-navigation order.
    private var visibleNotes: [NoteMeta] {
        isSearching ? searchResults : pinnedNotes + recentNotes
    }

    private var noteList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                    if isSearching {
                        if searchResults.isEmpty {
                            emptyState(symbol: "magnifyingglass", text: "No notes match “\(query)”")
                        } else {
                            sectionHeader("\(searchResults.count) Result\(searchResults.count == 1 ? "" : "s")")
                            rows(searchResults)
                        }
                    } else if store.notes.isEmpty {
                        emptyState(symbol: "note.text", text: "No notes yet — jot one down above.")
                    } else {
                        if !pinnedNotes.isEmpty {
                            sectionHeader("Pinned")
                            rows(pinnedNotes)
                        }
                        if !recentNotes.isEmpty {
                            sectionHeader("Recent")
                            rows(recentNotes)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: highlighted) {
                guard let highlighted else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(highlighted) }
            }
        }
    }

    private func rows(_ notes: [NoteMeta]) -> some View {
        ForEach(notes) { note in
            MenuBarNoteRow(
                note: note,
                notebook: store.notebook(with: note.notebookID),
                isHighlighted: highlighted == note.id,
                isHovered: hovered == note.id
            )
            .id(note.id)
            .onHover { inside in
                if inside { hovered = note.id } else if hovered == note.id { hovered = nil }
            }
            .onTapGesture { open(note.id) }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Tokens.Font.sectionLabel)
            .tracking(Tokens.Tracking.sectionLabel)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func emptyState(symbol: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.horizontal, 24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "New Note", symbol: "square.and.pencil", shortcut: "⌘N") { newNote() }
                .keyboardShortcut("n", modifiers: .command)
            Spacer()
            FooterButton(title: "Settings…", symbol: "gearshape", shortcut: nil) { showSettings() }
                .keyboardShortcut(",", modifiers: .command)
            FooterButton(title: "Quit NoteIt", symbol: "power", shortcut: nil) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func prepareForDisplay() {
        query = ""
        highlighted = nil
        draftNotebook = store.defaultNotebookIDForNewNotes
        focusToken += 1
    }

    private func move(_ direction: PanelSearchField.Direction) {
        let notes = visibleNotes
        guard !notes.isEmpty else { return }
        let current = highlighted.flatMap { id in notes.firstIndex { $0.id == id } }
        let next: Int
        switch direction {
        case .down: next = current.map { min($0 + 1, notes.count - 1) } ?? 0
        case .up: next = current.map { max($0 - 1, 0) } ?? notes.count - 1
        }
        highlighted = notes[next].id
    }

    private func openHighlighted() {
        if let id = highlighted ?? (isSearching ? visibleNotes.first?.id : nil) {
            open(id)
        }
    }

    private func open(_ id: UUID) {
        store.reveal(id)
        closePanel()
        WindowRouter.showMainWindow()
    }

    private func newNote() {
        closePanel()
        let meta = store.createNote(in: store.defaultNotebookIDForNewNotes)
        store.reveal(meta.id)
        WindowRouter.showMainWindow()
        WindowRouter.focusEditor()
    }

    /// Uses this view's own (live) `openSettings` action before the panel closes, then closes the
    /// panel on the next run-loop turn so the action's host is still alive when it runs.
    private func showSettings() {
        SettingsOpener.open(using: openSettings)
        DispatchQueue.main.async { closePanel() }
    }

    private func closePanel() {
        windowBox.window?.close()
    }
}

/// Holds the panel window and bumps `openCount` each time it becomes key (i.e. the panel opens).
/// Stores no view closures and observes weakly, so it cannot form a retain cycle with the view.
@MainActor
private final class WindowBox: ObservableObject {
    weak var window: NSWindow?
    @Published private(set) var openCount = 0
    private let observerToken = ObserverToken()

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        observerToken.replace(with: NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.openCount += 1 }
        })
    }
}

/// Removes its NotificationCenter observer when replaced or deallocated.
private final class ObserverToken {
    private var token: NSObjectProtocol?

    func replace(with newToken: NSObjectProtocol?) {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = newToken
    }

    deinit { replace(with: nil) }
}

private struct MenuBarNoteRow: View {
    let note: NoteMeta
    let notebook: Notebook?
    let isHighlighted: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 10) {
            NotebookGlyph(notebook: notebook, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(note.preview.isEmpty ? "No additional text" : note.preview)
                    .font(Tokens.Font.rowMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(RelativeDate.short(note.updatedAt))
                .font(Tokens.Font.rowMeta)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.22)
                      : isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

enum RelativeDate {
    /// "Now", "5m", "3h", "Yesterday", "Mon", "Sep 3", "Sep 3, 2024".
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
