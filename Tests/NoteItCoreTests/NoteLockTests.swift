import NoteItCore
import XCTest

/// foundations Task 4.3: the lock fields are data only and leave unlocked metas byte-identical.
final class NoteLockTests: XCTestCase {
    /// `LibraryCoding.encoder` output of these metas before `lock` existed.
    private let preChangeFull = "ewogICJjb25mbGljdE9yaWdpbmFsSUQiIDogIjJCMUM4RThDLTNGNTUtNEMzQS05RjdFLTFEMkIzQzRENUU2RiIsCiAgImNvbmZsaWN0U291cmNlIiA6ICJMYXB0b3AiLAogICJjcmVhdGVkQXQiIDogIjIwMjYtMDEtMDFUMDA6MDA6MDBaIiwKICAiZGVsZXRlZEF0IiA6ICIyMDI2LTAxLTAxVDAwOjAyOjAwWiIsCiAgImlkIiA6ICI2QTFDOEU4Qy0zRjU1LTRDM0EtOUY3RS0xRDJCM0M0RDVFNkYiLAogICJpc1Bpbm5lZCIgOiB0cnVlLAogICJub3RlYm9va0lEIiA6ICIwQjFDOEU4Qy0zRjU1LTRDM0EtOUY3RS0xRDJCM0M0RDVFNkYiLAogICJwcmV2aWV3IiA6ICJNaWxrIiwKICAicmV2aXNpb24iIDogIjFCMUM4RThDLTNGNTUtNEMzQS05RjdFLTFEMkIzQzRENUU2RiIsCiAgInRhZ3MiIDogWwogICAgImhvbWUiCiAgXSwKICAidGl0bGUiIDogIkdyb2NlcmllcyIsCiAgInVwZGF0ZWRBdCIgOiAiMjAyNi0wMS0wMVQwMDowMTowMFoiCn0="
    private let preChangeMinimal = "ewogICJjcmVhdGVkQXQiIDogIjIwMjYtMDEtMDFUMDA6MDA6MDBaIiwKICAiaWQiIDogIjZBMUM4RThDLTNGNTUtNEMzQS05RjdFLTFEMkIzQzRENUU2RiIsCiAgImlzUGlubmVkIiA6IGZhbHNlLAogICJwcmV2aWV3IiA6ICIiLAogICJ0YWdzIiA6IFsKCiAgXSwKICAidGl0bGUiIDogIiIsCiAgInVwZGF0ZWRBdCIgOiAiMjAyNi0wMS0wMVQwMDowMDowMFoiCn0="

    private let date = Date(timeIntervalSince1970: 1_767_225_600)
    private let id = UUID(uuidString: "6A1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F")!

    private var full: NoteMeta {
        NoteMeta(id: id, notebookID: UUID(uuidString: "0B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F")!, title: "Groceries",
                 preview: "Milk", isPinned: true, createdAt: date, updatedAt: date.addingTimeInterval(60), tags: ["home"],
                 revision: UUID(uuidString: "1B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F")!, conflictSource: "Laptop",
                 conflictOriginalID: UUID(uuidString: "2B1C8E8C-3F55-4C3A-9F7E-1D2B3C4D5E6F")!,
                 deletedAt: date.addingTimeInterval(120))
    }

    func testUnlockedMetaEncodesAsBefore() throws {
        let minimal = NoteMeta(id: id, title: "", preview: "", isPinned: false, createdAt: date, updatedAt: date, tags: [])
        XCTAssertFalse(full.isLocked)
        XCTAssertEqual(try LibraryCoding.encoder.encode(full), Data(base64Encoded: preChangeFull))
        XCTAssertEqual(try LibraryCoding.encoder.encode(minimal), Data(base64Encoded: preChangeMinimal))
        let decoded = try LibraryCoding.decoder.decode(NoteMeta.self, from: try XCTUnwrap(Data(base64Encoded: preChangeFull)))
        XCTAssertNil(decoded.lock)
        XCTAssertEqual(decoded, full)
    }

    func testLockedMetaRoundTrips() throws {
        var meta = full
        meta.lock = NoteLock(keyID: "key-1", sealedID: UUID())
        XCTAssertTrue(meta.isLocked)
        let data = try LibraryCoding.encoder.encode(meta)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lock = try XCTUnwrap(object["lock"] as? [String: Any])
        XCTAssertEqual(Set(lock.keys), ["keyID", "sealedID"])
        XCTAssertEqual(try LibraryCoding.decoder.decode(NoteMeta.self, from: data), meta)
    }

    func testLockIsOwned() {
        XCTAssertTrue(NoteMeta.ownedCodingKeys.contains("lock"))
    }
}
