import AppKit

/// Images shipped as SwiftPM resources (`Sources/NoteIt/Resources`).
///
/// Looks the resource bundle up itself instead of using `Bundle.module`: the generated accessor only
/// checks the `.app` root (where a nested bundle would break code signing) and an absolute build path,
/// and it traps when neither exists. `build_app.sh` copies the bundle into `Contents/Resources`.
enum AppResources {
    private static let bundleName = "NoteIt_NoteIt.bundle"

    static let bundle: Bundle? = {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for case let dir? in candidates {
            if let bundle = Bundle(url: dir.appendingPathComponent(bundleName)) { return bundle }
        }
        return nil
    }()

    @MainActor private static var cache: [String: NSImage] = [:]

    /// A PNG resource by base name; `@2x` variants are picked up automatically.
    @MainActor
    static func image(_ name: String, template: Bool = false, size: NSSize? = nil) -> NSImage? {
        let key = "\(name)|\(template)|\(size.map { "\($0.width)x\($0.height)" } ?? "")"
        if let cached = cache[key] { return cached }
        guard let image = bundle?.image(forResource: name) else { return nil }
        image.isTemplate = template
        if let size { image.size = size }
        cache[key] = image
        return image
    }

    /// The app icon artwork (`scripts/make_icon.swift`), for unbundled runs without an `.icns`.
    @MainActor static var appIcon: NSImage? { image("AppIcon") }

    /// The menu bar glyph (`scripts/make_menubar_glyph.swift`): a template image at 18 × 18 pt.
    /// With `draft`, a small dot in the corner shows that Quick Capture is holding an unsaved draft.
    @MainActor static func menuBarGlyph(capturing: Bool, draft: Bool = false) -> NSImage? {
        let size = NSSize(width: Tokens.Size.menuBarGlyph, height: Tokens.Size.menuBarGlyph)
        guard let base = image(capturing ? "noteit-menubar-capturingTemplate" : "noteit-menubarTemplate", template: true, size: size) else {
            return nil
        }
        guard draft, !capturing else { return base }
        let key = "noteit-menubar-draft"
        if let cached = cache[key] { return cached }
        let badged = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let dot = Tokens.Size.menuBarDraftDot
            let spot = NSRect(x: rect.maxX - dot - 0.5, y: rect.maxY - dot - 0.5, width: dot, height: dot)
            // Clear a ring around the dot so it stays readable on top of the glyph, then draw it.
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: spot.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: spot).fill()
            return true
        }
        badged.isTemplate = true
        cache[key] = badged
        return badged
    }
}
