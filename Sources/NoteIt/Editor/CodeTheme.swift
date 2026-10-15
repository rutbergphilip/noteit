import AppKit

/// Syntax colors for code blocks. Each theme has a light and a dark palette; the dynamic colors
/// follow the editor's appearance and are only ever applied as layout-manager temporary attributes.
struct CodeTheme: Identifiable, Equatable {
    struct Palette {
        var plain: UInt32
        var keyword: UInt32
        var string: UInt32
        var comment: UInt32
        var number: UInt32
        var type: UInt32
        var property: UInt32
        var punctuation: UInt32
        /// Card fill; nil keeps the editor's neutral code background.
        var background: UInt32?

        func hex(for kind: TokenKind?) -> UInt32 {
            switch kind {
            case nil: plain
            case .keyword: keyword
            case .string: string
            case .comment: comment
            case .number: number
            case .type: type
            case .property: property
            case .punctuation: punctuation
            }
        }
    }

    let id: String
    let name: String
    let light: Palette
    let dark: Palette

    static func == (a: CodeTheme, b: CodeTheme) -> Bool { a.id == b.id }

    static let xcode = CodeTheme(
        id: "xcode", name: "Xcode",
        light: Palette(plain: 0x1F1F24, keyword: 0x9B2393, string: 0xC41A16, comment: 0x5D6C79, number: 0x1C00CF,
                       type: 0x0B4F79, property: 0x326D74, punctuation: 0x4A4A52, background: nil),
        dark: Palette(plain: 0xDFDFE0, keyword: 0xFC5FA3, string: 0xFC6A5D, comment: 0x7F8C98, number: 0xD0BF69,
                      type: 0x5DD8FF, property: 0x67B7A4, punctuation: 0xB4B4B9, background: nil))

    static let github = CodeTheme(
        id: "github", name: "GitHub",
        light: Palette(plain: 0x1F2328, keyword: 0xCF222E, string: 0x0A3069, comment: 0x6E7781, number: 0x0550AE,
                       type: 0x953800, property: 0x8250DF, punctuation: 0x57606A, background: 0xF6F8FA),
        dark: Palette(plain: 0xE6EDF3, keyword: 0xFF7B72, string: 0xA5D6FF, comment: 0x8B949E, number: 0x79C0FF,
                      type: 0xFFA657, property: 0xD2A8FF, punctuation: 0xADBAC7, background: 0x161B22))

    static let solarized = CodeTheme(
        id: "solarized", name: "Solarized",
        light: Palette(plain: 0x586E75, keyword: 0x859900, string: 0x2AA198, comment: 0x93A1A1, number: 0xD33682,
                       type: 0xB58900, property: 0x268BD2, punctuation: 0x657B83, background: 0xFDF6E3),
        dark: Palette(plain: 0x93A1A1, keyword: 0x859900, string: 0x2AA198, comment: 0x657B83, number: 0xD33682,
                      type: 0xB58900, property: 0x268BD2, punctuation: 0x839496, background: 0x002B36))

    static let nord = CodeTheme(
        id: "nord", name: "Nord",
        light: Palette(plain: 0x2E3440, keyword: 0x5E81AC, string: 0x4F7D3A, comment: 0x7B88A1, number: 0x9A6A94,
                       type: 0x3B8A8C, property: 0x4C7BA6, punctuation: 0x4C566A, background: 0xECEFF4),
        dark: Palette(plain: 0xD8DEE9, keyword: 0x81A1C1, string: 0xA3BE8C, comment: 0x7B88A1, number: 0xB48EAD,
                      type: 0x8FBCBB, property: 0x88C0D0, punctuation: 0xA7B1C2, background: 0x2E3440))

    static let all: [CodeTheme] = [xcode, github, solarized, nord]

    static func named(_ id: String?) -> CodeTheme {
        all.first { $0.id == id } ?? xcode
    }

    // MARK: Colors

    nonisolated(unsafe) private static var cache: [String: NSColor] = [:]

    /// Dynamic color for `kind` (nil = plain text).
    func color(for kind: TokenKind?) -> NSColor {
        let key = "\(id).\(kind.map { "\($0)" } ?? "plain")"
        if let cached = Self.cache[key] { return cached }
        let light = NSColor(rgb: self.light.hex(for: kind))
        let dark = NSColor(rgb: self.dark.hex(for: kind))
        let color = NSColor(name: nil) { $0.isDark ? dark : light }
        Self.cache[key] = color
        return color
    }

    /// Card fill, or nil for the neutral editor code background.
    var background: NSColor? {
        guard let l = light.background, let d = dark.background else { return nil }
        let key = "\(id).background"
        if let cached = Self.cache[key] { return cached }
        let lightColor = NSColor(rgb: l), darkColor = NSColor(rgb: d)
        let color = NSColor(name: nil) { $0.isDark ? darkColor : lightColor }
        Self.cache[key] = color
        return color
    }
}

extension NSColor {
    convenience init(rgb hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
