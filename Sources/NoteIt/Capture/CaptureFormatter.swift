import AppKit

/// Turns a captured selection into note content: a title, the quoted text and a source line.
enum CaptureFormatter {
    static let maxTitleLength = CaptureTitle.maxLength
    static let maxSelectionLength = 200_000

    static let titleScanLimit = CaptureTitle.scanLimit

    static func title(for capture: CapturedSelection) -> String {
        let source = capture.source
        let appName = CaptureTitle.singleLine(source.appName)
        if let pageTitle = CaptureTitle.singleLine(source.pageTitle) {
            return CaptureTitle.truncated(pageTitle)
        }
        if let window = usableWindowTitle(source.windowTitle, appName: appName) {
            return CaptureTitle.truncated(window)
        }
        if let document = linkableURL(source.documentURL), document.isFileURL {
            let name = document.deletingPathExtension().lastPathComponent
            if name != "/", let name = CaptureTitle.singleLine(name) {
                return CaptureTitle.truncated(name)
            }
        }
        if let line = CaptureTitle.firstLine(of: capture.text) {
            return CaptureTitle.truncated(line)
        }
        guard let appName else { return "Captured Text" }
        return "Captured from \(appName)"
    }

    static func body(for capture: CapturedSelection) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let (lines, truncated) = quoteLines(of: capture.text)
        for line in lines {
            result.append(EditorStyle.paragraph(line, kind: .quote))
        }
        if truncated {
            result.append(EditorStyle.paragraph("…", kind: .quote))
        }
        if result.length > 0 {
            result.append(EditorStyle.paragraph("", kind: .body))
        }
        result.append(sourceLine(for: capture))
        return result
    }

    static func noteContent(for capture: CapturedSelection) -> NSAttributedString {
        NoteStore.capturedText(title: title(for: capture), body: body(for: capture))
    }

    /// Returns the URL only if it is safe to link: http(s) with a host, or a file URL.
    static func linkableURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" {
            return url.isFileURL && !url.path.isEmpty ? url : nil
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: Source line

    private static func sourceLine(for capture: CapturedSelection) -> NSAttributedString {
        let source = capture.source
        let appName = CaptureTitle.singleLine(source.appName)
        let attributes = EditorStyle.bodyAttributes
        let line = NSMutableAttributedString()

        var link: (label: String, url: URL)?
        if let page = linkableURL(source.pageURL) {
            link = (CaptureTitle.singleLine(source.pageTitle) ?? label(for: page), page)
        } else if let document = linkableURL(source.documentURL) {
            link = (label(for: document), document)
        }

        if let link {
            line.append(NSAttributedString(string: "From ", attributes: attributes))
            var linkAttributes = attributes
            linkAttributes[.link] = link.url
            line.append(NSAttributedString(string: link.label, attributes: linkAttributes))
            if let appName {
                line.append(NSAttributedString(string: " in \(appName)", attributes: attributes))
            }
            return line
        }

        var text = "From another app"
        if let appName {
            text = "From \(appName)"
        }
        if let window = CaptureTitle.singleLine(source.windowTitle), CaptureTitle.truncated(window) != title(for: capture), !isSame(window, appName) {
            text += " — \(window)"
        }
        line.append(NSAttributedString(string: text, attributes: attributes))
        return line
    }

    private static func label(for url: URL) -> String {
        if url.isFileURL {
            let name = url.lastPathComponent
            let label = name.isEmpty || name == "/" ? url.path : name
            return CaptureTitle.singleLine(label) ?? "file"
        }
        var host = url.host ?? ""
        if host.lowercased().hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host.isEmpty ? url.absoluteString : host
    }

    // MARK: Selection text

    private static func quoteLines(of text: String) -> (lines: [String], truncated: Bool) {
        var text = text
        var truncated = false
        if let cut = text.index(text.startIndex, offsetBy: maxSelectionLength, limitedBy: text.endIndex), cut < text.endIndex {
            text = String(text[..<cut])
            truncated = true
        }
        var lines: [String] = []
        var blankRun = 0
        for raw in normalizedLines(text) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                continue
            }
            if !lines.isEmpty {
                let kept = blankRun >= 3 ? 1 : blankRun
                lines.append(contentsOf: repeatElement("", count: kept))
            }
            blankRun = 0
            lines.append(String(raw))
        }
        return (lines, truncated)
    }

    private static func normalizedLines(_ text: String) -> [Substring] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\u{2029}", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\u{2028}", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
    }

    // MARK: Title helpers

    private static func usableWindowTitle(_ text: String?, appName: String?) -> String? {
        guard let window = CaptureTitle.singleLine(text), !isSame(window, appName), !isGenericUntitled(window) else { return nil }
        return window
    }

    private static func isGenericUntitled(_ title: String) -> Bool {
        let pattern = "^untitled(?:[ -]?\\d+)?(?:\\.[a-z0-9]+)?$"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isSame(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}
