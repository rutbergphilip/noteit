import AppKit
import Foundation

/// The one body codec type, with no registry. Owned by the foundations plan (Task 4.2; program §6).
/// `rtfd` is the editor's NSAttributedString as RTFD libraries store it (an `.rtfd` package); `noteItDoc` is a
/// self-contained `.noteitdoc` file. markdown-storage adds `case markdown` in wave 1 with a branch in each switch.
///
/// Sync's body encoding: a `noteit-doc` body is built with `noteItDoc(of: text, extras: bodyExtras[id] ?? .empty)`
/// before sealing, and an incoming one is applied with `attributedString(from:)`, writing with the returned extras
/// and storing them in `bodyExtras[id]` only after the body is installed (Task 4.1). Wave 0 sync still sends RTFD.
enum BodyCodec: String, CaseIterable, Sendable {
    case rtfd
    case noteItDoc

    var fileExtension: String {
        switch self {
        case .rtfd: "rtfd"
        case .noteItDoc: "noteitdoc"
        }
    }

    /// `.rtfd` reads `extras` as `.empty`.
    func read(at url: URL) throws -> StoredBody {
        switch self {
        case .rtfd:
            return StoredBody(text: try RTFDBodyStorage.readBody(at: url))
        case .noteItDoc:
            return try Self.attributedString(from: BodyContainer.decode(Data(contentsOf: url)))
        }
    }

    /// Replaces `url` atomically. `.rtfd` ignores `extras`; `.noteItDoc` writes one file with the attachments and
    /// `extras` inside.
    func write(_ text: NSAttributedString, extras: ContainerExtras = .empty, to url: URL) throws {
        switch self {
        case .rtfd:
            let temp = try RTFDBodyStorage.writeTempBody(text, in: url.deletingLastPathComponent())
            try RTFDBodyStorage.installBody(temp, at: url)
        case .noteItDoc:
            try data(of: text, extras: extras).write(to: url, options: .atomic)
        }
    }

    /// The bytes `write(_:extras:to:)` stores; for `.rtfd`, the package's flat-file serialization.
    func data(of text: NSAttributedString, extras: ContainerExtras = .empty) throws -> Data {
        switch self {
        case .rtfd:
            guard let data = text.rtfd(from: NSRange(location: 0, length: text.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        case .noteItDoc:
            return try Self.noteItDoc(of: text, extras: extras).encoded()
        }
    }

    // MARK: Format-independent

    /// Plain text with list markers as `- `, `1. `, `☐ ` and `☑ `, and tables as tab-separated rows.
    @MainActor
    static func plainText(of text: NSAttributedString) -> String {
        var lines: [String] = []
        for block in NoteBlocks.parse(text) {
            switch block {
            case .paragraph(_, _, let runs):
                lines.append(plainLine(runs))
            case .listItem(let marker, let level, _, let runs):
                let prefix: String
                switch marker {
                case .bullet: prefix = "- "
                case .numbered(let n): prefix = "\(n). "
                case .checkbox(let checked): prefix = (checked ? EditorStyle.checkedBox : EditorStyle.uncheckedBox) + " "
                }
                lines.append(String(repeating: "  ", count: level) + prefix + plainLine(runs))
            case .code(let code, _):
                lines.append(code)
            case .divider:
                lines.append("---")
            case .table(let rows):
                lines.append(rows.map { $0.map { plainLine($0).replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n"))
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    @MainActor
    private static func plainLine(_ runs: [InlineRun]) -> String {
        NoteBlocks.plainText(runs).replacingOccurrences(of: NoteBlocks.lineBreak, with: "\n")
            .trimmingCharacters(in: .whitespaces)
    }

    @MainActor
    static func html(of text: NSAttributedString, title: String) -> String {
        HTMLWriter.write(text, title: title)
    }

    // MARK: noteit-doc container

    /// The container's `extras` are `extras`.
    static func noteItDoc(of text: NSAttributedString, extras: ContainerExtras = .empty,
                          imagePolicy: ImagePolicy = .normalize) throws -> BodyContainer {
        var container = try DocConverter.export(text, styles: AppDocStyleProvider.shared, imagePolicy: imagePolicy)
        container.extras = extras
        return container
    }

    /// `extras` are the container's.
    static func attributedString(from container: BodyContainer) throws -> StoredBody {
        StoredBody(text: try DocConverter.importDocument(container, styles: AppDocStyleProvider.shared),
                   extras: container.extras)
    }

    /// True when both texts export to the same noteit-doc bytes.
    static func semanticallyEqual(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        guard let left = try? noteItDoc(of: a).encoded(), let right = try? noteItDoc(of: b).encoded() else { return false }
        return left == right
    }
}
