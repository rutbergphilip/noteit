import Foundation
import NoteItAPI

/// Every automation surface's errors, mapped per surface: an `APIErrorCode` for the Local API, `errorCode` and
/// `errorMessage` for x-callback-url, `message` for Shortcuts and the Share extension.
enum AutomationError: Error, Equatable {
    case notFound, noteDeleted, noteUnreadable, noteLocked, notReady, notebookNotFound, invalidInput(String),
         revisionMismatch(current: UUID?), formatUnavailable(String), tooLarge, dailyNotesUnavailable, cancelled,
         versionNotSaved

    var apiCode: APIErrorCode {
        switch self {
        case .notFound, .notebookNotFound: .notFound
        case .noteDeleted: .noteDeleted
        case .noteUnreadable: .noteUnreadable
        case .noteLocked: .noteLocked
        case .notReady: .notReady
        case .invalidInput, .cancelled: .badRequest
        case .revisionMismatch: .revisionMismatch
        case .formatUnavailable, .dailyNotesUnavailable: .notImplemented
        case .tooLarge: .tooLarge
        case .versionNotSaved: .internal
        }
    }

    /// The x-callback-url `errorCode`.
    var callbackCode: String {
        if case .cancelled = self { return "cancelled" }
        return apiCode.rawValue
    }

    var message: String {
        switch self {
        case .notFound: "No note with that id."
        case .noteDeleted: "That note is in Recently Deleted."
        case .noteUnreadable: "That note couldn't be read, so it can't be changed."
        case .noteLocked: "That note is locked."
        case .notReady: "NoteIt is still opening your notes. Try again in a moment."
        case .notebookNotFound: "No notebook with that name."
        case .invalidInput(let text): text
        case .revisionMismatch: "That note was changed since you read it."
        case .formatUnavailable: "That format isn't available in this version."
        case .tooLarge: "That's too large."
        case .dailyNotesUnavailable: "Daily notes aren't available in this version."
        case .cancelled: "Cancelled."
        case .versionNotSaved: "Couldn't save a version of the note, so it wasn't changed."
        }
    }
}
