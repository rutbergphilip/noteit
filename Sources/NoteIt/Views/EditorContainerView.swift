import NoteItCore
import SwiftUI

struct EditorContainerView: View {
    @EnvironmentObject private var store: NoteStore
    @StateObject private var editor = EditorController()
    @StateObject private var find = FindReplaceModel()
    @StateObject private var searchHighlights = SearchHighlightController()
    @StateObject private var renames = RenameTracker()
    @EnvironmentObject private var navigation: NavigationModel
    @ObservedObject private var linkState = LinkNavigationState.shared
    @AppStorage(PrefKey.inspectorVisible) private var inspectorVisible = false

    var body: some View {
        content
            .inspector(isPresented: $inspectorVisible) {
                LinksPanelView(noteID: store.selectedNoteID)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let id = store.selectedNoteID, let note = store.note(with: id) {
            let writeBlocked = store.isBodyWriteBlocked(id)
            let readOnly = writeBlocked || note.deletedAt != nil || store.libraryConversionInProgress
                || store.markdownFolderUnavailable || store.isMarkdownBodyLoading(id) || store.isMarkdownBodyUnread(id)
                || store.isMarkdownBodyMissing(id)
            VStack(spacing: 0) {
                EditorHeader(note: note)
                LinkRenameBanner(tracker: renames)
                if let missing = linkState.missingHeading, missing.note == id {
                    Text("Heading “\(missing.heading)” not found")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                }
                if let deletedAt = note.deletedAt {
                    DeletedNoteBanner(note: note, deletedAt: deletedAt)
                }
                if store.libraryConversionInProgress {
                    Text("Converting your library…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                if store.markdownFolderUnavailable, let folder = store.markdownStorage?.contentRootURL {
                    Text(store.markdownFolderChecking
                         ? "Checking “\(folder.lastPathComponent)”… Notes are read-only until it answers."
                         : "“\(folder.lastPathComponent)” isn’t responding. Notes are read-only until it’s back.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                if store.isMarkdownBodyLoading(id), !store.markdownFolderUnavailable,
                   let folder = store.markdownStorage?.contentRootURL {
                    Text("Reading this note from “\(folder.lastPathComponent)”…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                if store.isRecoveredEditUnreadable(id) {
                    LoadErrorBanner(message: "This note’s recovered edit couldn’t be read from the Recovery folder. Retry, or discard the edit to keep the note without it; the edit is set aside, not deleted.",
                                    file: store.recoveryURL, readOnly: true, retry: { store.retryMarkdownRecovery(of: [id]) },
                                    secondary: ("Discard Recovered Edit", { store.discardRecoveredEdit(id) }))
                } else if store.isMarkdownRecoveryHeld(id), note.deletedAt == nil, !store.markdownFolderUnavailable {
                    Text("Restoring this note’s recovered edit…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                if store.isMarkdownBodyUnread(id), !store.isMarkdownBodyLoading(id), !store.markdownFolderUnavailable,
                   !store.isMarkdownRecoveryHeld(id), let folder = store.markdownStorage?.contentRootURL {
                    Text("This note hasn’t been read from “\(folder.lastPathComponent)” yet, so it’s read-only.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                if store.isMarkdownBodyMissing(id), let folder = store.markdownStorage?.contentRootURL {
                    LoadErrorBanner(message: "This note’s file is missing from “\(folder.lastPathComponent)”. If it doesn’t come back, the note moves to Recently Deleted with its last text.",
                                    file: nil, readOnly: true, retry: { store.retryReadingBody(id) })
                }
                if let message = store.loadError(for: id) {
                    LoadErrorBanner(message: message, file: store.loadErrorFile(for: id), readOnly: writeBlocked,
                                    retry: store.canRetryReadingBody(id) ? { store.retryReadingBody(id) } : nil)
                }
                if let notice = store.bodySaveNotice(for: id) {
                    LoadErrorBanner(message: notice, file: nil, readOnly: false, title: "This note isn’t saved")
                }
                FormattingToolbar(controller: editor)
                    .disabled(readOnly)
                Divider().opacity(0.5)
                RichTextEditor(noteID: id, controller: editor, isEditable: !readOnly)
                    .id(id)
                    .overlay(alignment: .topTrailing) {
                        if find.isVisible {
                            FindReplaceBar(model: find)
                                .padding(.top, Tokens.Space.s8)
                                .padding(.horizontal, Tokens.Space.s16)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: find.isVisible)
            }
            .onAppear {
                find.editor = editor
                searchHighlights.editor = editor
            }
            .onChange(of: id, initial: true) { searchHighlights.update(search: store.searchText) }
            .onChange(of: store.searchText) { _, search in searchHighlights.update(search: search) }
            .onDisappear { find.close(refocusText: false) }
            .onChange(of: readOnly, initial: true) { find.allowsReplace = !readOnly }
            .onChange(of: id) { find.close(refocusText: false) }
            .onChange(of: id, initial: true) { _, id in
                renames.store = store
                renames.open(id, title: note.title)
            }
            .onChange(of: note.title) { _, title in renames.titleObserved(title, of: id) }
            .background(Tokens.Color.surfaceEditor)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    NavigationButtons(navigation: navigation)
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareToolbarButton(note: note)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { inspectorVisible.toggle() } label: {
                        Label("Links and Outline", systemImage: "sidebar.trailing")
                    }
                    .help(inspectorVisible ? "Hide Links and Outline" : "Show Links and Outline")
                }
            }
        } else {
            // Blank, like Notes: the list column carries the empty state and its New Note action.
            Tokens.Color.surfaceEditor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NavigationButtons: View {
    @EnvironmentObject private var store: NoteStore
    @ObservedObject var navigation: NavigationModel

    var body: some View {
        ControlGroup {
            Button { navigation.goBack(in: store) } label: { Image(systemName: "chevron.backward") }
                .help("Go Back")
                .accessibilityLabel("Go Back")
                .disabled(!navigation.history.canGoBack)
            Button { navigation.goForward(in: store) } label: { Image(systemName: "chevron.forward") }
                .help("Go Forward")
                .accessibilityLabel("Go Forward")
                .disabled(!navigation.history.canGoForward)
        }
    }
}

struct EditorHeader: View {
    @EnvironmentObject private var store: NoteStore
    let note: NoteMeta
    @State private var showsCalendar = false

    private var notebook: Notebook? { store.notebook(with: note.notebookID) }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.notebookPickerEntries) { entry in
                    Button {
                        store.moveNote(note.id, to: entry.id)
                    } label: {
                        NotebookPickerLabel(entry)
                    }
                }
                Divider()
                Button("No Notebook") { store.moveNote(note.id, to: nil) }
            } label: {
                NotebookChip(notebook: notebook)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move to Notebook")
            .disabled(note.deletedAt != nil)

            Text("Edited \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let source = note.conflictSource {
                ConflictBadge(source: source) { store.markConflictResolved(note.id) }
            }

            if DailyNotes.isAvailable, note.deletedAt == nil, let day = store.dailyDay(of: note.id) {
                dailyControls(day)
            }

            Button {
                store.togglePin(note.id)
            } label: {
                Image(systemName: note.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(note.isPinned ? Tokens.Color.pinned : Color.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(note.isPinned ? "Unpin" : "Pin")
            .disabled(note.deletedAt != nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func dailyControls(_ day: DayKey) -> some View {
        let previous = store.adjacentDailyNote(to: note.id, forward: false)
        let next = store.adjacentDailyNote(to: note.id, forward: true)
        HStack(spacing: 2) {
            Button { store.openAdjacentDailyNote(to: note.id, forward: false) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 22) }
                .disabled(previous == nil)
                .help(previous.map { "Previous Daily Note: \($0.displayTitle)" } ?? "No earlier daily note")
                .accessibilityLabel("Previous Daily Note")
            Button { showsCalendar = true } label: { Image(systemName: "calendar").frame(width: 22, height: 22) }
                .help("Daily Note for Date…")
                .accessibilityLabel("Daily Note for Date")
                .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                    DailyCalendarView(selected: day) { showsCalendar = false }
                        .environmentObject(store)
                }
            Button { store.openAdjacentDailyNote(to: note.id, forward: true) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 22) }
                .disabled(next == nil)
                .help(next.map { "Next Daily Note: \($0.displayTitle)" } ?? "No later daily note")
                .accessibilityLabel("Next Daily Note")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

}

/// Shown on a sync conflict copy; "Resolved" clears the badge (also cleared by editing the copy).
struct ConflictBadge: View {
    let source: String
    let resolve: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Label("Conflict copy from \(source)", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Button("Mark Resolved", action: resolve)
                .controlSize(.small)
                .help("Keep this note and clear its conflict badge")
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.orange.opacity(0.12)))
    }
}

struct NotebookChip: View {
    let notebook: Notebook?

    var body: some View {
        let tint = notebook?.color ?? .secondary
        HStack(spacing: 5) {
            Image(systemName: notebook?.symbol ?? "tray")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(notebook?.name ?? "No Notebook")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.Color.ink)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(Tokens.Opacity.tintChip)))
    }
}

/// Persistent notice for a note whose body file couldn't be read.
struct LoadErrorBanner: View {
    let message: String
    let file: URL?
    let readOnly: Bool
    var title: String? = nil
    var retry: (() -> Void)? = nil
    var secondary: (title: String, action: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? (readOnly ? "This note is read-only" : "This note couldn’t be opened"))
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .help(message)
            }
            Spacer(minLength: 8)
            if let retry {
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .controlSize(.small)
            }
            if let file {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
                .controlSize(.small)
                .help(file.path)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
