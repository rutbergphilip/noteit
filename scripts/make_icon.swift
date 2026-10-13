// Renders the NoteIt app icon into an .iconset directory. Run scripts/render_icon.sh to refresh
// Resources/AppIcon.iconset and the runtime copy; build_app.sh packs the committed iconset.
// Usage: make_icon <output.iconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(in ctx: CGContext, size s: CGFloat) {
    // Apple icon grid: 824/1024 body, ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = s * 185 / 1024
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(srgb(0x2B2D7A).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: deep indigo -> violet
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [srgb(0x6E5BFF).cgColor, srgb(0x3A3FD9).cgColor, srgb(0x1E2470).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Soft top glow
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.maxY), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY), endRadius: body.width * 0.8, options: [])

    // Paper sheet, slightly rotated
    ctx.saveGState()
    ctx.translateBy(x: body.midX - s * 0.03, y: body.midY - s * 0.02)
    ctx.rotate(by: -0.07)
    let paper = CGRect(x: -s * 0.24, y: -s * 0.29, width: s * 0.48, height: s * 0.58)
    let paperPath = CGPath(roundedRect: paper, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(paperPath)
    ctx.setFillColor(srgb(0xFBFAF7).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Header bar + text lines
    ctx.setFillColor(srgb(0x6E5BFF, 0.9).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: paper.minX + s * 0.05, y: paper.maxY - s * 0.11, width: s * 0.22, height: s * 0.035),
                       cornerWidth: s * 0.0175, cornerHeight: s * 0.0175, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(srgb(0xC9CBD6).cgColor)
    let widths: [CGFloat] = [0.36, 0.32, 0.36, 0.24, 0.30]
    for (i, w) in widths.enumerated() {
        let y = paper.maxY - s * 0.185 - CGFloat(i) * s * 0.07
        ctx.addPath(CGPath(roundedRect: CGRect(x: paper.minX + s * 0.05, y: y, width: s * w, height: s * 0.022),
                           cornerWidth: s * 0.011, cornerHeight: s * 0.011, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Quill / pen nib
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.30, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [srgb(0xFFC93C)]))
    if let symbol = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        ?? NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        ctx.saveGState()
        ctx.translateBy(x: body.midX + s * 0.17, y: body.midY - s * 0.06)
        ctx.rotate(by: 0)
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        let sz = symbol.size
        let rect = CGRect(x: -sz.width / 2, y: -sz.height / 2, width: sz.width, height: sz.height)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: rect)
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in variants {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    gctx.cgContext.clear(CGRect(x: 0, y: 0, width: px, height: px))
    drawIcon(in: gctx.cgContext, size: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try png.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("Wrote iconset to \(outDir.path)")
