// Renders the NoteIt menu bar glyph (squiggle + pencil, the app icon's motif) as template images.
// Usage: make_menubar_glyph <png-dir> <svg-dir>
// Writes noteit-menubarTemplate(.png|@2x.png|.svg) and noteit-menubar-capturingTemplate(…): the same
// glyph plus a small spark, shown while Quick Capture is open. Every format is drawn from the shapes
// below, on an 18 × 18 pt grid (y down), in black on transparent; macOS tints template images.
import AppKit

enum Segment {
    case move(CGPoint), line(CGPoint), curve(CGPoint, CGPoint, CGPoint), close
}

struct Shape {
    enum Paint { case fill, stroke(CGFloat) }
    var segments: [Segment]
    var paint: Paint
}

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// The scribble the pencil has just drawn.
let squiggle = Shape(segments: [
    .move(p(2.2, 14.6)),
    .curve(p(3.0, 12.2), p(4.7, 11.4), p(5.1, 12.9)),
    .curve(p(5.5, 14.4), p(4.3, 15.9), p(6.0, 15.7)),
    .curve(p(7.0, 15.6), p(7.6, 14.9), p(8.3, 14.2)),
], paint: .stroke(1.5))

/// A pencil at 45°, tip on the end of the squiggle: cone + body, then a separate eraser cap.
func pencil() -> [Shape] {
    let tip = p(9.0, 13.0), end = p(16.0, 6.0)
    let length = hypot(end.x - tip.x, end.y - tip.y)
    let d = p((end.x - tip.x) / length, (end.y - tip.y) / length)
    let n = p(-d.y, d.x)
    let half: CGFloat = 1.75, cone: CGFloat = 2.7, capLength: CGFloat = 2.0, gap: CGFloat = 0.85
    func at(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
        p(tip.x + d.x * along + n.x * side, tip.y + d.y * along + n.y * side)
    }
    let bodyEnd = length - capLength - gap
    let body = Shape(segments: [
        .move(tip), .line(at(cone, half)), .line(at(bodyEnd, half)), .line(at(bodyEnd, -half)),
        .line(at(cone, -half)), .close,
    ], paint: .fill)
    // Rounded end: the outer corners become a curve through the end point.
    let capStart = bodyEnd + gap
    let cap = Shape(segments: [
        .move(at(capStart, half)), .line(at(length - 0.9, half)),
        .curve(at(length, half), at(length, -half), at(length - 0.9, -half)),
        .line(at(capStart, -half)), .close,
    ], paint: .fill)
    return [body, cap]
}

/// Four-point spark, top left: "capturing".
func spark(center c: CGPoint, outer: CGFloat, inner: CGFloat) -> Shape {
    var segments: [Segment] = []
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 - .pi / 2
        let r = i.isMultiple(of: 2) ? outer : inner
        let point = p(c.x + cos(angle) * r, c.y + sin(angle) * r)
        segments.append(i == 0 ? .move(point) : .line(point))
    }
    segments.append(.close)
    return Shape(segments: segments, paint: .fill)
}

let idle = [squiggle] + pencil()
let capturing = idle + [spark(center: p(4.6, 4.8), outer: 3.4, inner: 1.2)]

// MARK: - Output

let grid: CGFloat = 18

func svg(_ shapes: [Shape]) -> String {
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".00", with: "") }
    func pt(_ q: CGPoint) -> String { "\(f(q.x)) \(f(q.y))" }
    var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"18\" viewBox=\"0 0 18 18\">\n"
    for shape in shapes {
        let d = shape.segments.map { segment -> String in
            switch segment {
            case .move(let a): return "M\(pt(a))"
            case .line(let a): return "L\(pt(a))"
            case .curve(let a, let b, let c): return "C\(pt(a)) \(pt(b)) \(pt(c))"
            case .close: return "Z"
            }
        }.joined(separator: " ")
        switch shape.paint {
        case .fill:
            out += "  <path d=\"\(d)\" fill=\"#000\"/>\n"
        case .stroke(let width):
            out += "  <path d=\"\(d)\" fill=\"none\" stroke=\"#000\" stroke-width=\"\(f(width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
        }
    }
    return out + "</svg>\n"
}

func png(_ shapes: [Shape], scale: CGFloat) -> Data {
    let px = Int(grid * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
    // Flip to the SVG's y-down grid.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for shape in shapes {
        let path = CGMutablePath()
        for segment in shape.segments {
            switch segment {
            case .move(let a): path.move(to: a)
            case .line(let a): path.addLine(to: a)
            case .curve(let a, let b, let c): path.addCurve(to: c, control1: a, control2: b)
            case .close: path.closeSubpath()
            }
        }
        ctx.addPath(path)
        switch shape.paint {
        case .fill: ctx.fillPath()
        case .stroke(let width):
            ctx.setLineWidth(width)
            ctx.strokePath()
        }
    }
    // Point size (sets the PNG's DPI) only after drawing, so the context works in pixels.
    rep.size = NSSize(width: grid, height: grid)
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
let pngDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let svgDir = URL(fileURLWithPath: args.count > 2 ? args[2] : ".")
for dir in [pngDir, svgDir] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

for (name, shapes) in [("noteit-menubarTemplate", idle), ("noteit-menubar-capturingTemplate", capturing)] {
    try png(shapes, scale: 1).write(to: pngDir.appendingPathComponent("\(name).png"))
    try png(shapes, scale: 2).write(to: pngDir.appendingPathComponent("\(name)@2x.png"))
    try svg(shapes).write(to: svgDir.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
}
print("Wrote menu bar glyphs to \(pngDir.path) and \(svgDir.path)")
