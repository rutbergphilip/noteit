import AppKit

/// The result of writing a note as Markdown.
struct MarkdownExport: Equatable {
    var markdown: String
    /// Images and files referenced from `markdown` as `<title> assets/<filename>`.
    var assets: [ExportAsset]
}

/// Converts a NoteIt note body to Markdown (CommonMark with GFM tables, task lists and strikethrough).
///
/// Underline, colors, highlights, alignment and indentation of plain paragraphs are dropped.
@MainActor
enum MarkdownWriter {
    /// The folder next to the Markdown file that holds its images and files.
    static func assetsFolderName(for title: String) -> String {
        "\(title) assets"
    }

    /// `title` names the assets folder that image links point into; pass the exported file's base name.
    static func write(_ text: NSAttributedString, title: String) -> MarkdownExport {
        write(text, assetsFolder: assetsFolderName(for: title))
    }

    /// Like `write(_:title:)`, with image links pointing into the folder named `assetsFolder`.
    static func write(_ text: NSAttributedString, assetsFolder: String) -> MarkdownExport {
        var writer = Writer(assetsFolder: assetsFolder)
        return writer.write(NoteBlocks.parse(text))
    }

    private struct Writer {
        let assetsFolder: String
        var assets: [ExportAsset] = []
        var takenAssetNames = Set<String>()
        var imageCount = 0
        var topListKind: ListKind?
        /// Column where the text of the current list item at each level starts. A child item must be
        /// indented to its parent's text column to nest in CommonMark (2 under `- `, 3 under `1. `).
        var listColumns: [Int] = []

        mutating func write(_ blocks: [NoteBlock]) -> MarkdownExport {
            var out = ""
            var previous: NoteBlock?
            for block in blocks {
                if case .listItem = block {} else { listColumns.removeAll() }
                if let previous { out += separator(between: previous, and: block) }
                out += render(block)
                previous = block
            }
            if !out.isEmpty { out += "\n" }
            return MarkdownExport(markdown: out, assets: assets)
        }

        private func separator(between a: NoteBlock, and b: NoteBlock) -> String {
            switch (a, b) {
            case (.listItem, .listItem(let marker, let level, _, _)):
                // A different kind of list at the top level starts a new list.
                return level == 0 && topListKind != ListMarker(kind: marker, length: 0).listKind ? "\n\n" : "\n"
            case (.paragraph(.quote, _, _), .paragraph(.quote, _, _)):
                return "\n>\n"
            default:
                return "\n\n"
            }
        }

        private mutating func render(_ block: NoteBlock) -> String {
            switch block {
            case .paragraph(let kind, _, let runs):
                switch kind {
                case .title, .heading, .subheading:
                    let hashes = kind == .title ? "#" : kind == .heading ? "##" : "###"
                    let text = inline(runs, continuation: "").replacingOccurrences(of: "\\\n", with: " ")
                    return hashes + " " + text
                case .quote:
                    return "> " + escapeLines(inline(runs, continuation: "> "), continuation: "> ")
                default:
                    return escapeLines(inline(runs, continuation: ""), continuation: "")
                }
            case .listItem(let marker, let level, _, let runs):
                if level == 0 { topListKind = ListMarker(kind: marker, length: 0).listKind }
                let prefix: String
                switch marker {
                case .bullet: prefix = "- "
                case .numbered(let n): prefix = "\(n). "
                case .checkbox(let checked): prefix = checked ? "- [x] " : "- [ ] "
                }
                // A level with no parent item above it nests under the deepest item there is.
                let depth = min(level, listColumns.count)
                let column = depth == 0 ? 0 : listColumns[depth - 1]
                listColumns.removeSubrange(depth...)
                // The task box is part of the item's text; CommonMark nests on the `- `.
                listColumns.append(column + (marker.isNumbered ? prefix.count : 2))
                let indent = String(repeating: " ", count: column)
                let continuation = indent + String(repeating: " ", count: prefix.count)
                return indent + prefix + escapeLines(inline(runs, continuation: continuation), continuation: continuation)
            case .code(let code, let language):
                var fence = "```"
                while code.contains(fence) { fence += "`" }
                let info = language.flatMap { $0 == .plain ? nil : $0.identifier } ?? ""
                return fence + info + "\n" + code + "\n" + fence
            case .divider:
                return "---"
            case .table(let rows):
                guard let header = rows.first else { return "" }
                var lines = [row(header)]
                lines.append("|" + header.map { _ in " --- |" }.joined())
                for r in rows.dropFirst() { lines.append(row(r)) }
                return lines.joined(separator: "\n")
            }
        }

        private mutating func row(_ cells: [[InlineRun]]) -> String {
            "|" + cells.map { " " + inline($0, continuation: "", inTable: true) + " |" }.joined()
        }

        // MARK: Inline

        private enum Delimiter: String { case strike = "~~", bold = "**", italic = "*" }

        private mutating func inline(_ runs: [InlineRun], continuation: String, inTable: Bool = false) -> String {
            let runs = runs.map { run in
                var run = run
                if let link = run.link, !ExportLinks.isSafe(link) { run.link = nil }
                return run
            }
            var out = ""
            var index = 0
            while index < runs.count {
                let link = runs[index].attachment == nil ? runs[index].link : nil
                var end = index + 1
                while end < runs.count, runs[end].link == link || (link == nil && runs[end].attachment != nil) {
                    if link != nil && runs[end].attachment != nil { break }
                    end += 1
                }
                let group = Array(runs[index..<end])
                let styled = styledText(group, continuation: continuation, inTable: inTable)
                if let link {
                    out += "[" + styled + "](" + destination(link.absoluteString) + ")"
                } else {
                    out += styled
                }
                index = end
            }
            return out.trimmingCharacters(in: .whitespaces)
        }

        private mutating func styledText(_ runs: [InlineRun], continuation: String, inTable: Bool) -> String {
            var out = ""
            var open: [Delimiter] = []
            var pending = ""

            func close(from k: Int) {
                for d in open[k...].reversed() { out += d.rawValue }
                open.removeSubrange(k...)
            }

            for run in runs {
                if let attachment = run.attachment {
                    close(from: 0)
                    out += pending + attachmentMarkdown(attachment)
                    pending = ""
                    continue
                }
                var desired: [Delimiter] = []
                if run.strikethrough { desired.append(.strike) }
                if run.bold { desired.append(.bold) }
                if run.italic { desired.append(.italic) }

                let lead = String(run.text.prefix { $0 == " " || $0 == "\t" })
                let rest = run.text.dropFirst(lead.count)
                let trail = String(rest.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
                let core = String(rest.dropLast(trail.count))
                if core.isEmpty {
                    pending += lead + trail
                    continue
                }
                var k = 0
                while k < open.count, k < desired.count, open[k] == desired[k] { k += 1 }
                close(from: k)
                out += pending + lead
                pending = ""
                for d in desired[k...] { out += d.rawValue }
                open = desired
                var body = run.code ? codeSpan(core) : escape(core, inTable: inTable)
                if run.code && inTable { body = body.replacingOccurrences(of: "|", with: "\\|") }
                out += lineBreaks(body, continuation: continuation, inTable: inTable)
                pending = trail
            }
            close(from: 0)
            return out + pending
        }

        private func lineBreaks(_ s: String, continuation: String, inTable: Bool) -> String {
            s.replacingOccurrences(of: NoteBlocks.lineBreak, with: inTable ? "<br>" : "\\\n" + continuation)
        }

        private func codeSpan(_ s: String) -> String {
            var ticks = "`"
            while s.contains(ticks) { ticks += "`" }
            let pad = s.hasPrefix("`") || s.hasSuffix("`") ? " " : ""
            return ticks + pad + s + pad + ticks
        }

        private func escape(_ s: String, inTable: Bool) -> String {
            let chars = Array(s)
            var out = ""
            for (i, c) in chars.enumerated() {
                switch c {
                case "\\", "*", "`", "[", "]", "~", "<":
                    out += "\\" + String(c)
                case "_":
                    let before = i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber)
                    let after = i + 1 < chars.count && (chars[i + 1].isLetter || chars[i + 1].isNumber)
                    out += before && after ? "_" : "\\_"
                case "|" where inTable:
                    out += "\\|"
                default:
                    out.append(c)
                }
            }
            return out
        }

        /// Escapes the start of each line of a paragraph, including lines after a line break.
        private func escapeLines(_ s: String, continuation: String) -> String {
            let separator = "\\\n" + continuation
            return s.components(separatedBy: separator).enumerated().map { index, line in
                // Leading spaces after a line break are dropped by Markdown readers anyway.
                escapeLineStart(index == 0 ? line : String(line.drop { $0 == " " || $0 == "\t" }))
            }.joined(separator: separator)
        }

        /// Keeps a line that starts like a block marker (`# `, `- `, `1. `, `>`, a setext underline) as text.
        private func escapeLineStart(_ s: String) -> String {
            let pattern = #"^(#{1,6}(\s|$)|[-+](\s|$)|>|\d{1,9}[.)](\s|$)|=+\s*$|-{2,}\s*$)"#
            guard s.range(of: pattern, options: .regularExpression) != nil else { return s }
            if let first = s.first, first.isNumber, let dot = s.firstIndex(where: { $0 == "." || $0 == ")" }) {
                return String(s[..<dot]) + "\\" + String(s[dot...])
            }
            return "\\" + s
        }

        private func destination(_ raw: String) -> String {
            let s = raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "&", with: "\\&")
            return s.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" }) ? "<" + s + ">" : s
        }

        private mutating func attachmentMarkdown(_ attachment: NSTextAttachment) -> String {
            guard let contents = attachment.exportContents else { return "" }
            let filename: String
            if contents.isImage {
                imageCount += 1
                var ext = ((contents.filename ?? "") as NSString).pathExtension.lowercased()
                if ext.isEmpty { ext = "png" }
                filename = ExportNaming.unique("image-\(imageCount)", extension: ext, taken: &takenAssetNames)
            } else {
                let original = contents.filename ?? "file"
                let ext = (original as NSString).pathExtension
                let base = ExportNaming.sanitized((original as NSString).deletingPathExtension, fallback: "file")
                filename = ExportNaming.unique(base, extension: ext, taken: &takenAssetNames)
            }
            assets.append(ExportAsset(filename: filename, data: contents.data))
            let path = destination(assetsFolder + "/" + filename)
            if contents.isImage { return "![](" + path + ")" }
            return "[" + escape(filename, inTable: false) + "](" + path + ")"
        }
    }
}

private extension ListMarker.Kind {
    var isNumbered: Bool {
        if case .numbered = self { return true }
        return false
    }
}
