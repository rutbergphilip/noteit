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
    /// `<file name> assets` folder next to it.
    static func write(_ body: NSAttributedString, title: String, format: ExportFormat, to url: URL) throws {
        switch format {
        case .markdown:
            let base = url.deletingPathExtension().lastPathComponent
            let export = MarkdownWriter.write(body, title: base)
            if !export.assets.isEmpty {
                let folder = url.deletingLastPathComponent().appendingPathComponent(MarkdownWriter.assetsFolderName(for: base), isDirectory: true)
                try replaceFolder(folder)
                for asset in export.assets {
                    try asset.data.write(to: folder.appendingPathComponent(asset.filename), options: .atomic)
                }
            }
            try Data(export.markdown.utf8).write(to: url, options: .atomic)
        case .html:
            try Data(HTMLWriter.write(body, title: title).utf8).write(to: url, options: .atomic)
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

    /// An existing assets folder belongs to the file being replaced; it goes to the Trash.
    private static func replaceFolder(_ folder: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            do {
                try fm.trashItem(at: folder, resultingItemURL: nil)
            } catch {
                try fm.removeItem(at: folder)
            }
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Plain text with list markers as `- `, `1. `, `☐ ` and `☑ `, and tables as tab-separated rows.
    static func plainText(_ body: NSAttributedString) -> String {
        var lines: [String] = []
        for block in NoteBlocks.parse(body) {
            switch block {
            case .paragraph(_, _, let runs):
                lines.append(text(runs))
            case .listItem(let marker, let level, _, let runs):
                let prefix: String
                switch marker {
                case .bullet: prefix = "- "
                case .numbered(let n): prefix = "\(n). "
                case .checkbox(let checked): prefix = (checked ? EditorStyle.checkedBox : EditorStyle.uncheckedBox) + " "
                }
                lines.append(String(repeating: "  ", count: level) + prefix + text(runs))
            case .code(let code):
                lines.append(code)
            case .divider:
                lines.append("---")
            case .table(let rows):
                lines.append(rows.map { $0.map { text($0).replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n"))
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func text(_ runs: [InlineRun]) -> String {
        NoteBlocks.plainText(runs).replacingOccurrences(of: NoteBlocks.lineBreak, with: "\n")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Notebooks

    struct Result {
        /// The folder that was created.
        var folder: URL
        var noteCount: Int
    }

    /// Writes one notebook as a folder named after it, inside `destination`.
    static func exportNotebook(_ notebook: Notebook, notes: [NoteMeta], format: ExportFormat, to destination: URL,
                               body: (UUID) -> NSAttributedString) throws -> Result {
        let name = ExportNaming.uniqueOnDisk(ExportNaming.sanitized(notebook.name, fallback: "Notebook"), extension: "", in: destination)
        let folder = destination.appendingPathComponent(name, isDirectory: true)
        let notebookNotes = exportableNotes(in: notes).filter { $0.notebookID == notebook.id }
        try writeFolder(folder, notes: notebookNotes, format: format, body: body)
        return Result(folder: folder, noteCount: notebookNotes.count)
    }

    /// Writes every notebook as a folder inside a new `NoteIt Export` folder in `destination`.
    /// Notes without a notebook go in `No Notebook`.
    static func exportAll(notebooks: [Notebook], notes: [NoteMeta], format: ExportFormat, to destination: URL,
                          body: (UUID) -> NSAttributedString) throws -> Result {
        let root = destination.appendingPathComponent(
            ExportNaming.uniqueOnDisk(allNotesFolderName, extension: "", in: destination), isDirectory: true)
        let notes = exportableNotes(in: notes)
        let notebookIDs = Set(notebooks.map(\.id))
        var groups: [(name: String, notes: [NoteMeta])] = notebooks.map { nb in
            (ExportNaming.sanitized(nb.name, fallback: "Notebook"), notes.filter { $0.notebookID == nb.id })
        }
        let loose = notes.filter { $0.notebookID.map { !notebookIDs.contains($0) } ?? true }
        if !loose.isEmpty { groups.append((noNotebookFolderName, loose)) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var taken = Set<String>()
        for group in groups {
            let folder = root.appendingPathComponent(ExportNaming.unique(group.name, extension: "", taken: &taken), isDirectory: true)
            try writeFolder(folder, notes: group.notes, format: format, body: body)
        }
        return Result(folder: root, noteCount: groups.reduce(0) { $0 + $1.notes.count })
    }

    /// One file per note, oldest first, so the first of several same-named notes keeps the plain name.
    private static func writeFolder(_ folder: URL, notes: [NoteMeta], format: ExportFormat, body: (UUID) -> NSAttributedString) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var taken = Set<String>()
        let ordered = notes.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        for note in ordered {
            let name = ExportNaming.unique(ExportNaming.sanitized(note.displayTitle), extension: format.fileExtension, taken: &taken)
            if format == .markdown {
                taken.insert(MarkdownWriter.assetsFolderName(for: (name as NSString).deletingPathExtension).lowercased())
            }
            try write(body(note.id), title: note.displayTitle, format: format, to: folder.appendingPathComponent(name))
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
        NoteItTextView.normalize(storage, around: full)
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
