import Foundation
import NoteItDoc

public enum MarkdownError: Error, Equatable {
    case invalidFrontMatter(line: Int)
    case notUTF8
}
