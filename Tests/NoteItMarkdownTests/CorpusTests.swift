import NoteItDoc
import NoteItDocTestSupport
import XCTest
@testable import NoteItMarkdown

final class CorpusTests: XCTestCase {
    /// Blocks that plain Markdown can hold: code without marks or atoms, and GFM-shaped tables.
    static func isNative(_ block: DocNode) -> Bool {
        switch block {
        case .codeBlock(_, _, let content):
            return content.allSatisfy { if case .text(_, let marks) = $0 { marks.isEmpty } else { false } }
        case .table(_, let rows):
            guard let first = rows.first else { return false }
            let headerRow = first.allSatisfy(\.header) || first.allSatisfy { !$0.header }
            guard headerRow, rows.dropFirst().allSatisfy({ $0.allSatisfy { !$0.header } }) else { return false }
            var aligns: [Int: Align?] = [:]
            for row in rows {
                for (column, cell) in row.enumerated() {
                    guard cell.content.count == 1, case .paragraph(let align, nil, _) = cell.content[0], align != .justify else {
                        return false
                    }
                    if let seen = aligns[column], seen != align { return false }
                    aligns[column] = align
                }
            }
            return true
        default:
            return true
        }
    }

    func testRandomBlocksFallBackOnlyWhenMarkdownCannotHoldThem() {
        var native = 0
        var nativeFallbacks = 0
        for seed in UInt64(0)..<500 {
            var generator = RandomDocGenerator(seed: seed)
            guard case .doc(let blocks) = generator.next().doc else { continue }
            for block in blocks where Self.isNative(block) {
                let output = MarkdownCodec.write(BodyContainer(doc: .doc([block]), attachments: [:]), frontMatter: .empty,
                                                 profile: .library, attachmentPath: CodecPropertyTests.path,
                                                 noteLinkName: { $0.uuidString }, previous: nil)
                native += output.units
                nativeFallbacks += output.fallbacks
            }
        }
        XCTAssertGreaterThan(native, 1000)
        XCTAssertLessThanOrEqual(nativeFallbacks * 100, native, "\(nativeFallbacks) of \(native) blocks fell back")
    }
}
