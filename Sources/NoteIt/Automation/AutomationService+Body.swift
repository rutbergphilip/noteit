import AppKit
import Foundation
import NoteItAPI
import NoteItDoc
import NoteItMarkdown
import UniformTypeIdentifiers

/// Body reads and writes. Markdown goes through `NoteItMarkdown`, `noteit-doc` through `DocConverter`, HTML
/// through `HTMLWriter`; every change goes through `NoteStore.editBody`.
extension AutomationService {
    static let attachmentScheme = "noteit-attachment:"

    /// `sameNote`: a note whose own attachments `noteit-attachment:<noteID>/<name>` may refer to, as in Markdown
    /// read from it. Staged uploads (`noteit-attachment:att_…`) always resolve; any other path is dropped unread.
    func attributedBody(from text: String, format: BodyFormatDTO,
                        sameNote: UUID? = nil) throws(AutomationError) -> NSAttributedString {
        guard text.utf8.count <= Self.maxTextBytes else { throw .tooLarge }
        switch format {
        case .text:
            return NoteStore.capturedText(title: "", body: text)
        case .markdown:
            let parsed: ParsedMarkdown
            do { parsed = try MarkdownCodec.parse(text) } catch { throw .invalidInput("That Markdown couldn't be read.") }
            let attachments = sameNote.flatMap { id in store.note(with: id)?.isLocked == false ? attachmentFiles(of: id) : nil } ?? []
            let imported = MarkdownCodec.resolvingAttachments(parsed) { path in
                self.attachmentData(for: path, sameNote: sameNote, attachments: attachments)
            }
            do {
                return try BodyCodec.attributedString(from: imported.body).text
            } catch {
                throw .invalidInput("That Markdown couldn't be read.")
            }
        case .noteitDoc:
            do {
                let container = try BodyContainer.decode(Data(text.utf8))
                return try BodyCodec.attributedString(from: container).text
            } catch {
                throw .invalidInput("That noteit-doc body couldn't be read.")
            }
        case .html:
            throw .formatUnavailable(format.rawValue)
        }
    }

    func bodyString(of id: UUID, format: BodyFormatDTO) throws(AutomationError) -> String {
        let meta = try existing(id)
        if meta.isLocked { throw .noteLocked }
        let text = store.body(for: id)
        if let folder = store.unreadMarkdownFolder(of: id) { throw .folderNotAvailable(folder) }
        switch format {
        case .text:
            return store.plainText(for: id)
        case .html:
            return BodyCodec.html(of: text, title: meta.displayTitle)
        case .markdown:
            do {
                let container = try BodyCodec.noteItDoc(of: text)
                return MarkdownCodec.serialize(container, frontMatter: .empty, profile: .portable, attachmentPath: { sha in
                    Self.attachmentScheme + id.uuidString + "/" + (container.attachments[sha]?.name ?? sha)
                }, previous: nil)
            } catch {
                throw .noteUnreadable
            }
        case .noteitDoc:
            do {
                return String(decoding: try BodyCodec.noteItDoc(of: text).encoded(), as: UTF8.self)
            } catch {
                throw .noteUnreadable
            }
        }
    }

    func edit(_ id: UUID, actionName: String, versioning: EditBodyVersioning,
              _ change: (NSMutableAttributedString) throws -> Void) throws(AutomationError) {
        let meta = try existing(id)
        if meta.deletedAt != nil { throw .noteDeleted }
        if store.isBodyWriteBlocked(id) { throw .noteUnreadable }
        if meta.isLocked { throw .noteLocked }
        do {
            try store.editBody(id, actionName: actionName, versioning: versioning, change)
        } catch let error as BodyEditError {
            switch error {
            case .noteMissing: throw .notFound
            case .inTrash: throw .noteDeleted
            case .locked: throw .noteLocked
            case .writeBlocked, .taskChanged: throw .noteUnreadable
            case .versionNotSaved: throw .versionNotSaved
            case .folderNotAvailable(let folder): throw .folderNotAvailable(folder)
            }
        } catch let error as AutomationError {
            throw error
        } catch {
            throw .noteUnreadable
        }
    }

    /// The first paragraph becomes `title`, keeping the attributes of its first character.
    func setTitle(_ id: UUID, _ title: String) throws(AutomationError) {
        let line = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard line.utf8.count <= Self.maxTextBytes else { throw .tooLarge }
        try edit(id, actionName: "Set Title", versioning: .none) { storage in
            let string = storage.string as NSString
            let paragraph = string.paragraphRange(for: NSRange(location: 0, length: 0))
            var first = paragraph
            while first.length > 0, let scalar = UnicodeScalar(string.character(at: NSMaxRange(first) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                first.length -= 1
            }
            let attributes = first.length > 0
                ? storage.attributes(at: 0, effectiveRange: nil)
                : NoteStore.capturedText(title: "x", body: "").attributes(at: 0, effectiveRange: nil)
            storage.replaceCharacters(in: first, with: NSAttributedString(string: line, attributes: attributes))
        }
    }

    /// `.end` adds a new last paragraph; `.start` adds one right after the first (the title) paragraph.
    static func insert(_ addition: NSAttributedString, into storage: NSMutableAttributedString, at position: AppendPosition) {
        let piece = NSMutableAttributedString(attributedString: addition)
        while piece.string.hasSuffix("\n") { piece.deleteCharacters(in: NSRange(location: piece.length - 1, length: 1)) }
        let newline = { (index: Int) -> NSAttributedString in
            let attributes = piece.length > 0 ? piece.attributes(at: index, effectiveRange: nil) : [:]
            return NSAttributedString(string: "\n", attributes: attributes)
        }
        let string = storage.string as NSString
        switch position {
        case .end:
            if storage.length > 0, !storage.string.hasSuffix("\n") { piece.insert(newline(0), at: 0) }
            storage.append(piece)
        case .start:
            let firstBreak = string.rangeOfCharacter(from: .newlines)
            if firstBreak.location == NSNotFound {
                if storage.length > 0 { piece.insert(newline(0), at: 0) }
                storage.append(piece)
            } else {
                if piece.length > 0 { piece.append(newline(piece.length - 1)) }
                storage.insert(piece, at: NSMaxRange(firstBreak))
            }
        }
    }

    // MARK: Attachments

    func attachments(of id: UUID) throws(AutomationError) -> [AttachmentDTO] {
        try ensureReady()
        let meta = try existing(id)
        if meta.isLocked { throw .noteLocked }
        return attachmentFiles(of: id).map {
            AttachmentDTO(name: $0.name, contentType: Self.contentType(of: $0.name), size: $0.data.count)
        }
    }

    func attachment(of id: UUID, named name: String) throws(AutomationError) -> (contentType: String, data: Data) {
        try ensureReady()
        let meta = try existing(id)
        if meta.isLocked { throw .noteLocked }
        guard let file = attachmentFiles(of: id).first(where: { $0.name == name }) else { throw .notFound }
        return (Self.contentType(of: file.name), file.data)
    }

    func addAttachment(to id: UUID, data: Data, filename: String, contentType: String) throws(AutomationError) -> NoteMeta {
        try ensureReady()
        let meta = try existing(id)
        if meta.deletedAt != nil { throw .noteDeleted }
        if meta.isLocked { throw .noteLocked }
        guard !data.isEmpty else { throw .invalidInput("The attachment is empty.") }
        guard AttachmentLimit.allows(byteCount: data.count) else { throw .tooLarge }
        var name = Self.sanitizedFilename(filename)
        if (name as NSString).pathExtension.isEmpty, let ext = UTType(mimeType: contentType)?.preferredFilenameExtension {
            name += "." + ext
        }
        let unique = Self.deduplicated(name, existing: Set(attachmentFiles(of: id).map(\.name)))
        try edit(id, actionName: "Add Attachment", versioning: .none) { storage in
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = unique
            let piece = NSMutableAttributedString(attributedString: NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            if storage.length > 0 {
                let attributes = storage.attributes(at: storage.length - 1, effectiveRange: nil)
                piece.insert(NSAttributedString(string: "\n", attributes: attributes), at: 0)
            }
            storage.append(piece)
        }
        return visible(try existing(id))
    }

    static func sanitizedFilename(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.filter { $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(120))
        return limited.isEmpty || limited == "." || limited == ".." ? "attachment" : limited
    }

    static func deduplicated(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = base + " \(number)" + (ext.isEmpty ? "" : "." + ext)
            if !existing.contains(candidate) { return candidate }
            number += 1
        }
    }

    static func contentType(of name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private func attachmentFiles(of id: UUID) -> [(name: String, data: Data)] {
        let text = store.body(for: id)
        var files: [(name: String, data: Data)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let wrapper = (value as? NSTextAttachment)?.fileWrapper, wrapper.isRegularFile,
                  let data = wrapper.regularFileContents else { return }
            files.append((wrapper.preferredFilename ?? wrapper.filename ?? "attachment", data))
        }
        return files
    }

    private func attachmentData(for path: String, sameNote: UUID?,
                                attachments: [(name: String, data: Data)]) -> Data? {
        guard path.hasPrefix(Self.attachmentScheme) else { return nil }
        let reference = String(path.dropFirst(Self.attachmentScheme.count))
        if StagedUploads.isValidID(reference) { return staged.data(for: reference) }
        guard let sameNote, let slash = reference.firstIndex(of: "/"),
              UUID(uuidString: String(reference[..<slash])) == sameNote else { return nil }
        let name = String(reference[reference.index(after: slash)...])
        return attachments.first { $0.name == name }?.data
    }
}
