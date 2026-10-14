import SwiftUI

struct EditorContainerView: View {
    @EnvironmentObject private var store: NoteStore
    @StateObject private var editor = EditorController()

    var body: some View {
        if let id = store.selectedNoteID, let note = store.note(with: id) {
            let writeBlocked = store.isBodyWriteBlocked(id)
            let readOnly = writeBlocked || note.deletedAt != nil
            VStack(spacing: 0) {
                EditorHeader(note: note)
                if let deletedAt = note.deletedAt {
                    DeletedNoteBanner(note: note, deletedAt: deletedAt)
                }
                if let message = store.loadError(for: id) {
                    LoadErrorBanner(message: message, file: store.loadErrorFile(for: id), readOnly: writeBlocked)
                }
                FormattingToolbar(controller: editor)
                    .disabled(readOnly)
                Divider().opacity(0.5)
                RichTextEditor(noteID: id, controller: editor, isEditable: !readOnly)
                    .id(id)
            }
            .background(Tokens.Color.surfaceEditor)
        } else {
            EmptyStateView(
                symbol: "square.and.pencil",
                title: "No Note Selected",
                message: "Choose a note from the list, or start something new.",
                actionTitle: "New Note"
            ) { store.createNoteInCurrentContext() }
            .background(Tokens.Color.surfaceEditor)
        }
    }
}

struct EditorHeader: View {
    @EnvironmentObject private var store: NoteStore
    let note: NoteMeta

    private var notebook: Notebook? { store.notebook(with: note.notebookID) }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.sortedNotebooks) { nb in
                    Button {
                        store.moveNote(note.id, to: nb.id)
                    } label: {
                        Label(nb.name, systemImage: nb.symbol)
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(readOnly ? "This note is read-only" : "This note couldn’t be opened")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .help(message)
            }
            Spacer(minLength: 8)
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
