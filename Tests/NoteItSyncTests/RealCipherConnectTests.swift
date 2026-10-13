import XCTest
@testable import NoteItSync

final class RealCipherConnectTests: XCTestCase {
    func testPublicConnectUsesAESAndRejectsWrongPassphrase() async throws {
        let backend = InMemoryBackend()
        let (manifest, cipher) = try await SyncEngine.connect(backend: backend, passphrase: "correct horse", encryptNew: true)
        XCTAssertEqual(manifest.encryption?.iterations, KeyDerivation.defaultIterations)
        XCTAssertEqual(manifest.encryption?.salt.count, 16)
        let marker = Data("PLAINTEXT-MARKER".utf8)
        let sealed = try cipher.seal(marker, context: "notes/x.meta")
        XCTAssertNil(sealed.range(of: marker))

        let (_, again) = try await SyncEngine.connect(backend: backend, passphrase: "correct horse", encryptNew: false)
        XCTAssertEqual(try again.open(sealed, context: "notes/x.meta"), marker)

        do {
            _ = try await SyncEngine.connect(backend: backend, passphrase: "wrong", encryptNew: false)
            XCTFail("expected wrongPassphrase")
        } catch let error as SyncError {
            XCTAssertEqual(error, .wrongPassphrase)
        }
    }
}
