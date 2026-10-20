import CryptoKit
import Foundation
import NoteItDoc

/// Seeded random `noteit-doc` containers for round-trip tests. Owned by the foundations plan (Task 2.2).
///
/// Default: every node except .unknown, so output validates as .valid and round-trips through the AppKit
/// converter. includeUnknown: true also emits .unknown nodes; only NoteItDoc codec and validator tests use it.
///
/// Output is canonical, the form the converter writes back: marks in declaration order, no empty or mergeable text
/// nodes, `indent` absent rather than 0, no two blockquotes in a row, no `bold` in headings, no `strike` or
/// `textColor` on checked items, no `code` mark in code blocks, attachment names whose extension gives the mime,
/// and a header row only as the first row of a table.
public struct RandomDocGenerator {
    private var random: SplitMix64
    private let includeUnknown: Bool
    private var attachments: [String: Attachment] = [:]

    public init(seed: UInt64, includeUnknown: Bool = false) {
        random = SplitMix64(seed: seed)
        self.includeUnknown = includeUnknown
    }

    public mutating func next() -> BodyContainer {
        attachments = [:]
        var blocks: [DocNode] = []
        for _ in 0..<int(1...12) {
            var block = randomBlock()
            if case .blockquote? = blocks.last, case .blockquote = block { block = .horizontalRule }
            blocks.append(block)
        }
        var container = BodyContainer(doc: .doc(blocks), attachments: attachments,
                                      frontMatter: chance(0.15) ? "title: \(word())\ntags: [\(word())]" : nil)
        if includeUnknown, chance(0.3) {
            container.extra = ["future\(int(0...9))": randomJSON(depth: 0)]
        }
        return container
    }

    // MARK: - Blocks

    private mutating func randomBlock() -> DocNode {
        if includeUnknown, chance(0.12) { return unknownNode() }
        switch int(0...9) {
        case 0, 1:
            return .paragraph(align: align(), indent: indent(), content: inlines(context: .body))
        case 2:
            return .heading(level: int(1...3), align: align(), indent: indent(), content: inlines(context: .heading))
        case 3:
            return .codeBlock(align: align(), language: pick([nil, "swift", "python", "text", "brainfudge"]),
                              content: inlines(context: .code))
        case 4:
            var content = (0..<int(1...3)).map { _ in DocNode.paragraph(align: align(), indent: nil, content: inlines(context: .body)) }
            if includeUnknown, chance(0.2) { content.insert(unknownNode(), at: int(0...content.count)) }
            return .blockquote(indent: indent(), content: content)
        case 5:
            return .horizontalRule
        case 6, 7, 8:
            let kind = pick([ListKind.bullet, .ordered, .task])
            let checked: Bool? = kind == .task ? chance(0.5) : nil
            return .listItem(kind: kind, level: int(0...8), number: kind == .ordered ? int(1...120) : nil, checked: checked,
                             align: align(), content: inlines(context: checked == true ? .checkedItem : .body))
        default:
            return table()
        }
    }

    private mutating func table() -> DocNode {
        let columns = int(1...4)
        let hasHeader = chance(0.5)
        let rows = (0..<int(1...4)).map { row in
            (0..<columns).map { _ in
                TableCell(header: hasHeader && row == 0, content: (0..<int(1...2)).map { _ in
                    DocNode.paragraph(align: align(), indent: nil, content: inlines(context: .body))
                })
            }
        }
        var widths: [Double]?
        if chance(0.5) {
            var parts = (0..<columns).map { _ in Double(int(10...40)) }
            parts[columns - 1] += 100 - parts.reduce(0, +)
            widths = parts
        }
        return .table(columnWidths: widths, rows: rows)
    }

    private mutating func align() -> Align? {
        chance(0.6) ? nil : pick([.left, .center, .right, .justify])
    }

    private mutating func indent() -> Int? {
        chance(0.6) ? nil : int(1...8)
    }

    // MARK: - Inline content

    private enum InlineContext { case body, heading, code, checkedItem }

    private mutating func inlines(context: InlineContext) -> [Inline] {
        var content: [Inline] = []
        for _ in 0..<int(0...5) {
            switch int(0...9) {
            case 0 where !content.isEmpty:
                content.append(.hardBreak)
            case 1:
                content.append(image())
            case 2 where context != .heading:
                content.append(fileAttachment())
            default:
                let marks = marks(context: context)
                if case .text(let previous, let previousMarks)? = content.last, previousMarks == marks {
                    content[content.count - 1] = .text(previous + " " + word(), marks: marks)
                } else {
                    content.append(.text(content.isEmpty ? word() : " " + word(), marks: marks))
                }
            }
        }
        return content
    }

    private mutating func marks(context: InlineContext) -> [Mark] {
        var marks: [Mark] = []
        if context != .heading, chance(0.2) { marks.append(.bold) }
        if chance(0.2) { marks.append(.italic) }
        if chance(0.15) { marks.append(.underline) }
        if context != .checkedItem, chance(0.15) { marks.append(.strike) }
        if context != .code, chance(0.12) { marks.append(.code) }
        if chance(0.12) {
            let id = uuid().uuidString
            marks.append(.link(href: pick(["https://example.com/\(word())", "http://example.org/a?b=c", "mailto:someone@example.com",
                                           "tel:+15551234567", "noteit://note/\(id)", "noteit://note/\(id)?heading=Intro",
                                           "noteit://note?title=Plan"])))
        }
        if context != .checkedItem, chance(0.15) { marks.append(.textColor(color())) }
        if chance(0.12) { marks.append(.highlight(color())) }
        if chance(0.12) { marks.append(.fontSize(delta: pick([-3, -2, -1, 1, 2, 4, 8, 12]))) }
        return marks
    }

    private mutating func color() -> String {
        String(format: "#%02X%02X%02X", int(0...255), int(0...255), int(0...255))
    }

    private mutating func image() -> Inline {
        let (ext, mime) = pick([("png", "image/png"), ("jpg", "image/jpeg"), ("gif", "image/gif")])
        let sha = store(mime: mime, name: "\(word()).\(ext)")
        let attachment = attachments[sha]!
        return .image(sha: sha, name: attachment.name, mime: mime, width: chance(0.5) ? nil : Double(int(40...600)))
    }

    private mutating func fileAttachment() -> Inline {
        let (ext, mime) = pick([("pdf", "application/pdf"), ("zip", "application/zip"), ("txt", "text/plain")])
        let sha = store(mime: mime, name: "\(word()).\(ext)")
        return .attachment(sha: sha, name: attachments[sha]!.name, mime: mime)
    }

    /// Stores random bytes under their hash; reuses an earlier attachment now and then.
    private mutating func store(mime: String, name: String) -> String {
        if chance(0.2), let earlier = attachments.filter({ $0.value.mime == mime }).keys.sorted().first { return earlier }
        let data = Data((0..<int(8...64)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        attachments[sha] = Attachment(mime: mime, name: name, data: data)
        return sha
    }

    private static let words = ["note", "plan", "idea", "list", "draft", "Alpha", "beta", "Gamma", "kaffe", "smörgås",
                                "naïve", "café", "日本", "emoji😀", "x", "longerword", "Q3", "it's", "(aside)", "end."]

    private mutating func word() -> String {
        pick(Self.words)
    }

    // MARK: - Unknown nodes

    private mutating func unknownNode() -> DocNode {
        let type = pick(["callout", "x-embed", "mathBlock", "futureThing"])
        var members: [String: JSONValue] = ["type": .string(type)]
        if chance(0.7) { members["attrs"] = randomJSON(depth: 1) }
        if chance(0.5) { members["content"] = .array([.object(["type": .string("paragraph")])]) }
        let json = try! JSONValue.object(members).encoded()
        return .unknown(type: type, json: json)
    }

    private mutating func randomJSON(depth: Int) -> JSONValue {
        switch depth > 2 ? int(0...3) : int(0...5) {
        case 0: return .null
        case 1: return .bool(chance(0.5))
        case 2: return .number(pick(["0", "-0", "1.50", "9007199254740993", "-12", "3e+5", "2.5E-3"]))
        case 3: return .string(pick(["", "s/t", "quote\"d", "tab\tnew\nline", "ünï"]))
        case 4: return .array((0..<int(0...3)).map { _ in randomJSON(depth: depth + 1) })
        default:
            var members: [String: JSONValue] = [:]
            for _ in 0..<int(0...3) { members[pick(["a", "b", "Z", "key", "é"])] = randomJSON(depth: depth + 1) }
            return .object(members)
        }
    }

    // MARK: - Random primitives

    private mutating func uuid() -> UUID {
        let a = random.next(), b = random.next()
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: a >> ($0 * 8)) } + (0..<8).map { UInt8(truncatingIfNeeded: b >> ($0 * 8)) }
        bytes[6] = bytes[6] & 0x0F | 0x40
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(random.next() % UInt64(range.count))
    }

    private mutating func chance(_ probability: Double) -> Bool {
        Double(random.next() >> 11) / Double(1 << 53) < probability
    }

    private mutating func pick<T>(_ items: [T]) -> T {
        items[int(0...(items.count - 1))]
    }
}

/// SplitMix64: small, fast and the same on every platform.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
