import Foundation

/// The editor's per-paragraph block tags. RTFD drops custom attributes, so each block kind is written as
/// a sentinel `defaultTabInterval`, which RTF keeps per paragraph. Moved from `EditorStyle` in foundations
/// Task 2.1 (shape owned by the web-app plan); the values never change, because stored notes carry them.
public enum BlockSentinels {
    public static let body: Double = 29
    public static let code: Double = 31
    public static let quote: Double = 33
    public static let divider: Double = 35
    public static let title: Double = 37
    public static let heading: Double = 39
    public static let subheading: Double = 41
}
