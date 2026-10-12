import CryptoKit
import XCTest
@testable import InkwellSync

final class CryptoTests: XCTestCase {
    func testPBKDF2RFC7914Vector() {
        let derived = KeyDerivation.deriveBytes(passphrase: "passwd", salt: Data("salt".utf8), iterations: 1, length: 64)
        let hex = derived.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    func testDeriveKeyIs32BytesAndDeterministic() {
        let salt = KeyDerivation.randomSalt()
        XCTAssertEqual(salt.count, 16)
        let a = KeyDerivation.deriveKey(passphrase: "pw", salt: salt, iterations: 1000)
        let b = KeyDerivation.deriveKey(passphrase: "pw", salt: salt, iterations: 1000)
        XCTAssertEqual(a.bitCount, 256)
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(salt, KeyDerivation.randomSalt())
    }

    func testSealOpenRoundTrip() throws {
        let cipher = AESGCMCipher(key: SymmetricKey(size: .bits256))
        let plain = Data("hello inkwell".utf8)
        let sealed = try cipher.seal(plain)
        XCTAssertNotEqual(sealed, plain)
        XCTAssertEqual(sealed.count, plain.count + 12 + 16)
        XCTAssertEqual(try cipher.open(sealed), plain)
    }

    func testSealIsNonDeterministic() throws {
        let cipher = AESGCMCipher(key: SymmetricKey(size: .bits256))
        let plain = Data("same".utf8)
        XCTAssertNotEqual(try cipher.seal(plain), try cipher.seal(plain))
    }

    func testTamperedCiphertextThrows() throws {
        let cipher = AESGCMCipher(key: SymmetricKey(size: .bits256))
        var sealed = try cipher.seal(Data("secret".utf8))
        sealed[14] ^= 0x01
        XCTAssertThrowsError(try cipher.open(sealed))
    }

    func testWrongKeyThrows() throws {
        let sealed = try AESGCMCipher(key: SymmetricKey(size: .bits256)).seal(Data("secret".utf8))
        XCTAssertThrowsError(try AESGCMCipher(key: SymmetricKey(size: .bits256)).open(sealed))
    }

    func testPassthroughIsIdentity() throws {
        let cipher = PassthroughCipher()
        let data = Data("plain".utf8)
        XCTAssertEqual(try cipher.seal(data), data)
        XCTAssertEqual(try cipher.open(data), data)
    }
}
