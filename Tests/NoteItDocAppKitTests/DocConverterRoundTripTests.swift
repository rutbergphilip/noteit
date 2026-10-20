import NoteItDoc
import NoteItDocAppKit
import NoteItDocTestSupport
import XCTest

final class DocConverterRoundTripTests: XCTestCase {
    func testRandomDocsRoundTripExactly() throws {
        var failures = 0
        for seed in UInt64(0)..<500 {
            var generator = RandomDocGenerator(seed: seed)
            let original = generator.next()
            let text = try DocConverter.importDocument(original, styles: TestStyles())
            let back = try DocConverter.export(text, styles: TestStyles())
            if back.doc != original.doc || back.attachments != original.attachments {
                failures += 1
                if failures <= 3 {
                    XCTFail("seed \(seed): \(Self.firstDifference(original, back))")
                }
            }
        }
        XCTAssertEqual(failures, 0)
    }

    private static func firstDifference(_ a: BodyContainer, _ b: BodyContainer) -> String {
        guard case .doc(let x) = a.doc, case .doc(let y) = b.doc else { return "root" }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : nil
            let r = i < y.count ? y[i] : nil
            guard l != r else { continue }
            if case .table(let w1, let rows1)? = l, case .table(let w2, let rows2)? = r {
                if w1 != w2 { return "block \(i) widths \(String(describing: w1)) vs \(String(describing: w2))" }
                for (ri, (r1, r2)) in zip(rows1, rows2).enumerated() where r1 != r2 {
                    for (ci, (c1, c2)) in zip(r1, r2).enumerated() where c1 != c2 {
                        return "block \(i) cell \(ri),\(ci) header \(c1.header)/\(c2.header)\n  want \(c1.content.map { describe($0) })\n  got  \(c2.content.map { describe($0) })"
                    }
                    return "block \(i) row \(ri) count \(r1.count) vs \(r2.count)"
                }
                return "block \(i) rows \(rows1.count) vs \(rows2.count)"
            }
            return "block \(i)\n  want \(describe(l))\n  got  \(describe(r))"
        }
        let missing = Set(a.attachments.keys).subtracting(b.attachments.keys).map { a.attachments[$0]!.name }
        let extra = Set(b.attachments.keys).subtracting(a.attachments.keys).map { b.attachments[$0]!.name }
        let changed = a.attachments.filter { b.attachments[$0.key] != nil && b.attachments[$0.key] != $0.value }.map { "\($0.value.name) -> \(b.attachments[$0.key]!.name) \(b.attachments[$0.key]!.mime)" }
        return "attachments missing \(missing) extra \(extra) changed \(changed)"
    }

    private static func describe(_ node: DocNode?) -> String {
        guard let node else { return "nil" }
        return (try? JSONEncoder().encode(node)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }
}
