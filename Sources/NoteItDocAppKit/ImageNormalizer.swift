import Foundation
import ImageIO
import NoteItDoc
import UniformTypeIdentifiers

/// Applies `ImagePolicy` to an image's bytes on export. Shape owned by the web-app plan (spec §3.5); built in
/// foundations Task 2.3. `.normalize` turns TIFF and BMP into PNG and HEIC/HEIF into JPEG at quality 0.9, because
/// browsers can't show them; everything else, and anything that fails to decode, keeps its bytes.
public enum ImageNormalizer {
    public static let jpegQuality = 0.9

    public static func normalized(_ data: Data, mime: String, policy: ImagePolicy) -> (data: Data, mime: String) {
        guard policy == .normalize, let target = target(for: mime),
              let converted = convert(data, to: target.type) else { return (data, mime) }
        return (converted, target.mime)
    }

    private static func target(for mime: String) -> (type: UTType, mime: String)? {
        switch mime.lowercased() {
        case "image/tiff", "image/bmp", "image/x-bmp", "image/x-ms-bmp": (.png, "image/png")
        case "image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence": (.jpeg, "image/jpeg")
        default: nil
        }
    }

    private static func convert(_ data: Data, to type: UTType) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = original[kCGImagePropertyOrientation] {
            properties[kCGImagePropertyOrientation] = orientation
        }
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
