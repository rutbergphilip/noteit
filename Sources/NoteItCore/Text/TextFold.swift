import Foundation

/// Case-, diacritic- and width-insensitive folding shared by search and fuzzy matching.
/// Moved from `NoteStore.fold` in foundations Task 1.2.
public enum TextFold {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }
}
