import AppKit
import CryptoKit
import NoteItDoc
import UniformTypeIdentifiers

/// Converts between the editor's `NSAttributedString` and a `noteit-doc` container. Shape owned by the web-app plan
/// (spec §3.3 and §3.5); built in foundations Task 2.3.
///
/// How native attributes map, and what foreign (pasted) attributes become:
///
/// | Native | noteit-doc |
/// |---|---|
/// | paragraph sentinel (`BlockSentinels`), legacy fonts without one | block kind |
/// | list marker text and list indent | `listItem` kind, level, number, checked |
/// | checked item strike and gray | derived from `checked`, never a mark |
/// | bold / italic font traits | `bold` / `italic`; headings never export `bold` |
/// | monospaced font outside a code block | `code`; dropped inside code blocks |
/// | point size against the block's base font | `fontSize{delta}` |
/// | underline / strikethrough style | `underline` / `strike` |
/// | `.link` | `link{href}` |
/// | `.foregroundColor` / `.backgroundColor` (sRGB) | `textColor` / `highlight`; the legacy inline-code gray is dropped |
/// | `NSTextAttachment` file | `image` (PNG, JPEG, GIF, WebP) or `attachment` |
/// | `NSTextTable` cells | `table`; a cell background marks a header |
/// | code-language tab stop, `noteItCodeLanguageID` | `codeBlock.language` |
/// | U+2028, with `noteItSoftBreak` or without | `softBreak` / `hardBreak` |
/// | other fonts, kerning, shadows, baseline and similar | dropped |
public enum DocConverter {
    public static func export(_ text: NSAttributedString, styles: DocStyleProvider, imagePolicy: ImagePolicy = .normalize) throws -> BodyContainer {
        var exporter = DocExporter(text: text, styles: styles, imagePolicy: imagePolicy)
        return try exporter.run()
    }

    public static func importDocument(_ body: BodyContainer, styles: DocStyleProvider) throws -> NSAttributedString {
        var importer = DocImporter(styles: styles, attachments: body.attachments)
        return try importer.run(body.doc)
    }
}

/// Why a document can't be turned into editor text: it holds content the editor can't show (read-only documents).
public struct DocConversionError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

enum ConverterSupport {
    static func align(_ alignment: NSTextAlignment) -> Align? {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justify
        default: nil
        }
    }

    static func alignment(_ align: Align?) -> NSTextAlignment {
        switch align {
        case .left?: .left
        case .center?: .center
        case .right?: .right
        case .justify?: .justified
        case nil: .natural
        }
    }

    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { min(255, max(0, Int((value * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    static func color(hex: String) -> NSColor? {
        guard DocValidationSupport.isColor(hex), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func mime(forFileName name: String) -> String? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    /// Image types every browser shows inline; anything else exports as an attachment chip.
    static let inlineImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func isImage(mime: String) -> Bool {
        UTType(mimeType: mime)?.conforms(to: .image) ?? false
    }
}

enum DocValidationSupport {
    static func isColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return false }
        return bytes.dropFirst().allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
    }
}
