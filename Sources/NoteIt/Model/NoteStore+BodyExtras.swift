import AppKit
import Foundation

/// A point at which the `bodyWriteInterruption` test hook stops a body write and throws, leaving the files as a
/// crash there would (foundations Task 4.1).
enum BodyWriteStep: Sendable {
    case afterSidecarStage, afterBodyInstall
}

struct BodyWriteInterrupted: Error, Equatable {
    var step: BodyWriteStep
}

/// Something worth logging while reading a body-extras sidecar; also handed to `bodyExtrasNoticeHandler`.
enum BodyExtrasNotice: Equatable, Sendable {
    /// The sidecar exists but can't be read or decoded; writes to the note are blocked.
    case unreadable
    /// No entry matches the package on disk (it was changed outside NoteStore); `current` is used.
    case digestMismatch
    /// The text's code-paragraph count differs from the entry's, so no language ID was set.
    case codeCountMismatch(text: Int, entry: Int)
}

enum BodyExtrasError: Error, Equatable {
    case unreadableSidecar(UUID)
}

/// One body's extras in the body-extras sidecar. Owned by the foundations plan (Task 4.1). `codeLanguageIDs` has one
/// entry per code paragraph in document order: its `noteItCodeLanguageID` at write time, or nil. `bodySHA256` is
/// `RTFDBodyStorage.packageDigest` of the `.rtfd` package the entry belongs to.
struct BodyExtrasEntry: Equatable, Sendable {
    var bodySHA256: String
    var extras: ContainerExtras
    var codeLanguageIDs: [String?]

    var isEmpty: Bool { extras == .empty && codeLanguageIDs.allSatisfy { $0 == nil } }

    var json: JSONValue {
        var extrasMembers: [String: JSONValue] = ["extra": .object(extras.extra)]
        if let frontMatter = extras.frontMatter { extrasMembers["frontMatter"] = .string(frontMatter) }
        return .object([
            "bodySHA256": .string(bodySHA256),
            "extras": .object(extrasMembers),
            "codeLanguageIDs": .array(codeLanguageIDs.map { $0.map(JSONValue.string) ?? .null }),
        ])
    }

    init(bodySHA256: String, extras: ContainerExtras, codeLanguageIDs: [String?]) {
        self.bodySHA256 = bodySHA256
        self.extras = extras
        self.codeLanguageIDs = codeLanguageIDs
    }

    init(json: JSONValue) throws {
        guard case .object(let members) = json,
              case .string(let digest)? = members["bodySHA256"],
              case .object(let extrasMembers)? = members["extras"],
              case .array(let ids)? = members["codeLanguageIDs"] else {
            throw DocDecodingError("body extras: malformed entry")
        }
        var extras = ContainerExtras()
        switch extrasMembers["frontMatter"] {
        case nil, .null?: break
        case .string(let value)?: extras.frontMatter = value
        default: throw DocDecodingError("body extras: frontMatter must be a string")
        }
        switch extrasMembers["extra"] {
        case nil: break
        case .object(let extra)?: extras.extra = extra
        default: throw DocDecodingError("body extras: extra must be an object")
        }
        bodySHA256 = digest
        self.extras = extras
        codeLanguageIDs = try ids.map { id -> String? in
            switch id {
            case .null: return nil
            case .string(let value): return value
            default: throw DocDecodingError("body extras: a code language ID must be a string or null")
            }
        }
    }
}

/// `<rootURL>/body-extras/<UUID>.json`: `{"current": Entry, "previous": Entry?}`. Owned by the foundations plan
/// (Task 4.1). `previous` is set only between steps 1 and 3 of a body write.
struct BodyExtrasSidecar: Equatable, Sendable {
    var current: BodyExtrasEntry
    var previous: BodyExtrasEntry?

    /// The matching entry, else current.
    func entry(forBodySHA256 digest: String) -> BodyExtrasEntry {
        matchingEntry(forBodySHA256: digest) ?? current
    }

    func matchingEntry(forBodySHA256 digest: String) -> BodyExtrasEntry? {
        if current.bodySHA256 == digest { return current }
        if let previous, previous.bodySHA256 == digest { return previous }
        return nil
    }

    func encoded() throws -> Data {
        var members: [String: JSONValue] = ["current": current.json]
        if let previous { members["previous"] = previous.json }
        return try JSONValue.object(members).encoded()
    }

    static func decode(_ data: Data) throws -> BodyExtrasSidecar {
        guard case .object(let members) = try JSONValue.decode(data), let current = members["current"] else {
            throw DocDecodingError("body extras: missing current")
        }
        let previous: BodyExtrasEntry?
        switch members["previous"] {
        case nil, .null?: previous = nil
        case let value?: previous = try BodyExtrasEntry(json: value)
        }
        return BodyExtrasSidecar(current: try BodyExtrasEntry(json: current), previous: previous)
    }
}

/// The body-extras sidecar, used only when `bodyStorage.kind == .rtfd`: an `.rtfd` package holds no extras and keeps
/// only known code languages, so NoteStore keeps both beside it. Owned by the foundations plan (Task 4.1).
extension NoteStore {
    var bodyExtrasDirectoryURL: URL { rootURL.appendingPathComponent("body-extras", isDirectory: true) }

    func bodyExtrasFileURL(_ id: UUID) -> URL {
        bodyExtrasDirectoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// nil removes the entry.
    func setBodyExtras(_ extras: ContainerExtras?, for id: UUID) {
        bodyExtras[id] = extras
    }

    /// The note's unknown front matter keys, also when its body isn't loaded.
    func storedFrontMatter(_ id: UUID) -> String? {
        if let extras = bodyExtras[id] { return extras.frontMatter }
        switch bodyStorage.kind {
        case .rtfd: return (try? readBodyExtrasSidecar(id))??.current.extras.frontMatter
        case .markdown:
            if let markdownStorage { return markdownStorage.index.entry(id)?.frontMatterExtra }
            return (try? BodyCodec.markdownFrontMatterExtra(at: bodyStorage.fileURL(for: id))) ?? nil
        }
    }

    /// The sidecar, or nil when there is none. Throws when it exists but can't be read or decoded.
    func readBodyExtrasSidecar(_ id: UUID) throws -> BodyExtrasSidecar? {
        let url = bodyExtrasFileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try BodyExtrasSidecar.decode(Data(contentsOf: url))
    }

    /// A temp file in `body-extras/`, then a rename over the old one.
    private func writeBodyExtrasSidecar(_ sidecar: BodyExtrasSidecar, for id: UUID) throws {
        let fm = FileManager.default
        let url = bodyExtrasFileURL(id)
        let temp = bodyExtrasDirectoryURL.appendingPathComponent(".\(UUID().uuidString).json.tmp")
        do {
            try fm.createDirectory(at: bodyExtrasDirectoryURL, withIntermediateDirectories: true)
            try sidecar.encoded().write(to: temp)
            guard rename(temp.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    func removeBodyExtrasFile(_ id: UUID) throws {
        let url = bodyExtrasFileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func noteBodyExtras(_ id: UUID, _ notice: BodyExtrasNotice, _ message: String) {
        NSLog("NoteIt: note \(id): \(message)")
        bodyExtrasNoticeHandler?(id, notice)
    }

    /// `bodyStorage.read`, plus on an RTFD store the sidecar: its extras and code language IDs. An unreadable
    /// sidecar sets `readOnlyReason` and leaves the extras empty; nothing is deleted or rewritten.
    func readStoredBody(_ id: UUID) throws -> StoredBody {
        var stored = try bodyStorage.read(id)
        guard bodyStorage.kind == .rtfd else { return stored }
        let sidecar: BodyExtrasSidecar?
        do {
            sidecar = try readBodyExtrasSidecar(id)
        } catch {
            noteBodyExtras(id, .unreadable, "its body-extras file is unreadable (\(error)); writes are disabled")
            stored.readOnlyReason = StoredBody.bodyExtrasUnreadable
            return stored
        }
        guard let sidecar else { return stored }
        let entry: BodyExtrasEntry
        if let digest = try? RTFDBodyStorage.packageDigest(at: bodyStorage.fileURL(for: id)),
           let match = sidecar.matchingEntry(forBodySHA256: digest) {
            entry = match
        } else {
            entry = sidecar.current
            noteBodyExtras(id, .digestMismatch, "its body changed outside NoteIt; using the latest body extras")
        }
        stored.extras = entry.extras
        stored.text = applyingCodeLanguageIDs(entry.codeLanguageIDs, to: stored.text, of: id)
        return stored
    }

    /// Sets the IDs on the code paragraphs by position, only when the counts match.
    private func applyingCodeLanguageIDs(_ ids: [String?], to text: NSAttributedString, of id: UUID) -> NSAttributedString {
        if let applied = Self.applyingCodeLanguageIDs(ids, to: text) { return applied }
        let count = Self.codeParagraphRanges(in: text).count
        noteBodyExtras(id, .codeCountMismatch(text: count, entry: ids.count),
                       "\(count) code paragraph(s) but \(ids.count) stored language ID(s); IDs dropped")
        return text
    }

    /// nil when the number of code paragraphs doesn't match `ids`.
    nonisolated static func applyingCodeLanguageIDs(_ ids: [String?], to text: NSAttributedString) -> NSAttributedString? {
        guard ids.contains(where: { $0 != nil }) else { return text }
        let ranges = codeParagraphRanges(in: text)
        guard ranges.count == ids.count else { return nil }
        let result = NSMutableAttributedString(attributedString: text)
        for (range, language) in zip(ranges, ids) {
            guard let language else { continue }
            result.addAttribute(.noteItCodeLanguageID, value: language, range: range)
        }
        return result
    }

    /// Paragraphs outside tables whose block kind is code, in document order (one codeBlock each, Task 2.3).
    nonisolated static func codeParagraphRanges(in text: NSAttributedString) -> [NSRange] {
        let ns = text.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(para)
            let ps = text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle
            if ps?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true { continue }
            if DocParagraphModel.blockKind(paragraphStyle: ps, font: nil, baseSize: 0) == .code { ranges.append(para) }
        }
        return ranges
    }

    nonisolated static func codeLanguageIDs(of text: NSAttributedString) -> [String?] {
        codeParagraphRanges(in: text).map { text.attribute(.noteItCodeLanguageID, at: $0.location, effectiveRange: nil) as? String }
    }

    /// Installs a temp package from `bodyStorage.prepareTemp`. On an RTFD store, in three steps: (1) the sidecar
    /// with `current` = the new entry and `previous` = the entry of the body on disk, (2) the body, (3) the sidecar
    /// without `previous`, or none when the new entry is empty. A failed step 1 throws before the body is touched
    /// and removes the temp; a failed step 3 is only logged.
    func installPreparedBody(_ temp: URL, text: NSAttributedString, extras: ContainerExtras, for meta: NoteMeta) throws {
        let fm = FileManager.default
        let id = meta.id
        let notebook = notebook(with: meta.notebookID)
        guard bodyStorage.kind == .rtfd else {
            try bodyStorage.installTemp(temp, for: meta, notebook: notebook)
            return
        }
        let entry: BodyExtrasEntry
        let existing: BodyExtrasSidecar?
        do {
            entry = BodyExtrasEntry(bodySHA256: try RTFDBodyStorage.packageDigest(at: temp), extras: extras,
                                    codeLanguageIDs: Self.codeLanguageIDs(of: text))
            do {
                existing = try readBodyExtrasSidecar(id)
            } catch {
                throw BodyExtrasError.unreadableSidecar(id)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        let staged = existing != nil || !entry.isEmpty
        if staged {
            var previous: BodyExtrasEntry?
            if let digest = try? RTFDBodyStorage.packageDigest(at: bodyStorage.fileURL(for: id)) {
                if let existing {
                    previous = existing.matchingEntry(forBodySHA256: digest)
                } else {
                    previous = BodyExtrasEntry(bodySHA256: digest, extras: .empty, codeLanguageIDs: [])
                }
            }
            do {
                try writeBodyExtrasSidecar(BodyExtrasSidecar(current: entry, previous: previous), for: id)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
        }
        if bodyWriteInterruption == .afterSidecarStage {
            try? fm.removeItem(at: temp)
            throw BodyWriteInterrupted(step: .afterSidecarStage)
        }
        try bodyStorage.installTemp(temp, for: meta, notebook: notebook)
        if bodyWriteInterruption == .afterBodyInstall { throw BodyWriteInterrupted(step: .afterBodyInstall) }
        guard staged else { return }
        do {
            if failsBodyExtrasFinish { throw CocoaError(.fileWriteUnknown) }
            if entry.isEmpty {
                try removeBodyExtrasFile(id)
            } else {
                try writeBodyExtrasSidecar(BodyExtrasSidecar(current: entry, previous: nil), for: id)
            }
        } catch {
            NSLog("NoteIt: note \(id) was saved, but finishing its body-extras file failed: \(error)")
        }
    }
}
