import AppKit

/// Settings › Editor › Code. Everything here is applied at display time, so changing a setting
/// restyles open notes without rewriting them.
enum InlineCodeColor: String, CaseIterable, Identifiable {
    case pink, purple, blue, green, orange, gray, accent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accent: "Accent Color"
        default: rawValue.capitalized
        }
    }

    private var hues: (lightText: UInt32, darkText: UInt32, fill: UInt32, lightAlpha: CGFloat, darkAlpha: CGFloat)? {
        switch self {
        case .pink: (0xC0286A, 0xFF7EB3, 0xE8357A, 0.10, 0.17)
        case .purple: (0x8338C9, 0xC9A1FF, 0x9147E0, 0.10, 0.19)
        case .blue: (0x1D62C4, 0x82B8FF, 0x2F7AF0, 0.10, 0.19)
        case .green: (0x237A36, 0x80DB93, 0x30A54E, 0.11, 0.17)
        case .orange: (0xAD5300, 0xFFB466, 0xF08A24, 0.13, 0.18)
        case .gray: (0x3A3A40, 0xE3E3E8, 0x787880, 0.11, 0.24)
        case .accent: nil
        }
    }

    var textColor: NSColor {
        guard let h = hues else {
            return NSColor(name: nil) { appearance in
                let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
                return appearance.isDark ? accent.blended(withFraction: 0.35, of: .white) ?? accent
                    : accent.blended(withFraction: 0.18, of: .black) ?? accent
            }
        }
        let light = NSColor(rgb: h.lightText), dark = NSColor(rgb: h.darkText)
        return NSColor(name: nil) { $0.isDark ? dark : light }
    }

    var fillColor: NSColor {
        guard let h = hues else {
            return NSColor(name: nil) { appearance in
                NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.2 : 0.11)
            }
        }
        let light = NSColor(rgb: h.fill, alpha: h.lightAlpha), dark = NSColor(rgb: h.fill, alpha: h.darkAlpha)
        return NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

enum InlineCodeFont: String, CaseIterable, Identifiable {
    case monospaced, sameAsText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monospaced: "Monospaced"
        case .sameAsText: "Same as Text"
        }
    }
}

struct CodeStyleSettings: Equatable {
    var inlineColor: InlineCodeColor
    var inlineFont: InlineCodeFont
    var theme: CodeTheme
    var highlighting: Bool

    static let `default` = CodeStyleSettings(inlineColor: .pink, inlineFont: .monospaced, theme: .xcode, highlighting: true)

    static var current: CodeStyleSettings {
        let d = UserDefaults.standard
        return CodeStyleSettings(
            inlineColor: d.string(forKey: PrefKey.inlineCodeColor).flatMap(InlineCodeColor.init(rawValue:)) ?? .pink,
            inlineFont: d.string(forKey: PrefKey.inlineCodeFont).flatMap(InlineCodeFont.init(rawValue:)) ?? .monospaced,
            theme: CodeTheme.named(d.string(forKey: PrefKey.codeBlockTheme)),
            highlighting: d.object(forKey: PrefKey.syntaxHighlighting) as? Bool ?? true)
    }
}
