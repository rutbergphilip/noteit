import AppKit

/// Converts a NoteIt note body to a self-contained HTML page. Images are embedded as data URLs, and
/// colors, highlights, underline and alignment are kept.
@MainActor
enum HTMLWriter {
    static func write(_ text: NSAttributedString, title: String, code: CodeStyleSettings = .current) -> String {
        var body = ""
        /// Open lists, innermost last. Each has an unclosed `<li>`.
        var lists: [(key: String, tag: String, level: Int)] = []

        func closeLists(above level: Int) {
            while let last = lists.last, last.level > level {
                body += "</li></\(last.tag)>\n"
                lists.removeLast()
            }
        }

        for block in NoteBlocks.parse(text) {
            guard case .listItem(let marker, let level, let alignment, let runs) = block else {
                closeLists(above: -1)
                body += html(for: block, code: code) + "\n"
                continue
            }
            let tag: String, key: String
            var opening: String
            var item = "<li\(alignmentStyle(alignment))>"
            switch marker {
            case .bullet:
                (tag, key, opening) = ("ul", "ul", "<ul>")
            case .numbered(let n):
                (tag, key, opening) = ("ol", "ol", "<ol>")
                if n != 1 { opening = "<ol start=\"\(n)\">" }
            case .checkbox(let checked):
                (tag, key, opening) = ("ul", "checklist", "<ul class=\"checklist\">")
                item = "<li class=\"\(checked ? "checked" : "unchecked")\"\(alignmentStyle(alignment))>"
                    + "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            }
            closeLists(above: level)
            if let last = lists.last, last.level == level {
                if last.key == key {
                    body += "</li>\n"
                } else {
                    body += "</li></\(last.tag)>\n"
                    lists.removeLast()
                }
            }
            if lists.last.map({ $0.level < level }) ?? true {
                body += opening + "\n"
                lists.append((key, tag, level))
            }
            if case .checkbox(true) = marker {
                body += item + "<span class=\"done\">" + inline(runs) + "</span>"
            } else {
                body += item + inline(runs)
            }
        }
        closeLists(above: -1)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="NoteIt">
        <title>\(escape(title))</title>
        <style>
        \(stylesheet)
        \(codeStylesheet(code))
        </style>
        </head>
        <body>
        <article>
        \(body)</article>
        </body>
        </html>

        """
    }

    private static func html(for block: NoteBlock, code settings: CodeStyleSettings) -> String {
        switch block {
        case .paragraph(let kind, let alignment, let runs):
            let style = alignmentStyle(alignment)
            switch kind {
            case .title: return "<h1\(style)>\(inline(runs))</h1>"
            case .heading: return "<h2\(style)>\(inline(runs))</h2>"
            case .subheading: return "<h3\(style)>\(inline(runs))</h3>"
            case .quote: return "<blockquote><p\(style)>\(inline(runs))</p></blockquote>"
            default: return "<p\(style)>\(inline(runs))</p>"
            }
        case .listItem:
            return ""
        case .code(let code, let language):
            let cls = language.flatMap { $0 == .plain ? nil : " class=\"language-\($0.identifier)\"" } ?? ""
            return "<pre><code\(cls)>\(highlighted(code, language: language, settings: settings))</code></pre>"
        case .divider:
            return "<hr>"
        case .table(let rows):
            var out = "<table>\n"
            for (r, row) in rows.enumerated() {
                let cell = r == 0 ? "th" : "td"
                out += "<tr>" + row.map { "<\(cell)>\(inline($0))</\(cell)>" }.joined() + "</tr>\n"
            }
            return out + "</table>"
        }
    }

    private static func alignmentStyle(_ alignment: NSTextAlignment) -> String {
        switch alignment {
        case .center: " style=\"text-align: center\""
        case .right: " style=\"text-align: right\""
        case .justified: " style=\"text-align: justify\""
        default: ""
        }
    }

    // MARK: Inline

    static func inline(_ runs: [InlineRun]) -> String {
        var out = ""
        for run in runs {
            if let attachment = run.attachment {
                out += attachmentHTML(attachment)
                continue
            }
            var s = escape(run.text).replacingOccurrences(of: NoteBlocks.lineBreak, with: "<br>")
            if run.code { s = "<code>\(s)</code>" }
            if run.italic { s = "<em>\(s)</em>" }
            if run.bold { s = "<strong>\(s)</strong>" }
            if run.underline { s = "<u>\(s)</u>" }
            if run.strikethrough { s = "<s>\(s)</s>" }
            var styles: [String] = []
            if let color = run.color.flatMap(cssColor), !isDefaultTextColor(run.color!) { styles.append("color: \(color)") }
            if let highlight = run.highlight.flatMap(cssColor) {
                s = "<mark style=\"background-color: \(highlight)\">\(s)</mark>"
            }
            if !styles.isEmpty { s = "<span style=\"\(styles.joined(separator: "; "))\">\(s)</span>" }
            if let link = run.link, ExportLinks.isSafe(link) { s = "<a href=\"\(escape(link.absoluteString))\">\(s)</a>" }
            out += s
        }
        return out
    }

    private static func attachmentHTML(_ attachment: NSTextAttachment) -> String {
        guard let contents = attachment.exportContents else { return "" }
        let ext = ((contents.filename ?? "image.png") as NSString).pathExtension
        let mime = ExportFileType.mimeType(extension: ext.isEmpty ? "png" : ext)
        let url = "data:\(mime);base64,\(contents.data.base64EncodedString())"
        if contents.isImage {
            return "<img src=\"\(escape(url))\" alt=\"\(escape(contents.filename ?? ""))\">"
        }
        let name = escape(contents.filename ?? "file")
        return "<a href=\"\(escape(url))\" download=\"\(name)\">\(name)</a>"
    }

    /// Black and near-black text is the default ink; leaving it out keeps it readable in dark mode.
    private static func isDefaultTextColor(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) < 0.2
    }

    /// Wraps syntax tokens in `tk-*` spans; Automatic blocks use the same guess as the editor.
    static func highlighted(_ code: String, language: CodeLanguage?, settings: CodeStyleSettings) -> String {
        guard settings.highlighting, let language = language ?? SyntaxHighlighter.guessLanguage(code) else {
            return escape(code)
        }
        let ns = code as NSString
        var out = "", cursor = 0
        for token in SyntaxHighlighter.tokenize(code, language: language).sorted(by: { $0.range.location < $1.range.location }) {
            guard token.range.location >= cursor, NSMaxRange(token.range) <= ns.length, token.range.length > 0 else { continue }
            out += escape(ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            out += "<span class=\"tk-\(token.kind)\">\(escape(ns.substring(with: token.range)))</span>"
            cursor = NSMaxRange(token.range)
        }
        return out + escape(ns.substring(from: cursor))
    }

    static func codeStylesheet(_ settings: CodeStyleSettings) -> String {
        func hex(_ v: UInt32) -> String { String(format: "#%06x", v) }
        func rules(_ palette: CodeTheme.Palette, _ ink: NSColor, _ fill: NSColor, dark: Bool) -> String {
            var css = "code { color: \(rgba(ink, dark: dark)); background: \(rgba(fill, dark: dark)); }"
            guard settings.highlighting else { return css + " pre code { color: var(--ink); }" }
            css += " pre code { color: \(hex(palette.plain)); }"
            if let background = palette.background { css += " pre { background: \(hex(background)); }" }
            for kind in TokenKind.allCases { css += " .tk-\(kind) { color: \(hex(palette.hex(for: kind))); }" }
            return css
        }
        let ink = settings.inlineColor.textColor, fill = settings.inlineColor.fillColor
        var css = "code { border-radius: 5px; padding: 0.12em 0.4em; }"
        if settings.inlineFont == .sameAsText { css += " :not(pre) > code { font-family: inherit; font-size: 1em; }" }
        css += "\n" + rules(settings.theme.light, ink, fill, dark: false)
        css += "\n@media (prefers-color-scheme: dark) { " + rules(settings.theme.dark, ink, fill, dark: true) + " }"
        return css + "\npre code, mark code { background: none; } pre code { padding: 0; }"
    }

    private static func rgba(_ color: NSColor, dark: Bool) -> String {
        var resolved: NSColor?
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let c = resolved else { return "inherit" }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return "rgba(\(byte(c.redComponent)), \(byte(c.greenComponent)), \(byte(c.blueComponent)), \(String(format: "%.2f", c.alphaComponent)))"
    }

    static func cssColor(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func hex(_ v: CGFloat) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + hex(rgb.redComponent) + hex(rgb.greenComponent) + hex(rgb.blueComponent)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    private static let stylesheet = """
    :root { color-scheme: light dark; --ink: #1d1d1f; --muted: #6e6e73; --rule: #d2d2d7; --fill: #f5f5f7; --accent: #0a84ff; }
    @media (prefers-color-scheme: dark) {
      :root { --ink: #f5f5f7; --muted: #a1a1a6; --rule: #424245; --fill: #2c2c2e; }
      body { background: #1e1e1e; }
    }
    body { margin: 0; color: var(--ink); font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif; -webkit-font-smoothing: antialiased; }
    article { max-width: 720px; margin: 0 auto; padding: 48px 28px 64px; }
    h1 { font-size: 2em; line-height: 1.2; margin: 0 0 0.6em; }
    h2 { font-size: 1.35em; line-height: 1.3; margin: 1.4em 0 0.4em; }
    h3 { font-size: 1.1em; margin: 1.2em 0 0.3em; }
    p { margin: 0 0 0.75em; }
    a { color: var(--accent); }
    code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.92em; }
    code { background: var(--fill); border-radius: 4px; padding: 0.1em 0.35em; }
    pre { background: var(--fill); border: 1px solid var(--rule); border-radius: 8px; padding: 12px 14px; overflow-x: auto; line-height: 1.45; }
    pre code { background: none; padding: 0; font-size: 1em; }
    blockquote { margin: 0 0 0.75em; padding-left: 14px; border-left: 3px solid var(--rule); color: var(--muted); }
    blockquote p { margin: 0; }
    blockquote + blockquote { margin-top: -0.75em; padding-top: 0.4em; }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 1.4em 0; }
    ul, ol { margin: 0 0 0.75em; padding-left: 1.6em; }
    li > ul, li > ol { margin: 0.2em 0 0; }
    ul.checklist { list-style: none; padding-left: 0.3em; }
    ul.checklist ul.checklist { padding-left: 1.6em; }
    ul.checklist input { margin: 0 0.4em 0 0; vertical-align: -1px; }
    .done { color: var(--muted); text-decoration: line-through; }
    mark { color: #1d1d1f; border-radius: 3px; padding: 0 0.1em; }
    img { max-width: 100%; height: auto; border-radius: 4px; }
    table { border-collapse: collapse; width: 100%; margin: 0 0 1em; }
    th, td { border: 1px solid var(--rule); padding: 6px 10px; text-align: left; vertical-align: top; }
    th { background: var(--fill); font-weight: 600; }
    @media print { body { background: none; } article { padding: 0; } }
    """
}
