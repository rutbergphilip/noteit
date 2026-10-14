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

    private static var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    /// The note's saved body, including edits still waiting in the editor.
    static func body(of note: NoteMeta) -> NSAttributedString {
        NotificationCenter.default.post(name: .noteItWillExportNote, object: note.id)
        return store.body(for: note.id)
    }

    static func markdown(of note: NoteMeta) -> String {
        MarkdownWriter.write(body(of: note), title: ExportNaming.sanitized(note.displayTitle)).markdown
    }

    // MARK: Copy as Markdown

    /// Copies the editor's selection, or the whole note when nothing is selected.
    static func copyAsMarkdown() {
        guard let note = currentNote else { return }
        let title = ExportNaming.sanitized(note.displayTitle)
        let markdown: String
        if let textView = window?.firstResponder as? NoteItTextView, textView.selectedRange().length > 0 {
            let selection = textView.attributedString().attributedSubstring(from: textView.selectedRange())
            markdown = MarkdownWriter.write(selection, title: title).markdown
        } else {
            markdown = MarkdownWriter.write(body(of: note), title: title).markdown
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("net.daringfireball.markdown")], owner: nil)
        pasteboard.setString(markdown, forType: .string)
        pasteboard.setString(markdown, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
    }

    // MARK: Print

    static func printCurrentNote() {
        guard let note = currentNote else { return }
        let operation = NoteExporter.printOperation(body(of: note), title: note.displayTitle)
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
        service.subject = note.displayTitle
        service.perform(withItems: [markdown(of: note)])
    }

    static func showSharePicker(for note: NoteMeta, relativeTo view: NSView) {
        shareDelegate.subject = note.displayTitle
        let picker = NSSharingServicePicker(items: [markdown(of: note)])
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
            do {
                try NoteExporter.write(body(of: note), title: note.displayTitle, format: format, to: url)
            } catch {
                showError(error, message: "Couldn’t export “\(note.displayTitle)”")
            }
        }
    }

    static func exportCurrentNotebook() {
        guard let notebook = currentNotebook else { return }
        chooseFolder(title: "Export “\(notebook.name)”") { folder, format in
            try NoteExporter.exportNotebook(notebook, notes: store.notes, format: format, to: folder, body: body(ofNoteWith:))
        }
    }

    static func exportAllNotes() {
        chooseFolder(title: "Export All Notes") { folder, format in
            try NoteExporter.exportAll(notebooks: store.sortedNotebooks, notes: store.notes, format: format, to: folder,
                                       body: body(ofNoteWith:))
        }
    }

    private static func body(ofNoteWith id: UUID) -> NSAttributedString {
        NotificationCenter.default.post(name: .noteItWillExportNote, object: id)
        return store.body(for: id)
    }

    private static func chooseFolder(title: String, export: @escaping (URL, ExportFormat) throws -> NoteExporter.Result) {
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
                let result = try export(folder, format)
                showCompletion(result)
            } catch {
                showError(error, message: "Couldn’t export the notes")
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

    private static func showCompletion(_ result: NoteExporter.Result) {
        let alert = NSAlert()
        alert.messageText = result.noteCount == 1 ? "Exported 1 note" : "Exported \(result.noteCount) notes"
        alert.informativeText = "They’re in “\(result.folder.lastPathComponent)”."
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

    private static func showError(_ error: Error, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
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
