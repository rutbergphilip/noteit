import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum KeyDerivationError: Error, Equatable, Sendable {
    case invalidIterations(Int)
    case failed(Int32)
}

public enum KeyDerivation {
    public static let defaultIterations = 210_000

    /// Traps on invalid parameters; use `checkedKey` for untrusted input.
    public static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        do {
            return try checkedKey(passphrase: passphrase, salt: salt, iterations: iterations)
        } catch {
            preconditionFailure("Key derivation failed: \(error)")
        }
    }

    public static func checkedKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        SymmetricKey(data: try deriveBytes(passphrase: passphrase, salt: salt, iterations: iterations, length: 32))
    }

    public static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    static func deriveBytes(passphrase: String, salt: Data, iterations: Int, length: Int) throws -> Data {
        guard iterations >= 1, let rounds = UInt32(exactly: iterations) else {
            throw KeyDerivationError.invalidIterations(iterations)
        }
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
                rounds,
                &out,
                length
            )
        }
        guard status == kCCSuccess else { throw KeyDerivationError.failed(status) }
        return Data(out)
    }
}
