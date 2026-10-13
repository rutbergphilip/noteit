// Renders the NoteIt app icon (white squiggle + pencil on the violet → indigo gradient) into an
// .iconset directory. Run scripts/render_icon.sh to refresh Resources/AppIcon.iconset and the runtime
// copy; build_app.sh packs the committed iconset.
// Usage: make_icon <output.iconset>
//
// The artwork is the original in-app icon view: a top-leading → bottom-trailing gradient of
// #6E5BFF, #3A3FD9, #1E2470 with the SF Symbol `pencil.and.scribble` in white, semibold, at 46/84 of
// the body. It sits on the macOS icon grid: an 824/1024 continuous squircle with a soft drop shadow.
// At 32 px the glyph is bolder and slightly larger; at 16 px it is the pencil alone, to stay legible.
// (The paper-sheet alternative lives in design/assets/app-icon/alt-paper.)
import AppKit
import SwiftUI

func hex(_ value: UInt32) -> Color {
    Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255)
}

struct IconArtwork: View {
    let px: CGFloat

    var body: some View {
        let side = px * 824 / 1024
        let small = px <= 32
        // 16 px: the squiggle turns to mush, so only the pencil; 32 px: a bolder, slightly larger scribble.
        let symbol = px <= 16 ? "pencil" : "pencil.and.scribble"
        let glyphScale = px <= 16 ? 0.66 : (small ? 0.58 : 0.46 / 0.84)
        RoundedRectangle(cornerRadius: side * 185.4 / 824, style: .continuous)
            .fill(LinearGradient(colors: [hex(0x6E5BFF), hex(0x3A3FD9), hex(0x1E2470)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: side * glyphScale, weight: small ? .bold : .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(small ? 0.2 : 0.3), radius: px * 0.015, y: px * 0.01)
            .frame(width: px, height: px)
    }
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

MainActor.assumeIsolated {
    for (name, px) in variants {
        let renderer = ImageRenderer(content: IconArtwork(px: CGFloat(px)))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { fatalError("render \(name)") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
        try! png.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
print("Wrote iconset to \(outDir.path)")
