import AppKit
import SwiftUI

enum ImportSource: String, CaseIterable, Identifiable {
    case markdown, bear, appleNotes, evernote, notion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: "Markdown & Obsidian"
        case .bear: "Bear"
        case .appleNotes: "Apple Notes"
        case .evernote: "Evernote"
        case .notion: "Notion"
        }
    }

    var detail: String {
        switch self {
        case .markdown: "A folder or .md and .txt files. Subfolders become notebooks, and images come along."
        case .bear: "Notes exported from Bear as TextBundle, TextPack or Markdown, with their images."
        case .appleNotes: "Reads every folder straight from the Notes app. macOS asks for permission the first time."
        case .evernote: "Choose one or more .enex files exported from Evernote. Each file becomes a notebook."
        case .notion: "Choose the .zip from Notion's Export › Markdown & CSV. Pages keep their images and tables."
        }
    }

    var symbol: String {
        switch self {
        case .markdown: "doc.text"
        case .bear: "pawprint"
        case .appleNotes: "note.text"
        case .evernote: "square.and.arrow.down.on.square"
        case .notion: "doc.on.doc"
        }
    }

    var tint: Color {
        switch self {
        case .markdown: Tokens.Color.notebookIndigo
        case .bear: Tokens.Color.notebookRed
        case .appleNotes: Tokens.Color.notebookOrange
        case .evernote: Tokens.Color.notebookGreen
        case .notion: Tokens.Color.notebookGray
        }
    }
}

@MainActor
final class ImportModel: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case running(ImportSource)
        case finished(ImportReport)
        case failed(ImportError)
    }

    @Published var source: ImportSource = .markdown
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var progress = ImportProgress()

    private let store: NoteStore
    private var task: Task<Void, Never>?

    init(store: NoteStore) {
        self.store = store
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func start() {
        switch source {
        case .markdown, .bear:
            guard let urls = chooseFiles(for: source) else { return }
            let items = MarkdownImporter.items(for: urls)
            guard !items.isEmpty else {
                phase = .failed(.nothingToImport)
                return
            }
            run(source) { model in
                await MarkdownImporter(store: model.store).run(items) { model.progress = $0 }
            }
        case .evernote:
            guard let urls = chooseFiles(for: source) else { return }
            let items = EvernoteImporter.items(for: urls)
            guard !items.isEmpty else {
                phase = .failed(.nothingToImport)
                return
            }
            run(source) { model in
                await EvernoteImporter.importItems(items, into: model.store) { model.progress = $0 }
            }
        case .notion:
            guard let url = chooseFiles(for: source)?.first else { return }
            run(source) { model in
                do {
                    return try await NotionImporter.importExport(url, into: model.store) { model.progress = $0 }
                } catch let error as ImportError {
                    model.phase = .failed(error)
                    return nil
                } catch {
                    model.phase = .failed(.unreadableArchive(url.lastPathComponent))
                    return nil
                }
            }
        case .appleNotes:
            run(.appleNotes) { model in
                do {
                    try await AppleNotesImporter.requestPermission()
                    if Task.isCancelled { return ImportReport(cancelled: true) }
                    return try await AppleNotesImporter(store: model.store).run { model.progress = $0 }
                } catch let error as ImportError {
                    model.phase = .failed(error)
                    return nil
                } catch {
                    model.phase = .failed(.notesUnavailable(error.localizedDescription))
                    return nil
                }
            }
        }
    }

    private func run(_ source: ImportSource, _ work: @escaping (ImportModel) async -> ImportReport?) {
        progress = ImportProgress()
        phase = .running(source)
        task = Task { [weak self] in
            guard let self else { return }
            if let report = await work(self) {
                self.phase = report.notesImported == 0 && report.lockedSkipped == 0 && report.notesSkipped == 0
                    && report.filesSkipped == 0 && report.archivesSkipped.isEmpty
                    && !report.cancelled && !report.permissionDenied
                    ? .failed(.nothingToImport)
                    : .finished(report)
            }
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        phase = .choosing
        progress = ImportProgress()
    }

    private func chooseFiles(for source: ImportSource) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = source != .notion
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Import"
        panel.message = switch source {
        case .bear: "Choose the files or folder you exported from Bear."
        case .evernote: "Choose .enex files, or a folder of them. Subfolders become notebook stacks."
        case .notion: "Choose the .zip you exported from Notion, or its unzipped folder."
        default: "Choose a folder, such as an Obsidian vault, or Markdown and text files."
        }
        return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }
}

struct ImportSheet: View {
    @ObservedObject var model: ImportModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch model.phase {
            case .choosing:
                choices
            case .running(let source):
                running(source)
            case .finished(let report):
                finished(report)
            case .failed(let error):
                failed(error)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: Tokens.Radius.preview, style: .continuous)
                .fill(Tokens.Color.notebookBlue.gradient)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                )
                .shadow(color: Tokens.Color.notebookBlue.opacity(0.35), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Notes").font(.title3.weight(.semibold))
                Text("Bring notes in from another app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Choosing

    private var choices: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: Tokens.Space.s8) {
                ForEach(ImportSource.allCases) { source in
                    SourceRow(source: source, selected: model.source == source) { model.source = source }
                }
            }
            Label("Importing the same notes twice creates duplicates. Your existing notes aren't changed.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(model.source == .appleNotes ? "Import" : "Choose…") {
                    model.start()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Running

    private func running(_ source: ImportSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.progress.total > 0 {
                ProgressView(value: model.progress.fraction)
                HStack {
                    Text(model.progress.currentName.isEmpty ? "Importing…" : model.progress.currentName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(min(model.progress.completed + 1, model.progress.total)) of \(model.progress.total)")
                        .monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear)
                Text(source != .appleNotes ? "Looking for notes…"
                     : model.progress.currentName.isEmpty ? "Reading folders from Notes…"
                     : "Reading “\(model.progress.currentName)” from Notes…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Done

    private func finished(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.cancelled || report.permissionDenied ? "Import stopped" : "Import complete").font(.headline)
                    Text(report.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: report.cancelled || report.permissionDenied ? "stop.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(report.cancelled || report.permissionDenied ? Tokens.Color.inkSecondary : Tokens.Color.success)
            }
            HStack {
                if report.permissionDenied {
                    Button("Open System Settings") { AppleNotesImporter.openAutomationSettings() }
                }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ error: ImportError) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(error.localizedDescription)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Tokens.Color.pinned)
            }
            HStack {
                if error == .notesPermissionDenied {
                    Button("Open System Settings") { AppleNotesImporter.openAutomationSettings() }
                }
                Spacer()
                Button("Back") { model.reset() }
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct SourceRow: View {
    let source: ImportSource
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Tokens.Space.s12) {
                RoundedRectangle(cornerRadius: Tokens.Radius.glyph(side: 32), style: .continuous)
                    .fill(source.tint.gradient)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: source.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.body.weight(.semibold))
                    Text(source.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Tokens.Color.accent : Tokens.Color.inkTertiary)
            }
            .padding(Tokens.Space.s12)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(selected ? Tokens.Color.accent.opacity(0.08) : Tokens.Color.fillQuiet.opacity(0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Tokens.Color.accent.opacity(0.6) : Tokens.Color.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shows the import sheet on the main window.
@MainActor
enum ImportSheetPresenter {
    private static var sheet: NSWindow?

    static func show() {
        if let sheet, sheet.sheetParent != nil {
            sheet.makeKeyAndOrderFront(nil)
            return
        }
        WindowRouter.showMainWindow()
        present(attempt: 0)
    }

    private static func present(attempt: Int) {
        guard let parent = WindowRouter.mainWindow, parent.isVisible else {
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { present(attempt: attempt + 1) }
            }
            return
        }
        guard parent.attachedSheet == nil else { return }
        let model = ImportModel(store: NoteStore.shared)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let view = ImportSheet(
            model: model,
            close: { [weak window] in
                model.cancel()
                guard let window else { return }
                window.sheetParent?.endSheet(window)
            }
        )
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
        sheet = window
        parent.beginSheet(window) { _ in
            MainActor.assumeIsolated { sheet = nil }
        }
    }
}
