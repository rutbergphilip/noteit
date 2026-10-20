import Foundation

/// Paragraph-level block kinds the editor understands. Moved from the app in foundations Task 2.1.
///
/// RTFD drops custom attributes and plain `NSTextBlock`s, so special blocks are tagged with a
/// sentinel `defaultTabInterval` (see `BlockSentinels`). Headings and body paragraphs written by the
/// editor carry sentinels too, so their identity doesn't depend on font size relative to the
/// (user-adjustable) body size.
public enum BlockKind: String, CaseIterable, Identifiable, Sendable {
    case title, heading, subheading, body, code, quote, divider

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .code: "Monospaced"
        case .quote: "Quote"
        case .divider: "Divider"
        }
    }

    public static let menuCases: [BlockKind] = [.title, .heading, .subheading, .body, .code, .quote]
}
