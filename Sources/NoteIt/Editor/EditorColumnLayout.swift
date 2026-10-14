import CoreGraphics

/// Horizontal geometry of the editor's text column: as wide as the editor allows, up to a maximum
/// reading width, and centered.
struct EditorColumnLayout: Equatable {
    var inset: CGFloat
    var containerWidth: CGFloat

    /// The column for an editor `width` points wide.
    static func fitting(
        width: CGFloat,
        maxReadingWidth: CGFloat = EditorStyle.maxReadingWidth,
        minInset: CGFloat = EditorStyle.minHorizontalInset
    ) -> EditorColumnLayout {
        let inset = max(minInset, floor((width - maxReadingWidth) / 2))
        return EditorColumnLayout(inset: inset, containerWidth: max(0, width - 2 * inset))
    }

    /// Keeps a column of `containerWidth` (so no text rewraps) centered in `width`. When it's wider than
    /// the editor allows, it stays at the minimum inset and its right edge is clipped.
    static func keeping(
        containerWidth: CGFloat,
        in width: CGFloat,
        minInset: CGFloat = EditorStyle.minHorizontalInset
    ) -> EditorColumnLayout {
        EditorColumnLayout(inset: max(minInset, floor((width - containerWidth) / 2)), containerWidth: containerWidth)
    }
}
