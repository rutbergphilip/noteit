import AppKit

struct TemplateContext {
    var title: String
    var date: Date
    var locale: Locale = .current
    var clipboard: () -> String?
}

struct TemplateExpansion {
    var text: NSAttributedString
    var caret: Int?
}

enum TemplateExpander {
    static let clipboardLimit = 10_000

    private static let pattern = try! NSRegularExpression(
        pattern: #"\{\{(title|date|time|clipboard|cursor)(?::([^}\n]{1,64}))?\}\}"#,
        options: [.caseInsensitive])

    static func expand(_ template: NSAttributedString, context: TemplateContext) -> TemplateExpansion {
        let out = NSMutableAttributedString(attributedString: template)
        let matches = pattern.matches(in: out.string, range: NSRange(location: 0, length: out.length))
        guard !matches.isEmpty else { return TemplateExpansion(text: out, caret: nil) }
        let ns = out.string as NSString

        var clipboardValue: String??
        func clipboard() -> String {
            if clipboardValue == nil { clipboardValue = .some(context.clipboard()) }
            var text = (clipboardValue ?? nil) ?? ""
            while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
            if text.count > clipboardLimit { text = String(text.prefix(clipboardLimit)) }
            return text
        }

        let firstCursor = matches.first { ns.substring(with: $0.range(at: 1)).lowercased() == "cursor" }?.range.location
        var caretShift = 0
        for match in matches.reversed() {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let format = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            let value: String
            switch name {
            case "title": value = context.title
            case "date": value = formatted(context.date, pattern: format ?? "yyyy-MM-dd", locale: context.locale)
            case "time":
                if let format { value = formatted(context.date, pattern: format, locale: context.locale) }
                else { value = shortTime(context.date, locale: context.locale) }
            case "clipboard": value = clipboard()
            default: value = ""
            }
            let attrs = out.attributes(at: match.range.location, effectiveRange: nil)
            out.replaceCharacters(in: match.range, with: NSAttributedString(string: value, attributes: attrs))
            if let firstCursor, match.range.location < firstCursor {
                caretShift += (value as NSString).length - match.range.length
            }
        }
        return TemplateExpansion(text: out, caret: firstCursor.map { $0 + caretShift })
    }

    static func displayName(forTitle title: String) -> String {
        let ns = title as NSString
        let stripped = pattern.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        let name = stripped.trimmingCharacters(in: trimSet)
        return name.isEmpty ? "Untitled Template" : name
    }

    private static func formatted(_ date: Date, pattern: String, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private static func shortTime(_ date: Date, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}
