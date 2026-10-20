import Foundation

/// How images are stored on export. A pure policy value; NoteItDocAppKit's `ImageNormalizer` applies it, so
/// NoteItDoc has no ImageIO code. Owned by the web-app plan; built in foundations Task 2.1.
public enum ImagePolicy: String, Codable, Sendable {
    /// TIFF and BMP become PNG, HEIC becomes JPEG at quality 0.9.
    case normalize
    case keepOriginal
}
