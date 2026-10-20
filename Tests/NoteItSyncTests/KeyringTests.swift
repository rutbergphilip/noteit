import CryptoKit
import XCTest
@testable import NoteItSync

/// foundations Task 3.2: Keyring, Rekey, KeyIdentity and passphrase normalisation.
final class KeyringTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let fast = 100_000

    private func assertThrows(_ expected: SyncError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? SyncError, expected, file: file, line: line)
        }
    }

    private func data(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    func testMakeThenUnwrap() throws {
        let key = SymmetricKey(size: .bits256)
        let keyring = try Keyring.make(dataKey: key, passphrase: "pw", deviceName: "Mac", now: now, iterations: fast)
        XCTAssertEqual(keyring.keyID, KeyIdentity.keyID(for: key))
        XCTAssertEqual(keyring.kdf, "pbkdf2-sha256")
        XCTAssertEqual(keyring.changedBy, "Mac")
        XCTAssertEqual(keyring.changedAt, now)
        XCTAssertEqual(data(try keyring.unwrap(passphrase: "pw")), data(key))
        XCTAssertEqual(Keyring.defaultIterations, 600_000)
        XCTAssertEqual(try Keyring.make(dataKey: key, passphrase: "pw", deviceName: "Mac", now: now).iterations, 600_000)
    }

    func testWrongPassphrase() throws {
        let keyring = try Keyring.make(dataKey: SymmetricKey(size: .bits256), passphrase: "pw", deviceName: "Mac", now: now, iterations: fast)
        assertThrows(.wrongPassphrase) { _ = try keyring.unwrap(passphrase: "other") }
    }

    func testNFCAndNFDBothUnwrap() throws {
        let key = SymmetricKey(size: .bits256)
        let nfc = "Caf\u{E9}", nfd = "Cafe\u{301}"
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        for maker in [nfc, nfd] {
            let keyring = try Keyring.make(dataKey: key, passphrase: maker, deviceName: "Mac", now: now, iterations: fast)
            XCTAssertEqual(data(try keyring.unwrap(passphrase: nfc)), data(key))
            XCTAssertEqual(data(try keyring.unwrap(passphrase: nfd)), data(key))
        }
    }

    func testV1PassphraseKeepsRawBytes() async throws {
        let nfc = "Caf\u{E9}", nfd = "Cafe\u{301}"
        let backend = InMemoryBackend()
        _ = try await SyncEngine.connect(backend: backend, passphrase: nfd, encryptNew: true)
        _ = try await SyncEngine.connect(backend: backend, passphrase: nfd, encryptNew: true)
        do {
            _ = try await SyncEngine.connect(backend: backend, passphrase: nfc, encryptNew: true)
            XCTFail("expected wrongPassphrase")
        } catch {
            XCTAssertEqual(error as? SyncError, .wrongPassphrase)
        }
    }

    func testRewrappedKeepsKeyID() throws {
        let key = SymmetricKey(size: .bits256)
        let keyring = try Keyring.make(dataKey: key, passphrase: "old", deviceName: "Mac", now: now, iterations: fast)
        let later = now.addingTimeInterval(60)
        let rewrapped = try keyring.rewrapped(dataKey: key, newPassphrase: "new", deviceName: "Other Mac", now: later)
        XCTAssertEqual(rewrapped.keyID, keyring.keyID)
        XCTAssertEqual(rewrapped.changedBy, "Other Mac")
        XCTAssertEqual(rewrapped.changedAt, later)
        XCTAssertEqual(data(try rewrapped.unwrap(passphrase: "new")), data(key))
        assertThrows(.wrongPassphrase) { _ = try rewrapped.unwrap(passphrase: "old") }
        assertThrows(.invalidManifest("data key doesn't match keyring")) {
            _ = try keyring.rewrapped(dataKey: SymmetricKey(size: .bits256), newPassphrase: "new", deviceName: "Mac", now: later)
        }
    }

    func testEmptyPassphraseIsRequired() throws {
        let key = SymmetricKey(size: .bits256)
        assertThrows(.passphraseRequired) { _ = try Keyring.make(dataKey: key, passphrase: "", deviceName: "Mac", now: self.now) }
        let keyring = try Keyring.make(dataKey: key, passphrase: "pw", deviceName: "Mac", now: now, iterations: fast)
        assertThrows(.passphraseRequired) { _ = try keyring.rewrapped(dataKey: key, newPassphrase: "", deviceName: "Mac", now: self.now) }
    }

    func testIterationsOutsideRangeAreInvalid() throws {
        let key = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try Keyring.make(dataKey: key, passphrase: "pw", deviceName: "Mac", now: now, iterations: 99_999)) { error in
            guard case SyncError.invalidManifest = error else { return XCTFail("\(error)") }
        }
        var keyring = try Keyring.make(dataKey: key, passphrase: "pw", deviceName: "Mac", now: now, iterations: fast)
        keyring.iterations = 20_000_000
        XCTAssertThrowsError(try keyring.unwrap(passphrase: "pw")) { error in
            guard case SyncError.invalidManifest = error else { return XCTFail("\(error)") }
        }
    }

    func testLegacyKeyIDIsStable() {
        let encryption = Manifest.Encryption(salt: Data(repeating: 1, count: 16), iterations: 210_000, keyCheck: Data(repeating: 2, count: 44))
        let id = KeyIdentity.legacyKeyID(encryption)
        XCTAssertEqual(id.count, 16)
        XCTAssertEqual(id, KeyIdentity.legacyKeyID(encryption))
        XCTAssertEqual(id, "93e5621ee45224c7")
        var other = encryption
        other.iterations = 210_001
        XCTAssertNotEqual(KeyIdentity.legacyKeyID(other), id)
    }

    func testKeyIDFormat() {
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))
        let id = KeyIdentity.keyID(for: key)
        XCTAssertEqual(id.count, 16)
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(id, SHA256.hash(data: Data("noteit-key-id".utf8) + Data(repeating: 0, count: 32)).prefix(8)
            .map { String(format: "%02x", $0) }.joined())
    }

    func testRekeyStaleAfterBoundary() {
        let rekey = Rekey(fromKeyID: nil, toKeyID: "abc", startedAt: now, updatedAt: now, deviceID: "D", deviceName: "Mac")
        XCTAssertEqual(Rekey.staleAfter, 3600)
        XCTAssertFalse(rekey.isStale(at: now.addingTimeInterval(3599.999)))
        XCTAssertTrue(rekey.isStale(at: now.addingTimeInterval(3600)))
    }

    func testRekeyPreviousFieldsRoundTrip() throws {
        let keyring = try Keyring.make(dataKey: SymmetricKey(size: .bits256), passphrase: "pw", deviceName: "Mac", now: now, iterations: fast)
        let rekey = Rekey(fromKeyID: keyring.keyID, toKeyID: "0123456789abcdef", startedAt: now, updatedAt: now, deviceID: "D",
                          deviceName: "Mac", previousKeyring: keyring,
                          previousEncryption: .init(salt: Data(repeating: 3, count: 16), iterations: 210_000, keyCheck: Data([4])))
        let manifest = Manifest(formatVersion: 2, createdAt: now, features: ["keyring"], keyring: keyring, rekey: rekey)
        let encoded = try SyncEngine.encode(manifest)
        let decoded = try SyncEngine.decode(Manifest.self, from: encoded)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.rekey?.previousKeyring, keyring)
        XCTAssertNotNil(decoded.rekey?.previousEncryption)
        XCTAssertEqual(try SyncEngine.encode(decoded), encoded)
    }
}
