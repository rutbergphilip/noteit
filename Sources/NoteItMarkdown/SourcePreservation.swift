import Foundation
import NoteItDoc

/// Blocks that didn't change keep their bytes from the previous file, so a foreign file's style (`__bold__`, `+`
/// bullets, setext headings) survives an edit elsewhere in the note.
enum SourcePreservation {
    struct PreviousUnit {
        var nodes: [DocNode]
        var text: String
    }

    /// Blocks of the previous parse grouped by source range, without the blank lines between them.
    static func units(of previous: ParsedMarkdown) -> [PreviousUnit] {
        guard case .doc(let blocks) = previous.body.doc, blocks.count == previous.sourceMap.blocks.count else { return [] }
        var units: [PreviousUnit] = []
        var lastRange: Range<String.Index>?
        for (node, range) in zip(blocks, previous.sourceMap.blocks) {
            let text = previous.source[range]
            if node == BlockParser.emptyParagraph, text.allSatisfy(\.isWhitespace) {
                lastRange = nil
                continue
            }
            if range == lastRange {
                units[units.count - 1].nodes.append(node)
            } else {
                units.append(PreviousUnit(nodes: [node], text: text.replacingOccurrences(of: "\r\n", with: "\n")))
            }
            lastRange = range
        }
        return units
    }

    /// For each unit, the previous source of an equal unit, matched in order.
    static func match(_ units: [[DocNode]], in previous: ParsedMarkdown) -> [String?] {
        let candidates = self.units(of: previous)
        var next = 0
        return units.map { nodes in
            guard let found = candidates[next...].firstIndex(where: { $0.nodes == nodes }) else { return nil }
            next = found + 1
            return candidates[found].text
        }
    }
}
