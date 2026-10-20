import AppKit
import ImageIO
import NoteItDoc
import NoteItDocAppKit
import UniformTypeIdentifiers
import XCTest

final class ImageNormalizerTests: XCTestCase {
    func testTIFFBecomesPNG() throws {
        let tiff = try Self.encode(.tiff)
        let result = ImageNormalizer.normalized(tiff, mime: "image/tiff", policy: .normalize)
        XCTAssertEqual(result.mime, "image/png")
        XCTAssertEqual(Array(result.data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(Self.pixelSize(result.data), CGSize(width: 1, height: 1))
    }

    func testKeepOriginalKeepsTIFFBytes() throws {
        let tiff = try Self.encode(.tiff)
        let result = ImageNormalizer.normalized(tiff, mime: "image/tiff", policy: .keepOriginal)
        XCTAssertEqual(result.mime, "image/tiff")
        XCTAssertEqual(result.data, tiff)
    }

    func testHEICBecomesJPEG() throws {
        guard let heic = try? Self.encode(.heic) else { throw XCTSkip("This system can't encode HEIC") }
        let result = ImageNormalizer.normalized(heic, mime: "image/heic", policy: .normalize)
        XCTAssertEqual(result.mime, "image/jpeg")
        XCTAssertEqual(Array(result.data.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertEqual(ImageNormalizer.normalized(heic, mime: "image/heic", policy: .keepOriginal).data, heic)
    }

    func testUndecodableBytesAreKept() {
        let junk = Data("not an image".utf8)
        let result = ImageNormalizer.normalized(junk, mime: "image/tiff", policy: .normalize)
        XCTAssertEqual(result.mime, "image/tiff")
        XCTAssertEqual(result.data, junk)
    }

    func testExportAppliesPolicy() throws {
        let tiff = try Self.encode(.tiff)
        let wrapper = FileWrapper(regularFileWithContents: tiff)
        wrapper.preferredFilename = "shot.tiff"
        let text = NSMutableAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        text.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: NSRange(location: 0, length: text.length))

        let normalized = try DocConverter.export(text, styles: TestStyles())
        let png = try XCTUnwrap(normalized.attachments.values.first)
        XCTAssertEqual(png.mime, "image/png")
        XCTAssertEqual(png.name, "shot.png")

        let kept = try DocConverter.export(text, styles: TestStyles(), imagePolicy: .keepOriginal)
        let original = try XCTUnwrap(kept.attachments.values.first)
        XCTAssertEqual(original.data, tiff)
        XCTAssertEqual(original.name, "shot.tiff")
        guard case .doc(let blocks) = kept.doc, case .paragraph(_, _, let content)? = blocks.first,
              case .attachment(_, _, let mime)? = content.first else {
            return XCTFail("A TIFF kept as is isn't an inline image type, so it exports as a file attachment: \(kept.doc)")
        }
        XCTAssertEqual(mime, "image/tiff")
    }

    private static func encode(_ type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }

    private static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }
}
