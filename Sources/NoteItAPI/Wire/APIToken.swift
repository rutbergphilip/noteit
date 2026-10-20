import CryptoKit
import Foundation
import Security

/// Local API tokens and pairing codes. The app stores only `hash` and `hint`. Shape owned by the automation plan;
/// built in foundations Task 5.1.
public enum APIToken {
    public static let prefix = "nit_"

    /// `prefix` + base64url (no padding) of 32 random bytes: 47 characters.
    public static func generate() -> String {
        prefix + Data(randomBytes(32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// SHA-256, lowercase hex.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The first 8 characters.
    public static func hint(_ token: String) -> String { String(token.prefix(8)) }

    /// Constant-time in the length of the stored hash.
    public static func matches(_ token: String, hash stored: String) -> Bool {
        let candidate = Array(hash(token).utf8)
        let expected = Array(stored.utf8)
        var difference = UInt8(candidate.count == expected.count ? 0 : 1)
        for index in expected.indices {
            difference |= expected[index] ^ (index < candidate.count ? candidate[index] : 0)
        }
        return difference == 0
    }

    /// 6 digits, uniform.
    public static func pairingCode() -> String {
        // 4_294_000_000 is the largest multiple of 1_000_000 below 2^32, so the remainder is uniform.
        while true {
            let bytes = randomBytes(4)
            let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if value < 4_294_000_000 {
                return String(format: "%06u", value % 1_000_000)
            }
        }
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}
