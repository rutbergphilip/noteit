import Foundation

/// Text recognised in a note's images. No provider exists yet; one registers through
/// `NoteStore.registerImageTextProvider(_:)`.
public protocol ImageTextProviding {
    func imageText(for noteID: UUID) -> String?
}
