import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted with a note ID before it's exported, printed, shared or copied, so the editor commits pending edits.
    static let noteItWillExportNote = Notification.Name("noteItWillExportNote")
}

/// The export, print, Share and Copy as Markdown commands, with their panels and alerts.
@MainActor
enum ExportActions {
    private static let formatKey = "exportFormat"
    private static var store: NoteStore { NoteStore.shared }

    static var currentNote: NoteMeta? { store.note(with: store.selectedNoteID) }

    /// The notebook selected in the sidebar, or else the current note's notebook. A note in Recently
    /// Deleted has none.
    static var currentNotebook: Notebook? {
        if case .notebook(let id) = store.selection, let nb = store.notebook(with: id) { return nb }
        guard let note = currentNote, note.deletedAt == nil else { return nil }
        return store.notebook(with: note.notebookID)
    }

    static var hasExportableNotes: Bool { !NoteExporter.exportableNotes(in: store.notes).isEmpty }

    private static var lastFormat: ExportFormat {
        get { UserDefaults.standard.string(forKey: formatKey).flatMap(ExportFormat.init(rawValue:)) ?? .markdown }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: formatKey) }
    }

    /// Sheets go on the key window, but never on the command palette, which closes when it loses key.
    static var window: NSWindow? {
        if let key = NSApp.keyWindow, !(key is PalettePanel) { return key }
        return WindowRouter.mainWindow ?? NSApp.mainWindow
    }

    /// The note's saved body, including edits still waiting in the editor. Nil, after telling the user, while its
    /// file hasn't been read: a placeholder is never exported, printed, copied or shared.
    static func body(of note: NoteMeta) -> NSAttributedString? {
        NotificationCenter.default.post(name: .noteItWillExportNote, object: note.id)
        guard let body = store.bodyForOutput(note.id) else {
            showUnread([note.displayTitle])
            return nil
        }
        return body
    }

    private static func showUnread(_ titles: [String], in parent: NSWindow? = nil) {
        let folder = store.markdownStorage?.contentRootURL.lastPathComponent ?? "the library folder"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = titles.count == 1 ? "“\(titles[0])” wasn’t read yet" : "\(titles.count) notes weren’t read yet"
        alert.informativeText = Self.unreadDetail(titles, folder: folder)
        if let window = parent ?? Self.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    static func unreadDetail(_ titles: [String], folder: String) -> String {
        let shown = titles.prefix(10).map { "“\($0)”" }.joined(separator: ", ")
        let more = titles.count > 10 ? " and \(titles.count - 10) more" : ""
        let subject = titles.count == 1 ? "Its file" : "Their files"
        return "\(shown)\(more): \(subject) in “\(folder)” didn’t answer, so nothing was output for \(titles.count == 1 ? "it" : "them"). Try again once the folder responds."
    }

    /// Note links written with the linked notes' current titles.
    static var noteTitles: ExportLinkContext {
        let store = store
        return .titles { store.note(with: $0)?.displayTitle }
    }

    static func markdown(of note: NoteMeta) -> String? {
        guard let body = body(of: note) else { return nil }
        return MarkdownWriter.write(body, title: ExportNaming.sanitized(note.displayTitle), links: noteTitles).markdown
    }

    // MARK: Copy as Markdown

    /// Copies the editor's selection, or the whole note when nothing is selected.
    static func copyAsMarkdown() {
        guard let note = currentNote else { return }
        let title = ExportNaming.sanitized(note.displayTitle)
        let markdown: String
        if let textView = window?.firstResponder as? NoteItTextView, textView.selectedRange().length > 0 {
            let selection = textView.attributedString().attributedSubstring(from: textView.selectedRange())
            markdown = MarkdownWriter.write(selection, title: title, links: noteTitles).markdown
        } else {
            guard let body = body(of: note) else { return }
            markdown = MarkdownWriter.write(body, title: title, links: noteTitles).markdown
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("net.daringfireball.markdown")], owner: nil)
        pasteboard.setString(markdown, forType: .string)
        pasteboard.setString(markdown, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
    }

    // MARK: Print

    static func printCurrentNote() {
        guard let note = currentNote, let body = body(of: note) else { return }
        let operation = NoteExporter.printOperation(body, title: note.displayTitle)
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: Share

    private static let shareDelegate = ShareSubjectDelegate()

    /// Services that can share text, for the File › Share menu.
    static let sharingServices: [NSSharingService] =
        (NSSharingService.self as SharingServiceLookup.Type).sharingServices(forItems: ["Markdown"])

    static func share(_ note: NoteMeta, with service: NSSharingService) {
        guard let markdown = markdown(of: note) else { return }
        service.subject = note.displayTitle
        service.perform(withItems: [markdown])
    }

    static func showSharePicker(for note: NoteMeta, relativeTo view: NSView) {
        guard let markdown = markdown(of: note) else { return }
        shareDelegate.subject = note.displayTitle
        let picker = NSSharingServicePicker(items: [markdown])
        picker.delegate = shareDelegate
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    // MARK: Export

    static func exportCurrentNote() {
        guard let note = currentNote else { return }
        let panel = NSSavePanel()
        panel.title = "Export Note"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let picker = FormatPicker(format: lastFormat)
        let name = ExportNaming.sanitized(note.displayTitle)
        picker.onChange = { [weak panel] format in
            guard let panel else { return }
            panel.allowedContentTypes = [format.contentType]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = (base.isEmpty ? name : base) + "." + format.fileExtension
        }
        panel.accessoryView = picker.view
        picker.onChange?(picker.format)
        panel.nameFieldStringValue = name + "." + picker.format.fileExtension

        present(panel) { url in
            let format = picker.format
            lastFormat = format
            guard let body = body(of: note) else { return }
            do {
                try NoteExporter.write(body, title: note.displayTitle, format: format, to: url, links: noteTitles)
            } catch {
                showError(error, message: "Couldn’t export “\(note.displayTitle)”")
            }
        }
    }

    static func exportCurrentNotebook() {
        guard let notebook = currentNotebook else { return }
        chooseFolder(title: "Export “\(notebook.name)”") { folder, format in
            try NoteExporter.prepareNotebook(notebook, notebooks: store.notebooks, notes: store.notes, format: format, to: folder, body: body(ofNoteWith:))
        }
    }

    static func exportAllNotes() {
        chooseFolder(title: "Export All Notes") { folder, format in
            try NoteExporter.prepareAll(notebooks: store.sortedNotebooks, notes: store.notes, format: format, to: folder,
                                        body: body(ofNoteWith:))
        }
    }

    private static func body(ofNoteWith id: UUID) -> NSAttributedString? {
        NotificationCenter.default.post(name: .noteItWillExportNote, object: id)
        return store.bodyForOutput(id)
    }

    private static func chooseFolder(title: String, export: @escaping (URL, ExportFormat) throws -> NotesExport) {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "Choose a folder. A folder for each notebook is created inside it."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let picker = FormatPicker(format: lastFormat)
        panel.accessoryView = picker.view
        panel.isAccessoryViewDisclosed = true

        present(panel) { folder in
            let format = picker.format
            lastFormat = format
            do {
                let notes = try export(folder, format)
                notes.bodyWhenRead = { [store] id in
                    NotificationCenter.default.post(name: .noteItWillExportNote, object: id)
                    return await store.bodyForOutputWhenRead(id)
                }
                run(notes, title: title)
            } catch {
                showError(error, message: "Couldn’t export the notes")
            }
        }
    }

    private static var isExporting = false

    /// Writes the notes a slice at a time, with a progress sheet once it takes longer than one slice.
    private static func run(_ export: NotesExport, title: String) {
        let parent = window
        let progress = ExportProgress(total: export.total)
        var sheet: NSWindow?
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let result = try await export.write { export in
                    progress.completed = export.next
                    if sheet == nil, !export.isFinished, let parent {
                        sheet = ExportProgressPresenter.show(progress, title: title, on: parent)
                    }
                    return !progress.isCancelled
                }
                sheet.map(ExportProgressPresenter.dismiss)
                showCompletion(result, in: parent)
            } catch {
                sheet.map(ExportProgressPresenter.dismiss)
                let written = export.written
                showError(error, message: "Couldn’t export the notes",
                          detail: written > 0 ? "\(written) of \(export.total) notes were exported to “\(export.folder.lastPathComponent)”." : nil,
                          in: parent)
            }
        }
    }

    private static func present(_ panel: NSSavePanel, then completion: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            // Let the panel's sheet close before writing, so alerts can attach to the window.
            DispatchQueue.main.async { completion(url) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private static func showCompletion(_ result: NoteExporter.Result, in parent: NSWindow?) {
        let window = parent ?? Self.window
        let alert = NSAlert()
        if result.noteCount < result.totalCount {
            alert.messageText = "Exported \(result.noteCount) of \(result.totalCount) notes"
        } else {
            alert.messageText = result.noteCount == 1 ? "Exported 1 note" : "Exported \(result.noteCount) notes"
        }
        alert.informativeText = "They’re in “\(result.folder.lastPathComponent)”."
        if !result.skipped.isEmpty {
            let folder = store.markdownStorage?.contentRootURL.lastPathComponent ?? "the library folder"
            alert.alertStyle = .warning
            alert.informativeText += " Not exported: " + unreadDetail(result.skipped, folder: folder)
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        let folder = result.folder
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private static func showError(_ error: Error, message: String, detail: String? = nil, in parent: NSWindow? = nil) {
        let window = parent ?? Self.window
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = [error.localizedDescription, detail].compactMap { $0 }.joined(separator: " ")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// The "Format:" pop-up shown in export panels.
@MainActor
private final class FormatPicker: NSObject {
    private(set) var format: ExportFormat
    var onChange: ((ExportFormat) -> Void)?
    let view: NSView
    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)

    init(format: ExportFormat) {
        self.format = format
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popUp])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        view = stack
        super.init()
        for f in ExportFormat.allCases {
            popUp.addItem(withTitle: f.displayName)
            popUp.lastItem?.representedObject = f.rawValue
        }
        popUp.selectItem(at: ExportFormat.allCases.firstIndex(of: format) ?? 0)
        popUp.target = self
        popUp.action = #selector(changed)
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(stack.fittingSize)
    }

    @objc private func changed() {
        guard let raw = popUp.selectedItem?.representedObject as? String, let f = ExportFormat(rawValue: raw) else { return }
        format = f
        onChange?(f)
    }
}

/// Gives the chosen sharing service the note's title as its subject (used by Mail).
private final class ShareSubjectDelegate: NSObject, NSSharingServicePickerDelegate {
    var subject = ""

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        service?.subject = subject
    }
}

/// `sharingServices(forItems:)` is deprecated in favour of the picker's standard menu item, which SwiftUI
/// menus can't host; calling it through a protocol keeps the File › Share submenu without a warning.
private protocol SharingServiceLookup {
    static func sharingServices(forItems items: [Any]) -> [NSSharingService]
}

extension NSSharingService: SharingServiceLookup {}

/// The toolbar Share button. The picker is shown below it.
struct ShareToolbarButton: View {
    let note: NoteMeta
    @State private var anchor = ViewAnchor()

    var body: some View {
        Button {
            if let view = anchor.view { ExportActions.showSharePicker(for: note, relativeTo: view) }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .background(AnchorView(anchor: anchor))
        .help("Share")
    }
}

final class ViewAnchor {
    weak var view: NSView?
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
