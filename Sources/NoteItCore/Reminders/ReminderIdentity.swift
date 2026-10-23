import CryptoKit
import Foundation

public enum ReminderIdentity {
    /// The same on every Mac: a version 8 UUID from SHA-256 of the note, the token time and the line text.
    public static func id(noteID: UUID, at: LocalDateTime, lineText: String) -> UUID {
        let input = "reminder\u{0}" + noteID.uuidString + "\u{0}" + at.token + "\u{0}" + TaskParser.displayText(lineText)
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
