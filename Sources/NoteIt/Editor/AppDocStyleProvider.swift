import AppKit

/// The editor's fonts for `DocConverter`, read from `EditorStyle`. Owned by the foundations plan (Task 2.3).
struct AppDocStyleProvider: DocStyleProvider {
    static let shared = AppDocStyleProvider()

    var baseFontSize: CGFloat { EditorStyle.bodySize }

    func font(for block: BlockKind, size: CGFloat) -> NSFont {
        EditorStyle.font(for: block, bodySize: size)
    }

    func monospacedFont(size: CGFloat) -> NSFont {
        EditorStyle.inlineCodeFont(bodySize: size)
    }
}
