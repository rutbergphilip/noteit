import AppKit
import SwiftUI

/// File › Version History…: earlier versions of a note on the left, a read-only preview on the right.
struct VersionHistorySheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID

    @State private var versions: [NoteVersion] = []
    @State private var selectedID: URL?
    @State private var preview: NSAttributedString?
    @State private var errorMessage: String?

    private var selected: NoteVersion? { versions.first { $0.id == selectedID } }
    private var canRestore: Bool {
        selected != nil && preview != nil && store.note(with: noteID)?.deletedAt == nil && !store.isBodyWriteBlocked(noteID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if versions.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "No Earlier Versions",
                    message: "Versions are saved automatically as you edit this note."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    versionList
                        .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
                    previewPane
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 540)
        .onAppear(perform: reload)
        .onChange(of: selectedID) { _, _ in loadPreview() }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Version History")
                .font(.headline)
            if let note = store.note(with: noteID) {
                Text("— \(note.displayTitle)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.s16)
        .padding(.vertical, Tokens.Space.s12)
    }

    private var versionList: some View {
        List(selection: $selectedID) {
            ForEach(versions) { version in
                Text(Self.label(for: version.date))
                    .font(Tokens.Font.row)
                    .tag(version.id)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var previewPane: some View {
        if let preview {
            VersionPreview(text: preview)
                .background(Tokens.Color.surfaceEditor)
        } else if let errorMessage {
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Can’t Show This Version", message: errorMessage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.Color.surfaceEditor)
        } else {
            Tokens.Color.surfaceEditor
        }
    }

    private var footer: some View {
        HStack {
            Text(versions.count == 1 ? "1 version" : "\(versions.count) versions")
                .font(Tokens.Font.rowMeta)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Restore This Version", action: restore)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRestore)
        }
        .padding(.horizontal, Tokens.Space.s16)
        .padding(.vertical, Tokens.Space.s12)
    }

    private func reload() {
        versions = store.versions(of: noteID)
        if selectedID == nil || selected == nil { selectedID = versions.first?.id }
        loadPreview()
    }

    private func loadPreview() {
        guard let version = selected else { preview = nil; errorMessage = nil; return }
        do {
            preview = try store.history.load(version).text
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func restore() {
        guard let version = selected else { return }
        do {
            try store.restoreVersion(version)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            preview = nil
        }
    }

    /// "Today 14:02", "Yesterday 09:15", or the date and time.
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Read-only rendering of a version with the editor's own text view, so blocks and checklists look the same.
private struct VersionPreview: NSViewRepresentable {
    let text: NSAttributedString

    final class Coordinator {
        var shown: NSAttributedString?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = NoteItTextView.make()
        textView.isEditable = false
        textView.isSelectable = true
        show(text, in: textView)
        context.coordinator.shown = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NoteItTextView,
              context.coordinator.shown.map({ !$0.isEqual(to: text) }) ?? true else { return }
        show(text, in: textView)
        context.coordinator.shown = text
    }

    private func show(_ text: NSAttributedString, in textView: NoteItTextView) {
        textView.storage.setAttributedString(text)
        NoteItTextView.refreshTableColors(in: textView.storage)
        NoteItTextView.normalize(textView.storage, around: NSRange(location: 0, length: textView.storage.length), chromeInsets: true)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        textView.needsDisplay = true
    }
}
