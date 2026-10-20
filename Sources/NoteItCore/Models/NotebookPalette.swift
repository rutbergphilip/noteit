import Foundation

/// Curated palette and symbols used by the notebook editor. Moved from the app in foundations Task 1.1;
/// notebooks persist their colour as one of these hex strings.
public enum NotebookPalette {
    /// The 10 notebook swatches, in picker order.
    public static let colors: [String] = [
        "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#FF453A",
        "#FF9F0A", "#FFD60A", "#30D158", "#64D2FF", "#8E8E93",
    ]

    public static let symbols: [String] = [
        "tray", "command", "lightbulb", "book", "bookmark", "folder",
        "doc.text", "pencil", "star", "heart", "flag", "tag",
        "briefcase", "house", "cart", "graduationcap", "hammer", "wrench.and.screwdriver",
        "paintbrush", "music.note", "film", "camera", "airplane", "globe",
        "leaf", "flame", "bolt", "brain.head.profile", "terminal", "chevron.left.forwardslash.chevron.right",
        "person.2", "calendar",
    ]
}
