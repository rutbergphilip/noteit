import Foundation

/// The per-attachment size cap. Shape owned by the web-app plan (Task 0.6); built in foundations Task 2.1.
public enum AttachmentLimit {
    /// 25 MB, the same as TS `MAX_ATTACHMENT_BYTES`.
    public static let maxBytes = 26_214_400

    public static func allows(byteCount: Int) -> Bool {
        byteCount <= maxBytes
    }

    public static func tooLargeMessage(name: String) -> String {
        "“\(name)” is too large to add. Attachments can be up to 25 MB."
    }
}
