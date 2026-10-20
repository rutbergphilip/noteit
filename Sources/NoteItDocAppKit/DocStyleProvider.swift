import AppKit
import NoteItDoc

/// The fonts the converter builds and reads text with, so it runs headless with any base size. Shape owned by the
/// web-app plan; built in foundations Task 2.3. The app's implementation is `AppDocStyleProvider`.
public protocol DocStyleProvider {
    /// The body text size in points.
    var baseFontSize: CGFloat { get }
    /// The font of a `block` paragraph when the body text size is `size`.
    func font(for block: BlockKind, size: CGFloat) -> NSFont
    /// The inline code font when the body text size is `size`.
    func monospacedFont(size: CGFloat) -> NSFont
}
