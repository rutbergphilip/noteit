import Foundation
import NoteItDoc

/// Doc blocks → Markdown. Every block is written in the most readable form that reads back as the same block:
/// its unchanged source from the previous file, canonical Markdown, HTML tag forms, everything escaped, and last a
/// `<!-- noteit: doc=… -->` fallback with a plain rendering (library flavour only).
struct MarkdownWriter {
    enum Mode: Equatable {
        case preserved(String)
        case styled(Int)
        case fallback
    }

    struct Unit {
        /// More than one node only for consecutive plain code blocks written as one fence.
        var nodes: [DocNode]
        /// Empty paragraphs before this unit.
        var emptiesBefore: Int
        var mode: Mode = .styled(0)

        var isListItem: Bool {
            if case .listItem? = nodes.first { true } else { false }
        }

        var level: Int {
            if case .listItem(_, let level, _, _, _, _)? = nodes.first { level } else { 0 }
        }
    }

    struct Output {
        var text: String
        var units: Int
        var fallbacks: Int
    }

    private struct Placement {
        var levelHint = false
        var atFileStart = false
        var levelBase = 0
    }

    let profile: MarkdownProfile
    let noteLinkName: (UUID) -> String?
    /// The front matter written before the body; "" when none.
    let header: String
    let targets = NoteTargets()

    private var hasFrontMatter: Bool { !header.isEmpty }

    func write(_ blocks: [DocNode], previous: ParsedMarkdown?) -> Output {
        registerNoteLinks(in: blocks)
        var (units, trailing) = Self.units(of: blocks, profile: profile)
        if let previous {
            let texts = SourcePreservation.match(units.map(\.nodes), in: previous)
            for index in units.indices {
                if let text = texts[index] { units[index].mode = .preserved(text) }
            }
        }
        for index in units.indices where units[index].mode == .styled(0) {
            units[index].mode = standaloneMode(units[index])
        }
        if profile == .library {
            var attempts = units.count * 3 + 3
            var checks = 0
            let doublings = Int.bitWidth - units.count.leadingZeroBitCount + 1
            while attempts > 0, let bad = firstMismatch(units, trailing: trailing) {
                attempts -= 1
                checks += 1
                // Each check parses the whole document, so after a few single steps the steps widen: first to the
                // preserved units nearby, which only lose their original bytes, then to any unit.
                let widening = max(0, checks - 8)
                let width = 1 << min(widening <= doublings ? widening : widening - doublings, 30)
                guard degrade(&units, at: bad, width: width, onlyPreserved: widening <= doublings) else { break }
            }
        }
        let body = assemble(units, trailing: trailing).text
        return Output(text: body, units: units.count, fallbacks: units.filter { $0.mode == .fallback }.count)
    }

    // MARK: Units

    /// An unknown block is a fallback comment alone in `library` and dropped in `portable`.
    static func units(of blocks: [DocNode], profile: MarkdownProfile) -> ([Unit], Int) {
        var units: [Unit] = []
        var empties = 0
        for node in blocks {
            switch node {
            case BlockParser.emptyParagraph:
                empties += 1
                continue
            case .unknown where profile == .library:
                units.append(Unit(nodes: [node], emptiesBefore: empties, mode: .fallback))
                empties = 0
                continue
            case .unknown, .doc:
                continue
            default:
                break
            }
            if empties == 0, let last = units.last, isPlainCode(node), last.nodes.allSatisfy(isPlainCode),
               case .codeBlock(let align, let language, _) = node, case .codeBlock(align, language, _)? = last.nodes.first {
                units[units.count - 1].nodes.append(node)
                continue
            }
            units.append(Unit(nodes: [node], emptiesBefore: empties))
            empties = 0
        }
        return (units, empties)
    }

    private static func isPlainCode(_ node: DocNode) -> Bool {
        guard case .codeBlock(_, _, let content) = node else { return false }
        return content.allSatisfy { inline in
            if case .text(let text, let marks) = inline { return marks.isEmpty && !text.contains(where: { $0 == "\n" || $0 == "\r" }) }
            return false
        }
    }

    /// Every note link's target is claimed up front, so a later link with a clashing name becomes a Markdown link.
    private func registerNoteLinks(in blocks: [DocNode]) {
        func visit(_ content: [Inline]) {
            for case .text(_, let marks) in content {
                for case .link(let href) in marks {
                    if case .resolved(let id, _)? = WikiLink.noteHref(href), let name = noteLinkName(id) {
                        _ = targets.register(name, id)
                    }
                }
            }
        }
        blocks.forEach { MarkdownWriter.forEachContent(in: $0, visit) }
    }

    // MARK: Choosing a form

    private func standaloneMode(_ unit: Unit) -> Mode {
        if case .horizontalRule? = unit.nodes.first { return .styled(0) }
        let placement = Placement(levelHint: true, levelBase: profile == .portable ? unit.level : 0)
        let expected = profile == .portable ? unit.nodes.map { Self.withLevel($0, unit.level - placement.levelBase) } : unit.nodes
        for style in InlineStyle.all.indices {
            let text = render(unit, mode: .styled(style), placement)
            if let parsed = try? MarkdownCodec.parse(text, resolveNoteLink: targets.resolve), case .doc(let blocks) = parsed.body.doc,
               blocks == expected {
                return .styled(style)
            }
        }
        return .fallback
    }

    private static func withLevel(_ node: DocNode, _ level: Int) -> DocNode {
        guard case .listItem(let kind, _, let number, let checked, let align, let content) = node else { return node }
        return .listItem(kind: kind, level: max(0, level), number: number, checked: checked, align: align, content: content)
    }

    /// The unit at the first block that doesn't read back, or nil when the whole document does.
    private func firstMismatch(_ units: [Unit], trailing: Int) -> Int? {
        guard !units.isEmpty else { return nil }
        var expected: [(DocNode, Int)] = []
        for (index, unit) in units.enumerated() {
            expected += Array(repeating: (BlockParser.emptyParagraph, index), count: unit.emptiesBefore)
            expected += unit.nodes.map { ($0, index) }
        }
        expected += Array(repeating: (BlockParser.emptyParagraph, units.count - 1), count: trailing)
        let text = header + assemble(units, trailing: trailing).text
        guard let parsed = try? MarkdownCodec.parse(text, resolveNoteLink: targets.resolve),
              case .doc(let blocks) = parsed.body.doc else { return 0 }
        for index in 0..<min(blocks.count, expected.count) where blocks[index] != expected[index].0 {
            return expected[index].1
        }
        if blocks.count == expected.count { return nil }
        return blocks.count < expected.count ? expected[blocks.count].1 : units.count - 1
    }

    /// One step down for the unit at `index`, or for an earlier unit when this one is already a fallback; with a
    /// `width` above 1, also for up to that many more units on either side (only preserved ones if `onlyPreserved`).
    private func degrade(_ units: inout [Unit], at index: Int, width: Int, onlyPreserved: Bool) -> Bool {
        func canStep(_ target: Int) -> Bool {
            units[target].mode != .fallback && units[target].nodes.first != .horizontalRule
        }
        func isExtra(_ target: Int) -> Bool {
            guard canStep(target) else { return false }
            if !onlyPreserved { return true }
            if case .preserved = units[target].mode { return true }
            return false
        }
        var first = index
        while first >= 0, !canStep(first) { first -= 1 }
        guard first >= 0 else { return false }
        var targets = [first]
        var lower = first - 1
        while lower >= max(0, first - width + 1) {
            if isExtra(lower) { targets.append(lower) }
            lower -= 1
        }
        var upper = first + 1
        while upper < min(units.count, index + width) {
            if isExtra(upper) { targets.append(upper) }
            upper += 1
        }
        for target in targets.sorted(by: >) { step(&units, at: target) }
        return true
    }

    private func step(_ units: inout [Unit], at target: Int) {
        switch units[target].mode {
        case .preserved:
            units[target].mode = standaloneMode(units[target])
        case .styled, .fallback:
            let unit = units[target]
            let split = unit.nodes.enumerated().map { offset, node in
                Unit(nodes: [node], emptiesBefore: offset == 0 ? unit.emptiesBefore : 0, mode: .fallback)
            }
            units.replaceSubrange(target...target, with: split)
        }
    }

    // MARK: Assembly

    private func assemble(_ units: [Unit], trailing: Int) -> (text: String, lines: Int) {
        var lines: [String] = []
        var levelBase = 0
        for (index, unit) in units.enumerated() {
            let previousIsList = index > 0 && units[index - 1].isListItem
            let separator = index == 0 ? (hasFrontMatter ? 1 : 0) : (previousIsList && unit.isListItem ? 0 : 1)
            lines += Array(repeating: "", count: separator + unit.emptiesBefore)
            let runStart = unit.isListItem && !previousIsList
            if runStart { levelBase = unit.level }
            let placement = Placement(levelHint: runStart, atFileStart: !hasFrontMatter && lines.isEmpty,
                                      levelBase: profile == .portable ? levelBase : 0)
            lines += render(unit, mode: unit.mode, placement).components(separatedBy: "\n")
        }
        lines += Array(repeating: "", count: trailing + (units.isEmpty && hasFrontMatter && trailing > 0 ? 1 : 0))
        return (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n", lines.count)
    }

    // MARK: Rendering

    private func render(_ unit: Unit, mode: Mode, _ placement: Placement) -> String {
        switch mode {
        case .preserved(let text):
            return text
        case .styled(let style):
            return renderNative(unit, style: InlineStyle.all[style], placement).joined(separator: "\n")
        case .fallback:
            return renderFallback(unit.nodes[0], placement).joined(separator: "\n")
        }
    }

    private func inlineWriter(_ context: InlineWriter.Context, _ style: InlineStyle) -> InlineWriter {
        InlineWriter(context: context, style: style, profile: profile, noteLinkName: noteLinkName,
                     attachmentPath: { $0 }, targets: targets)
    }

    /// Lines of a paragraph-like block; a hard break starts a new line.
    private func blockLines(_ content: [Inline], _ style: InlineStyle) -> [String] {
        guard !content.isEmpty else { return [] }
        return inlineWriter(.block, style).write(content).components(separatedBy: "\n")
            .map { InlineWriter.protectLine($0, lineStart: true) }
    }

    private func singleLine(_ content: [Inline], _ context: InlineWriter.Context, _ style: InlineStyle) -> String {
        InlineWriter.protectLine(inlineWriter(context, style).write(content), lineStart: false)
    }

    private func renderNative(_ unit: Unit, style: InlineStyle, _ placement: Placement) -> [String] {
        let node = unit.nodes[0]
        var lines: [String] = []
        if let comment = comment(for: node, placement, payload: nil) { lines.append(comment) }
        switch node {
        case .paragraph(_, _, let content):
            lines += blockLines(content, style)
        case .heading(let level, _, _, let content):
            let text = singleLine(content, .heading, style)
            lines.append(String(repeating: "#", count: level) + (text.isEmpty ? "" : " " + text))
        case .codeBlock(_, let language, _):
            lines += fence(unit.nodes.map { Self.codeText($0) }.joined(separator: "\n"), language: language)
        case .blockquote(_, let content):
            lines += quote(content) { paragraph in
                guard case .paragraph(_, _, let inlines) = paragraph else { return [] }
                var result: [String] = []
                if let comment = comment(for: paragraph, Placement(), payload: nil) { result.append(comment) }
                return result + blockLines(inlines, style)
            }
        case .horizontalRule:
            lines.append(placement.atFileStart ? "***" : "---")
        case .listItem(let kind, let level, let number, let checked, _, let content):
            lines += listItem(kind: kind, level: level - placement.levelBase, number: number, checked: checked,
                              body: blockLines(content, style))
        case .table(_, let rows):
            lines += table(rows) { cell in
                guard cell.content.count == 1, case .paragraph(_, nil, let inlines) = cell.content[0] else {
                    return cell.content.map { Self.plainLine(Self.contentOf($0), .tableCell) }.joined(separator: " ")
                }
                return singleLine(inlines, .tableCell, style)
            }
        case .doc, .unknown:
            break
        }
        return lines
    }

    private func renderFallback(_ node: DocNode, _ placement: Placement) -> [String] {
        var lines: [String] = []
        if profile == .library, let comment = comment(for: node, placement, payload: RichBlock.encode(node)) {
            lines.append(comment)
        }
        switch node {
        case .paragraph(_, _, let content):
            let line = Self.plainLine(content, .block)
            lines.append(line.isEmpty ? "\\" : line)
        case .heading(let level, _, _, let content):
            let text = Self.plainLine(content, .heading)
            lines.append(String(repeating: "#", count: level) + (text.isEmpty ? "" : " " + text))
        case .codeBlock(_, let language, _):
            let safeLanguage = language.flatMap { $0.isEmpty || $0.contains(where: \.isWhitespace) ? nil : $0 }
            lines += fence(Self.codeText(node), language: safeLanguage)
        case .blockquote(_, let content):
            lines += quote(content) { [Self.plainLine(Self.contentOf($0), .block)] }
        case .horizontalRule:
            lines.append(placement.atFileStart ? "***" : "---")
        case .listItem(let kind, let level, let number, let checked, _, let content):
            let line = Self.plainLine(content, .block)
            lines += listItem(kind: kind, level: level - placement.levelBase, number: number, checked: checked,
                              body: line.isEmpty ? [] : [line])
        case .table(_, let rows):
            lines += table(rows) { cell in cell.content.map { Self.plainLine(Self.contentOf($0), .tableCell) }.joined(separator: " ") }
        case .doc, .unknown:
            break
        }
        return lines
    }

    /// `<!-- noteit: align=… indent=… level=… widths=… doc=… -->`; nil when there's nothing to say.
    private func comment(for node: DocNode, _ placement: Placement, payload: String?) -> String? {
        guard profile == .library else { return nil }
        var parts: [String] = []
        var align: Align?
        var indent: Int?
        if payload == nil {
            switch node {
            case .paragraph(let a, let i, _), .heading(_, let a, let i, _):
                align = a
                indent = i
            case .codeBlock(let a, _, _), .listItem(_, _, _, _, let a, _):
                align = a
            case .blockquote(let i, _):
                indent = i
            default:
                break
            }
        }
        if let align { parts.append("align=" + align.rawValue) }
        if let indent { parts.append("indent=\(indent)") }
        if placement.levelHint, case .listItem(_, let level, _, _, _, _) = node, level > 0 { parts.append("level=\(level)") }
        if payload == nil, case .table(let widths?, _) = node {
            parts.append("widths=" + widths.map(InlineWriter.number).joined(separator: ","))
        }
        if let payload { parts.append("doc=" + payload) }
        return parts.isEmpty ? nil : BlockAttributes.prefix + " " + parts.joined(separator: " ") + " -->"
    }

    // MARK: Block shapes

    private func fence(_ body: String, language: String?) -> [String] {
        let char: Character = language?.contains("`") == true ? "~" : "`"
        var longest = 0
        var run = 0
        for c in body {
            run = c == char ? run + 1 : 0
            longest = max(longest, run)
        }
        let marker = String(repeating: char, count: max(3, longest + 1))
        let info = language.map { language in
            language.map { "\\&".contains($0) ? "\\" + String($0) : String($0) }.joined()
        } ?? ""
        let bodyLines = body.isEmpty && !body.contains("\n") ? [] : body.components(separatedBy: "\n")
        return [marker + info] + bodyLines + [marker]
    }

    private func quote(_ content: [DocNode], paragraph: (DocNode) -> [String]) -> [String] {
        var lines: [String] = []
        var empties = 0
        var first = true
        for node in content {
            if node == BlockParser.emptyParagraph {
                empties += 1
                continue
            }
            lines += Array(repeating: "", count: empties + (first ? 0 : 1))
            lines += paragraph(node)
            empties = 0
            first = false
        }
        lines += Array(repeating: "", count: empties)
        if lines.isEmpty { lines = [""] }
        return lines.map { $0.isEmpty ? ">" : "> " + $0 }
    }

    private func listItem(kind: ListKind, level: Int, number: Int?, checked: Bool?, body: [String]) -> [String] {
        let marker = switch kind {
        case .bullet: "-"
        case .ordered: "\(number ?? 1)."
        case .task: checked == true ? "- [x]" : "- [ ]"
        }
        let indent = String(repeating: " ", count: 4 * max(0, level))
        guard let first = body.first else { return [indent + marker] }
        let continuation = indent + String(repeating: " ", count: marker.count + 1)
        return [indent + marker + " " + first] + body.dropFirst().map { continuation + $0 }
    }

    private func table(_ rows: [[TableCell]], cell text: (TableCell) -> String) -> [String] {
        let columns = max(1, rows.map(\.count).max() ?? 0)
        func line(_ cells: [String]) -> String {
            "| " + (cells + Array(repeating: "", count: max(0, columns - cells.count))).joined(separator: " | ") + " |"
        }
        let hasHeader = rows.first.map { !$0.isEmpty && $0.allSatisfy(\.header) } ?? false
        let alignRow = rows.first ?? []
        let delimiters = (0..<columns).map { column -> String in
            guard column < alignRow.count, case .paragraph(let align, _, _)? = alignRow[column].content.first else { return "---" }
            switch align {
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            default: return "---"
            }
        }
        var lines = [hasHeader ? line(rows[0].map(text)) : line([]), "| " + delimiters.joined(separator: " | ") + " |"]
        for row in rows.dropFirst(hasHeader ? 1 : 0) { lines.append(line(row.map(text))) }
        return lines
    }

    // MARK: Plain text

    private static let strictEscaper = InlineWriter(context: .block, style: .strict, profile: .library, noteLinkName: { _ in nil },
                                                    attachmentPath: { $0 }, targets: NoteTargets())

    /// Text only, every punctuation character escaped: what a fallback block shows to other Markdown readers.
    static func plainLine(_ content: [Inline], _ context: InlineWriter.Context) -> String {
        let text = content.map { inline -> String in
            switch inline {
            case .text(let text, _): strictEscaper.escape(text, inLinkText: false)
            case .image(_, let name, _, _), .attachment(_, let name, _): " " + strictEscaper.escape(name, inLinkText: false) + " "
            case .hardBreak: " "
            }
        }.joined()
        return InlineWriter.protectLine(text, lineStart: context == .block)
    }

    static func codeText(_ node: DocNode) -> String {
        InlineWriter.plainText(contentOf(node), separator: "\n")
    }

    static func contentOf(_ node: DocNode) -> [Inline] {
        switch node {
        case .paragraph(_, _, let content), .heading(_, _, _, let content), .codeBlock(_, _, let content),
             .listItem(_, _, _, _, _, let content):
            content
        default:
            []
        }
    }

    // MARK: Doc helpers

    static func forEachContent(in node: DocNode, _ body: ([Inline]) -> Void) {
        switch node {
        case .paragraph(_, _, let content), .heading(_, _, _, let content), .codeBlock(_, _, let content),
             .listItem(_, _, _, _, _, let content):
            body(content)
        case .blockquote(_, let content), .doc(let content):
            content.forEach { forEachContent(in: $0, body) }
        case .table(_, let rows):
            for cell in rows.joined() { cell.content.forEach { forEachContent(in: $0, body) } }
        case .horizontalRule, .unknown:
            break
        }
    }

    static func mapContent(_ node: DocNode, _ transform: ([Inline]) -> [Inline]) -> DocNode {
        switch node {
        case .doc(let content):
            .doc(content.map { mapContent($0, transform) })
        case .paragraph(let align, let indent, let content):
            .paragraph(align: align, indent: indent, content: transform(content))
        case .heading(let level, let align, let indent, let content):
            .heading(level: level, align: align, indent: indent, content: transform(content))
        case .codeBlock(let align, let language, let content):
            .codeBlock(align: align, language: language, content: transform(content))
        case .blockquote(let indent, let content):
            .blockquote(indent: indent, content: content.map { mapContent($0, transform) })
        case .listItem(let kind, let level, let number, let checked, let align, let content):
            .listItem(kind: kind, level: level, number: number, checked: checked, align: align, content: transform(content))
        case .table(let widths, let rows):
            .table(columnWidths: widths, rows: rows.map { row in
                row.map { TableCell(header: $0.header, content: $0.content.map { mapContent($0, transform) }) }
            })
        case .horizontalRule, .unknown:
            node
        }
    }

    /// The doc as the reader gives it back: images and attachments by path, marks in canonical order, no empty
    /// or mergeable text runs; `portable` drops font sizes and unknown blocks.
    static func readable(_ node: DocNode, attachmentPath: (String) -> String, profile: MarkdownProfile) -> DocNode {
        if profile == .portable, case .doc(let blocks) = node {
            let known = blocks.filter { if case .unknown = $0 { false } else { true } }
            if known.count != blocks.count { return readable(.doc(known), attachmentPath: attachmentPath, profile: profile) }
        }
        return mapContent(node) { content in
            var result: [Inline] = []
            for inline in content {
                switch inline {
                case .image(let sha, let name, let mime, let width):
                    result.append(.image(sha: attachmentPath(sha), name: name, mime: mime, width: width))
                case .attachment(let sha, let name, let mime):
                    result.append(.attachment(sha: attachmentPath(sha), name: name, mime: mime))
                case .hardBreak:
                    result.append(.hardBreak)
                case .text(let text, var marks):
                    if profile == .portable { marks.removeAll { if case .fontSize = $0 { true } else { false } } }
                    result.append(.text(text, marks: MarkOrder.canonical(marks)))
                }
            }
            return result.mergingTextRuns()
        }
    }
}
