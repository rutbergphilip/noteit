import AppKit
import SwiftUI

struct Notebook: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var colorHex: String
    var sortIndex: Int
    var revision: UUID? = nil
    var modifiedAt: Date? = nil
}

struct NoteMeta: Identifiable, Codable, Hashable {
    var id: UUID
    var notebookID: UUID?
    var title: String
    var preview: String
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
    var revision: UUID? = nil
    /// Device name when this note is a sync conflict copy.
    var conflictSource: String? = nil
}

enum SidebarSelection: Hashable {
    case allNotes, pinned, recent, notebook(UUID), tag(String)
}

extension Notebook {
    var color: Color { Color(hex: colorHex) }
}

extension NoteMeta {
    var displayTitle: String { title.isEmpty ? "New Note" : title }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else if s.count == 6 {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        } else {
            r = 0.5; g = 0.5; b = 0.5; a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Curated palette and symbols used by the notebook editor.
enum NotebookPalette {
    static let colors: [String] = [
        "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#FF453A",
        "#FF9F0A", "#FFD60A", "#30D158", "#64D2FF", "#8E8E93",
    ]

    static let symbols: [String] = [
        "tray", "command", "lightbulb", "book", "bookmark", "folder",
        "doc.text", "pencil", "star", "heart", "flag", "tag",
        "briefcase", "house", "cart", "graduationcap", "hammer", "wrench.and.screwdriver",
        "paintbrush", "music.note", "film", "camera", "airplane", "globe",
        "leaf", "flame", "bolt", "brain.head.profile", "terminal", "chevron.left.forwardslash.chevron.right",
        "person.2", "calendar",
    ]
}
