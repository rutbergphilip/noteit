import AppKit
import NoteItDoc
import NoteItDocAppKit

/// The editor's font formulas at a fixed base size, so the tests don't read user defaults.
struct TestStyles: DocStyleProvider {
    var baseFontSize: CGFloat = 14

    func font(for block: BlockKind, size: CGFloat) -> NSFont {
        switch block {
        case .title: .systemFont(ofSize: size + 12, weight: .bold)
        case .heading: .systemFont(ofSize: size + 5, weight: .semibold)
        case .subheading: .systemFont(ofSize: size + 1.5, weight: .semibold)
        case .code: .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        case .body, .quote, .divider: .systemFont(ofSize: size)
        }
    }

    func monospacedFont(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size - 1, weight: .medium)
    }
}
