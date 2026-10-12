import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum KeyDerivation {
    public static let defaultIterations = 210_000

    public static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        SymmetricKey(data: deriveBytes(passphrase: passphrase, salt: salt, iterations: iterations, length: 32))
    }

    public static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    static func deriveBytes(passphrase: String, salt: Data, iterations: Int, length: Int) -> Data {
        let password = Array(passphrase.utf8)
        let saltBytes = [UInt8](salt)
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                pw.count,
                saltBytes,
                saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &out,
                length
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return Data(out)
    }
}
