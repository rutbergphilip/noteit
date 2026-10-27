import Foundation
import NoteItCore

/// Title, preview, tags and plain text of a note, the same on the Mac (`NoteStore`, from the attributed string) and
/// on the web (`@noteit/doc` `derive.ts`, from the noteit-doc). Web-app spec §2.8; vectors in `fixtures/golden/derive.json`.
///
/// The string rules (`clean`, `titleAndPreview(lines:)`) are the ones `NoteStore` applies to its display lines;
/// the document functions build those lines from a noteit-doc as the converter would lay the note out as text.
public enum DocDerivation {
    public static let titleLength = 120
    public static let previewLength = 140

    /// U+2028, a line break inside a paragraph (`hardBreak` and `softBreak`).
    public static let lineBreak = "\u{2028}"
    /// U+FFFC, an image or attachment.
    public static let objectReplacement = "\u{FFFC}"
    /// U+00A0, the text of a divider paragraph.
    public static let divider = "\u{00A0}"
    static let bullets = ["•", "◦", "▪"]

    // MARK: Lines

    /// Drops attachment characters and control characters, turns tabs into spaces and trims.
    public static func clean(_ line: String) -> String {
        let visible = line.replacingOccurrences(of: objectReplacement, with: "")
            .replacingOccurrences(of: "\t", with: " ")
            .unicodeScalars.filter { $0.properties.generalCategory != .control }
        return String(String.UnicodeScalarView(visible))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Title: the first non-blank line, cleaned, up to `titleLength` characters; preview: the non-blank lines
    /// after it, cleaned and joined by a space, up to `previewLength` characters. Both empty for a blank note.
    public static func titleAndPreview(lines: [String]) -> (title: String, preview: String) {
        guard let first = lines.firstIndex(where: { !clean($0).isEmpty }) else { return ("", "") }
        let rest = lines[(first + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: " ")
        return (String(clean(lines[first]).prefix(titleLength)), String(rest.prefix(previewLength)))
    }

    // MARK: Documents

    /// Display lines: one per paragraph, list markers kept, each table collapsed into one line (cells of a row
    /// joined by " · ", rows by two spaces, a header row left out). Cleaned.
    public static func lines(of doc: DocNode) -> [String] {
        var lines: [String] = []
        for item in paragraphs(of: doc) {
            switch item {
            case .line(let runs):
                lines.append(clean(text(runs)))
            case .table(let rows):
                let collapsed = rows.filter { !$0.header }
                    .map { $0.cells.map { clean(text($0)) }.filter { !$0.isEmpty } }
                    .filter { !$0.isEmpty }
                    .map { $0.joined(separator: " · ") }
                if !collapsed.isEmpty { lines.append(collapsed.joined(separator: "  ")) }
            }
        }
        return lines
    }

    public static func titleAndPreview(of doc: DocNode) -> (title: String, preview: String) {
        titleAndPreview(lines: lines(of: doc))
    }

    /// The note's whole text as the Mac holds it: paragraphs (and table cells) joined by newlines, list markers,
    /// U+2028 line breaks and U+FFFC objects kept. Search reads this.
    public static func plainText(of doc: DocNode) -> String {
        flattened(doc).map { text($0) }.joined(separator: "\n")
    }

    /// `plainText` with code and link ranges blanked, as `NoteStore.maskedForTokens`; tags, due dates and
    /// reminders are read from it.
    /// The newline after a code block is blanked too: the Mac sets it in the code font.
    public static func maskedText(of doc: DocNode) -> String {
        let paragraphs = flattened(doc)
        return paragraphs.enumerated().map { index, runs in
            let separator = index == paragraphs.count - 1 ? "" : (runs.last?.code == true ? " " : "\n")
            return masked(runs) + separator
        }.joined()
    }

    /// Lowercased, de-duplicated in order, never inside code or links.
    public static func tags(of doc: DocNode) -> [String] {
        TokenGrammar.tags(inMasked: maskedText(of: doc).precomposedStringWithCanonicalMapping)
    }

    // MARK: Paragraph model

    struct Run {
        var text: String
        /// Code or link: left out of tag parsing.
        var masked: Bool
        /// In a code block, whose paragraph end the Mac also sets in the code font.
        var code = false
    }

    enum Item {
        case line([Run])
        case table([(header: Bool, cells: [[Run]])])
    }

    static func paragraphs(of doc: DocNode) -> [Item] {
        guard case .doc(let blocks) = doc else { return paragraphs(of: .doc([doc])) }
        var items: [Item] = []
        func add(_ block: DocNode) {
            switch block {
            case .doc(let content):
                content.forEach(add)
            case .paragraph(_, _, let content), .heading(_, _, _, let content):
                items.append(.line(runs(content, code: false)))
            case .codeBlock(_, _, let content):
                items.append(.line(codeRuns(content)))
            case .blockquote(_, let content):
                content.forEach(add)
            case .horizontalRule:
                items.append(.line([Run(text: divider, masked: false)]))
            case .listItem(let kind, let level, let number, let checked, _, let content):
                items.append(.line([Run(text: marker(kind, level: level, number: number, checked: checked), masked: false)]
                                   + runs(content, code: false)))
            case .table(_, let rows):
                items.append(.table(rows.enumerated().map { index, row in
                    (header: index == 0 && isHeaderRow(row), cells: row.flatMap { cell in cell.content.compactMap(cellRuns) })
                }))
            case .unknown:
                break
            }
        }
        blocks.forEach(add)
        return items
    }

    /// A table cell holds paragraphs only (the schema's rule).
    private static func cellRuns(_ node: DocNode) -> [Run]? {
        guard case .paragraph(_, _, let content) = node else { return nil }
        return runs(content, code: false)
    }

    /// The Mac leaves a table's first row out of the preview when one of its cells is a header (shaded), or when
    /// one of its non-blank paragraphs starts in a bold font.
    static func isHeaderRow(_ row: [TableCell]) -> Bool {
        row.contains { cell in
            cell.header || cell.content.contains { node in
                guard case .paragraph(_, _, let content) = node, !clean(text(runs(content, code: false))).isEmpty,
                      case .text(_, let marks)? = content.first else { return false }
                return marks.contains(.bold)
            }
        }
    }

    static func marker(_ kind: ListKind, level: Int, number: Int?, checked: Bool?) -> String {
        switch kind {
        case .bullet: return bullets[((level % 3) + 3) % 3] + "\t"
        case .ordered: return "\(number ?? 1).\t"
        case .task: return (checked == true ? "☑" : "☐") + "\t"
        }
    }

    /// A code block's runs end with an empty masked run, so even an empty one ends in code.
    static func codeRuns(_ content: [Inline]) -> [Run] {
        runs(content, code: true) + [Run(text: "", masked: true, code: true)]
    }

    static func runs(_ content: [Inline], code: Bool) -> [Run] {
        content.map { inline in
            switch inline {
            case .text(let string, let marks):
                let masked = code || marks.contains { mark in
                    if case .code = mark { return true }
                    if case .link = mark { return true }
                    return false
                }
                return Run(text: string, masked: masked, code: code)
            case .hardBreak, .softBreak:
                return Run(text: lineBreak, masked: code, code: code)
            case .image, .attachment:
                return Run(text: objectReplacement, masked: code, code: code)
            }
        }
    }

    /// Every paragraph, table cells one each.
    private static func flattened(_ doc: DocNode) -> [[Run]] {
        paragraphs(of: doc).flatMap { item -> [[Run]] in
            switch item {
            case .line(let runs): return [runs]
            case .table(let rows): return rows.flatMap(\.cells)
            }
        }
    }

    static func text(_ runs: [Run]) -> String {
        runs.map(\.text).joined()
    }

    private static func masked(_ runs: [Run]) -> String {
        // Blank by UTF-16 length, as the Mac masks NSString ranges.
        runs.map { $0.masked ? String(repeating: " ", count: $0.text.utf16.count) : $0.text }.joined()
    }
}
