import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown, html, pdf, rtfd, plainText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .html: "HTML"
        case .pdf: "PDF"
        case .rtfd: "Rich Text (RTFD)"
        case .plainText: "Plain Text"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        case .pdf: "pdf"
        case .rtfd: "rtfd"
        case .plainText: "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        case .html: .html
        case .pdf: .pdf
        case .rtfd: .rtfd
        case .plainText: .plainText
        }
    }
}

/// File names for exported notes, notebooks and assets.
enum ExportNaming {
    static let maxLength = 120

    /// `name` without characters that are unsafe in file names on macOS and other systems.
    static func sanitized(_ name: String, fallback: String = "Untitled") -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|\u{FFFC}")
        let spaces = CharacterSet.controlCharacters.union(.newlines).union(CharacterSet(charactersIn: "\u{2028}\u{2029}"))
        var s = String(String.UnicodeScalarView(name.unicodeScalars.compactMap {
            unsafe.contains($0) ? nil : spaces.contains($0) ? " " : $0
        }))
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > maxLength { s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? fallback : s
    }

    /// A file name `base[.ext]`, or `base 2[.ext]`, `base 3[.ext]`… if that's already in `taken`.
    /// Names are compared case-insensitively, as on APFS.
    static func unique(_ base: String, extension ext: String, taken: inout Set<String>) -> String {
        func name(_ n: Int) -> String {
            let stem = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var n = 1
        while taken.contains(name(n).lowercased()) { n += 1 }
        taken.insert(name(n).lowercased())
        return name(n)
    }

    /// Like `unique`, also avoiding names that already exist in `folder`.
    static func uniqueOnDisk(_ base: String, extension ext: String, in folder: URL) -> String {
        var taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        return unique(base, extension: ext, taken: &taken)
    }
}

/// Writes notes to files: one note in any format, or whole notebooks as one folder per notebook.
@MainActor
enum NoteExporter {
    static let allNotesFolderName = "NoteIt Export"
    static let noNotebookFolderName = "No Notebook"

    /// The notes that get exported: everything except notes in Recently Deleted.
    static func exportableNotes(in notes: [NoteMeta]) -> [NoteMeta] {
        notes.filter { $0.deletedAt == nil }
    }

    // MARK: One note

    /// Writes `body` to `url` (which includes the extension). Markdown images and files go in a
    /// `<file name> assets` folder next to it, or `<file name> assets 2`… if that name is taken, so
    /// nothing already on disk is replaced.
    static func write(_ body: NSAttributedString, title: String, format: ExportFormat, to url: URL,
                      links: ExportLinkContext = .titlesOnly) throws {
        switch format {
        case .markdown:
            let parent = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            var assetsName = MarkdownWriter.assetsFolderName(for: base)
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(assetsName).path) {
                assetsName = ExportNaming.uniqueOnDisk(assetsName, extension: "", in: parent)
            }
            let export = MarkdownWriter.write(body, assetsFolder: assetsName, links: links)
            if !export.assets.isEmpty {
                let folder = parent.appendingPathComponent(assetsName, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for asset in export.assets {
                    try asset.data.write(to: folder.appendingPathComponent(asset.filename), options: .atomic)
                }
            }
            try Data(export.markdown.utf8).write(to: url, options: .atomic)
        case .html:
            try Data(BodyCodec.html(of: body, title: title, links: links).utf8).write(to: url, options: .atomic)
        case .pdf:
            try pdfData(body, title: title).write(to: url, options: .atomic)
        case .rtfd:
            let wrapper = try body.fileWrapper(from: NSRange(location: 0, length: body.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        case .plainText:
            try Data(plainText(body).utf8).write(to: url, options: .atomic)
        }
    }

    /// Plain text with list markers as `- `, `1. `, `☐ ` and `☑ `, and tables as tab-separated rows.
    static func plainText(_ body: NSAttributedString) -> String {
        BodyCodec.plainText(of: body)
    }

    // MARK: Notebooks

    struct Result {
        /// The folder that was created.
        var folder: URL
        /// Notes written. Less than `totalCount` when the export was stopped.
        var noteCount: Int
        var totalCount: Int
    }

    /// Writes one notebook as a folder named after it, inside `destination`.
    static func exportNotebook(_ notebook: Notebook, notes: [NoteMeta], format: ExportFormat, to destination: URL,
                               body: @escaping (UUID) -> NSAttributedString) throws -> Result {
        try prepareNotebook(notebook, notes: notes, format: format, to: destination, body: body).writeAll()
    }

    /// Writes every notebook as a folder inside a new `NoteIt Export` folder in `destination`.
    /// Notes without a notebook go in `No Notebook`.
    static func exportAll(notebooks: [Notebook], notes: [NoteMeta], format: ExportFormat, to destination: URL,
                          body: @escaping (UUID) -> NSAttributedString) throws -> Result {
        try prepareAll(notebooks: notebooks, notes: notes, format: format, to: destination, body: body).writeAll()
    }

    /// Creates the notebook's folder and returns the export, ready to write its notes.
    static func prepareNotebook(_ notebook: Notebook, notes: [NoteMeta], format: ExportFormat, to destination: URL,
                                body: @escaping (UUID) -> NSAttributedString) throws -> NotesExport {
        let name = ExportNaming.uniqueOnDisk(ExportNaming.sanitized(notebook.name, fallback: "Notebook"), extension: "", in: destination)
        let folder = destination.appendingPathComponent(name, isDirectory: true)
        let notebookNotes = exportableNotes(in: notes).filter { $0.notebookID == notebook.id }
        let files = try prepareFolder(folder, notes: notebookNotes, format: format)
        return NotesExport(folder: folder, format: format, files: files, body: body, links: linkContext(files, notes: notes))
    }

    /// Creates the `NoteIt Export` folder and a folder per notebook, and returns the export, ready to
    /// write the notes.
    static func prepareAll(notebooks: [Notebook], notes: [NoteMeta], format: ExportFormat, to destination: URL,
                           body: @escaping (UUID) -> NSAttributedString) throws -> NotesExport {
        let root = destination.appendingPathComponent(
            ExportNaming.uniqueOnDisk(allNotesFolderName, extension: "", in: destination), isDirectory: true)
        let allNotes = notes
        let notes = exportableNotes(in: notes)
        let notebookIDs = Set(notebooks.map(\.id))
        var groups: [(name: String, notes: [NoteMeta])] = notebooks.map { nb in
            (ExportNaming.sanitized(nb.name, fallback: "Notebook"), notes.filter { $0.notebookID == nb.id })
        }
        let loose = notes.filter { $0.notebookID.map { !notebookIDs.contains($0) } ?? true }
        if !loose.isEmpty { groups.append((noNotebookFolderName, loose)) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var taken = Set<String>()
        var files: [NotesExport.File] = []
        for group in groups {
            let folder = root.appendingPathComponent(ExportNaming.unique(group.name, extension: "", taken: &taken), isDirectory: true)
            files += try prepareFolder(folder, notes: group.notes, format: format)
        }
        return NotesExport(folder: root, format: format, files: files, body: body, links: linkContext(files, notes: allNotes))
    }

    /// Links to notes in the same export use their planned file names; other links use titles.
    private static func linkContext(_ files: [NotesExport.File], notes: [NoteMeta]) -> ExportLinkContext {
        .files(files, titles: Dictionary(notes.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Creates `folder` and names one file per note, oldest first, so the first of several same-named
    /// notes keeps the plain name.
    private static func prepareFolder(_ folder: URL, notes: [NoteMeta], format: ExportFormat) throws -> [NotesExport.File] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var taken = Set<String>()
        let ordered = notes.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return ordered.map { note in
            let name = ExportNaming.unique(ExportNaming.sanitized(note.displayTitle), extension: format.fileExtension, taken: &taken)
            if format == .markdown {
                taken.insert(MarkdownWriter.assetsFolderName(for: (name as NSString).deletingPathExtension).lowercased())
            }
            return NotesExport.File(note: note, url: folder.appendingPathComponent(name))
        }
    }

    // MARK: PDF and printing

    /// Letter or A4 from the user's print settings, with 1-inch margins.
    static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 72
        info.bottomMargin = 72
        info.leftMargin = 72
        info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// A text view laid out for one page width, drawn like the editor (checkboxes, code blocks, quotes, dividers)
    /// in light appearance.
    static func printView(for body: NSAttributedString, printInfo info: NSPrintInfo) -> NSTextView {
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let storage = NSTextStorage(attributedString: body)
        let full = NSRange(location: 0, length: storage.length)
        // Fresh attachments, so fitting images to the page doesn't resize the ones shown in the editor.
        storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
            guard let wrapper = (value as? NSTextAttachment)?.fileWrapper else { return }
            storage.addAttribute(.attachment, value: NSTextAttachment(fileWrapper: wrapper), range: range)
        }
        NoteItTextView.normalize(storage, around: full, chromeInsets: true)
        NoteItTextView.fitAttachments(in: storage, range: full, maxWidth: width)
        let layoutManager = NoteItLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        view.appearance = NSAppearance(named: .aqua)
        view.isEditable = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: width, height: 0)
        view.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainerInset = .zero
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        layoutManager.ensureLayout(for: container)
        view.sizeToFit()
        let used = layoutManager.usedRect(for: container)
        view.setFrameSize(NSSize(width: width, height: ceil(max(used.height, 1))))
        return view
    }

    static func pdfData(_ body: NSAttributedString, title: String) -> Data {
        let info = printInfo()
        let view = printView(for: body, printInfo: info)
        let data = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        var result = Data()
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            operation.run()
            result = data as Data
        }
        return result
    }

    static func printOperation(_ body: NSAttributedString, title: String) -> NSPrintOperation {
        let info = printInfo()
        let operation = NSPrintOperation(view: printView(for: body, printInfo: info), printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }
}

/// An export of many notes whose folders are already created. Notes are written one at a time, so
/// a large export can run in slices on the main thread and be stopped part way.
@MainActor
final class NotesExport {
    struct File {
        var note: NoteMeta
        var url: URL
    }

    let folder: URL
    let format: ExportFormat
    private let files: [File]
    private let body: (UUID) -> NSAttributedString
    private let links: ExportLinkContext
    private(set) var written = 0

    init(folder: URL, format: ExportFormat, files: [File], body: @escaping (UUID) -> NSAttributedString,
         links: ExportLinkContext = .titlesOnly) {
        self.folder = folder
        self.format = format
        self.files = files
        self.body = body
        self.links = links
    }

    var total: Int { files.count }
    var isFinished: Bool { written == files.count }
    var result: NoteExporter.Result { .init(folder: folder, noteCount: written, totalCount: total) }

    func writeNext() throws {
        guard !isFinished else { return }
        let file = files[written]
        try NoteExporter.write(body(file.note.id), title: file.note.displayTitle, format: format, to: file.url,
                               links: links.from(file.note.id))
        written += 1
    }

    func writeAll() throws -> NoteExporter.Result {
        while !isFinished { try writeNext() }
        return result
    }

    /// Writes the remaining notes in slices of about `slice`, letting the app handle events in between.
    /// `progress` is called after each slice; returning false stops the export, keeping what's written.
    func write(slice: Duration = .milliseconds(50), progress: (NotesExport) -> Bool) async throws -> NoteExporter.Result {
        let clock = ContinuousClock()
        while !isFinished {
            let start = clock.now
            repeat { try writeNext() } while !isFinished && clock.now - start < slice
            guard progress(self), !isFinished else { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return result
    }
}
