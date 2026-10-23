import CryptoKit
import Foundation

/// Whether a decoded container can be edited. Anything this build can't edit faithfully opens read-only.
/// Owned by the web-app plan; built in foundations Task 2.1, with the markdown-storage and `noteit:` link rules.
public enum DocValidation: Equatable, Sendable {
    case valid, readOnly(reason: String)

    /// Font sizes stay within 8–96 points. The base size depends on the block and the editor's font preference,
    /// so a delta no base in that range could bring back into it is rejected.
    static let fontSizeRange = 8...96
    static let fontSizeDeltaRange = (fontSizeRange.lowerBound - fontSizeRange.upperBound)...(fontSizeRange.upperBound - fontSizeRange.lowerBound)
    static let headingLevels = 1...3
    static let listLevels = 0...8
    static let indentLevels = 0...8

    public static func validate(_ c: BodyContainer) -> DocValidation {
        do {
            try check(c)
            return .valid
        } catch let failure as Failure {
            return .readOnly(reason: failure.reason)
        } catch {
            return .readOnly(reason: "\(error)")
        }
    }

    private struct Failure: Error {
        var reason: String
    }

    private static func check(_ c: BodyContainer) throws {
        guard c.format == BodyContainer.format else { throw Failure(reason: "Unknown format \(c.format)") }
        guard c.version <= BodyContainer.currentVersion else {
            throw Failure(reason: "Written by a newer version (format version \(c.version))")
        }
        for (key, attachment) in c.attachments {
            let digest = SHA256.hash(data: attachment.data).map { String(format: "%02x", $0) }.joined()
            guard key == digest else { throw Failure(reason: "Attachment \(attachment.name) doesn't match its key") }
        }
        guard case .doc(let blocks) = c.doc else { throw Failure(reason: "The document root isn't a doc node") }
        for block in blocks { try checkBlock(block) }
    }

    private static func checkBlock(_ node: DocNode) throws {
        switch node {
        case .doc:
            throw Failure(reason: "A doc node inside the document")
        case .paragraph(_, let indent, let content):
            try checkIndent(indent)
            try checkInlines(content)
        case .heading(let level, _, let indent, let content):
            guard headingLevels.contains(level) else { throw Failure(reason: "Heading level \(level) is out of range") }
            try checkIndent(indent)
            try checkInlines(content)
        case .codeBlock(_, _, let content):
            try checkInlines(content)
        case .blockquote(let indent, let content):
            try checkIndent(indent)
            try checkParagraphs(content)
        case .horizontalRule:
            break
        case .listItem(_, let level, _, _, _, let content):
            guard listLevels.contains(level) else { throw Failure(reason: "List level \(level) is out of range") }
            try checkInlines(content)
        case .table(let columnWidths, let rows):
            if let columnWidths {
                let columns = rows.map(\.count).max() ?? 0
                guard columnWidths.count == columns else {
                    throw Failure(reason: "The table has \(columns) columns but \(columnWidths.count) column widths")
                }
                for width in columnWidths { try checkWidth(width, of: "Column") }
            }
            for cell in rows.joined() { try checkParagraphs(cell.content) }
        case .unknown(let type, _):
            throw Failure(reason: "Unknown content \(type)")
        }
    }

    private static func checkParagraphs(_ nodes: [DocNode]) throws {
        for node in nodes {
            if case .unknown = node { try checkBlock(node) }
            guard case .paragraph = node else { throw Failure(reason: "Only paragraphs can be nested") }
            try checkBlock(node)
        }
    }

    private static func checkIndent(_ indent: Int?) throws {
        if let indent, !indentLevels.contains(indent) { throw Failure(reason: "Indent \(indent) is out of range") }
    }

    private static func checkInlines(_ content: [Inline]) throws {
        for inline in content {
            switch inline {
            case .text(_, let marks):
                for mark in marks { try checkMark(mark) }
            case .image(_, let name, _, let width):
                try checkName(name, of: "An image")
                if let width { try checkWidth(width, of: "Image") }
            case .attachment(_, let name, _):
                try checkName(name, of: "An attachment")
            case .hardBreak, .softBreak:
                break
            }
        }
    }

    private static func checkName(_ name: String, of item: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(reason: "\(item) has no name") }
    }

    private static func checkWidth(_ width: Double, of item: String) throws {
        guard width.isFinite, width > 0 else { throw Failure(reason: "\(item) width \(width) isn't a positive number") }
    }

    private static func checkMark(_ mark: Mark) throws {
        switch mark {
        case .textColor(let color), .highlight(let color):
            guard isColor(color) else { throw Failure(reason: "Colour \(color) isn't #RRGGBB") }
        case .fontSize(let delta):
            guard fontSizeDeltaRange.contains(delta) else { throw Failure(reason: "Font size change \(delta) is out of range") }
        case .link(let href):
            guard LinkPolicy.allows(href) else { throw Failure(reason: "Link \(href) isn't allowed") }
        case .bold, .italic, .underline, .strike, .code:
            break
        }
    }

    static func isColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}
