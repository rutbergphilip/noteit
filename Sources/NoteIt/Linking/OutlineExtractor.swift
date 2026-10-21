import AppKit

struct OutlineItem: Equatable, Sendable {
    /// 0 title, 1 heading, 2 subheading.
    var level: Int
    var text: String
    /// The paragraph, without its line break.
    var range: NSRange
}

enum OutlineExtractor {
    /// Title, heading and subheading paragraphs in text order, skipping empty ones and table cells.
    nonisolated static func items(in text: NSAttributedString) -> [OutlineItem] {
        let ns = text.string as NSString
        let length = ns.length
        var items: [OutlineItem] = []
        var location = 0
        while location < length {
            var end = 0
            var contentsEnd = 0
            ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            defer { location = max(end, location + 1) }
            guard contentsEnd > location else { continue }
            let ps = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            if ps?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true { continue }
            let font = text.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            let level: Int
            switch EditorStyle.blockKind(paragraphStyle: ps, font: font) {
            case .title: level = 0
            case .heading: level = 1
            case .subheading: level = 2
            default: continue
            }
            let range = NSRange(location: location, length: contentsEnd - location)
            let title = ns.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            items.append(OutlineItem(level: level, text: title, range: range))
        }
        return items
    }

    /// From the item's start up to the next item of the same or a higher level (a lower number), or to `length`.
    nonisolated static func section(of item: OutlineItem, in items: [OutlineItem], length: Int) -> NSRange {
        let start = item.range.location
        let next = items.first { $0.range.location > start && $0.level <= item.level }
        let end = next?.range.location ?? length
        return NSRange(location: start, length: max(0, end - start))
    }
}
