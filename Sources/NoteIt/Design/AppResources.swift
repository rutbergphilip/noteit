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
}
