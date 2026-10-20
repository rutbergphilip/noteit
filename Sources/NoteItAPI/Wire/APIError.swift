import Foundation

/// A Local API error code. Shape and the full list owned by the automation plan; the codes other sub-projects
/// rely on and their statuses are program §10's. Built in foundations Task 5.1. It is an `Error`, so it can be
/// `Result`'s failure type and can be thrown.
public enum APIErrorCode: String, Codable, Sendable, Error, CaseIterable {
    case badRequest = "bad_request", unauthorized, tokenRevoked = "token_revoked", forbiddenScope = "forbidden_scope",
         originNotAllowed = "origin_not_allowed", pairingDenied = "pairing_denied", pairingFailed = "pairing_failed",
         notFound = "not_found", noteDeleted = "note_deleted", noteUnreadable = "note_unreadable",
         pairingInProgress = "pairing_in_progress", cursorExpired = "cursor_expired", lengthRequired = "length_required",
         revisionMismatch = "revision_mismatch", tooLarge = "too_large", unsupportedMediaType = "unsupported_media_type",
         misdirected, rateLimited = "rate_limited", `internal`, apiDisabled = "api_disabled",
         /// Not built into this version yet (daily notes while `DailyNotes.isAvailable` is false, the tag tree
         /// without a provider).
         notImplemented = "not_implemented",
         /// Built but turned off (a search mode).
         notAvailable = "not_available",
         /// A note in a shared notebook the user can only read (sharing).
         readOnly = "read_only",
         noteLocked = "note_locked",
         /// Plugins only: the change needs an open editor.
         editorRequired = "editor_required",
         /// The library is still loading.
         notReady = "not_ready"

    public var httpStatus: Int {
        switch self {
        case .badRequest: return 400
        case .unauthorized, .tokenRevoked: return 401
        case .forbiddenScope, .originNotAllowed, .pairingDenied, .pairingFailed, .readOnly: return 403
        case .notFound: return 404
        case .noteDeleted, .noteUnreadable, .pairingInProgress, .editorRequired: return 409
        case .cursorExpired: return 410
        case .lengthRequired: return 411
        case .revisionMismatch: return 412
        case .tooLarge: return 413
        case .unsupportedMediaType: return 415
        case .misdirected: return 421
        case .noteLocked: return 423
        case .rateLimited: return 429
        case .internal: return 500
        case .notImplemented, .notAvailable: return 501
        case .apiDisabled, .notReady: return 503
        }
    }
}

/// `{"error":{"code":"not_found","message":"…"}}`. Built in foundations Task 5.1 (automation).
public struct APIErrorBody: Codable, Sendable, Equatable {
    public struct Inner: Codable, Sendable, Equatable {
        public var code: APIErrorCode
        public var message: String
        public init(code: APIErrorCode, message: String) {
            self.code = code
            self.message = message
        }
    }

    public var error: Inner

    public init(error: Inner) { self.error = error }
    public init(code: APIErrorCode, message: String) { self.error = Inner(code: code, message: message) }
}
