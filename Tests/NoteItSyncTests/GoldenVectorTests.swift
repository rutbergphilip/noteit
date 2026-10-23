import CryptoKit
import Foundation
import NoteItCore
import NoteItDoc
import XCTest
@testable import NoteItSync

/// Cross-language vectors for the v1 store format, read by the web client's tests. Owned by the foundations plan
/// (Task 2.4); the case shapes are the web-app plan's "Golden vector file schemas". `NOTEIT_WRITE_VECTORS=1`
/// rewrites `fixtures/golden`; a normal run checks the committed files against the current engine.
final class GoldenVectorTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        scratch = root.appendingPathComponent(".build/golden-vector-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - pbkdf2.json

    struct PBKDF2Case: Codable, Equatable {
        var passphrase: String
        var salt: String
        var iterations: Int
        var key: String
    }

    func testPBKDF2() throws {
        let inputs: [(String, Data, Int)] = [
            ("correct horse battery staple", VectorIO.bytes("salt-a", count: 16), 210_000),
            ("pässwörd 🔑", VectorIO.bytes("salt-b", count: 16), 210_000),
            ("café", Data(repeating: 0, count: 16), 210_000),
            ("x", Data(repeating: 0xFF, count: 16), 100_000),
            ("short salt", Data([0x01]), 1),
            ("long salt", VectorIO.bytes("salt-c", count: 64), 1_000),
            ("", VectorIO.bytes("salt-d", count: 16), 2),
        ]
        let cases = try inputs.map { passphrase, salt, iterations in
            PBKDF2Case(passphrase: passphrase, salt: salt.base64EncodedString(), iterations: iterations,
                       key: VectorIO.keyData(try KeyDerivation.checkedKey(passphrase: passphrase, salt: salt, iterations: iterations)).base64EncodedString())
        }
        try VectorIO.check("pbkdf2.json", cases)
    }

    // MARK: - aesgcm.json

    struct AESGCMCase: Codable, Equatable {
        var key: String
        var nonce: String
        var plaintext: String
        var context: String
        var sealed: String
        var tamper: String?
        var expect: String?
    }

    func testAESGCM() throws {
        let key = SymmetricKey(data: VectorIO.bytes("aes-key", count: 32))
        let inputs: [(Data, String)] = [
            (Data(), "manifest"),
            (Data("inkwell-key-check".utf8), "manifest"),
            (Data("{\"title\":\"Hello\"}".utf8), "notes/\(VectorIO.uuid("note-1").uuidString).meta"),
            (VectorIO.bytes("body", count: 1_000), "notes/\(VectorIO.uuid("note-1").uuidString).body"),
            (Data("smörgåsbord 😀".utf8), "devices/device-1.json"),
        ]
        var cases: [AESGCMCase] = []
        for (index, (plain, context)) in inputs.enumerated() {
            let nonce = VectorIO.bytes("aes-nonce-\(index)", count: 12)
            let sealed = try DeterministicAESCipher.seal(plain, key: key, nonce: nonce, context: context)
            cases.append(AESGCMCase(key: VectorIO.keyData(key).base64EncodedString(), nonce: nonce.base64EncodedString(),
                                    plaintext: plain.base64EncodedString(), context: context, sealed: sealed.base64EncodedString()))
        }
        // Negative cases carry the tampered values, so opening them as given must fail.
        let base = cases[2]
        let sealed = Data(base64Encoded: base.sealed)!
        var aad = base
        aad.context = base.context.replacingOccurrences(of: ".meta", with: ".body")
        var tag = base
        var tagBytes = sealed
        tagBytes[tagBytes.count - 1] ^= 0x01
        tag.sealed = tagBytes.base64EncodedString()
        var nonce = base
        var nonceBytes = sealed
        nonceBytes[0] ^= 0x01
        nonce.sealed = nonceBytes.base64EncodedString()
        nonce.nonce = nonceBytes.prefix(12).base64EncodedString()
        for (var negative, kind) in [(aad, "aad"), (tag, "tag"), (nonce, "nonce")] {
            negative.tamper = kind
            negative.expect = "fail"
            cases.append(negative)
        }
        try VectorIO.check("aesgcm.json", cases)

        for vector in try VectorIO.load("aesgcm.json", as: AESGCMCase.self) {
            let key = SymmetricKey(data: Data(base64Encoded: vector.key)!)
            let sealed = Data(base64Encoded: vector.sealed)!
            let opened = try? AESGCMCipher(key: key).open(sealed, context: vector.context)
            if vector.expect == "fail" {
                XCTAssertNil(opened, "tamper \(vector.tamper ?? "")")
            } else {
                XCTAssertEqual(opened, Data(base64Encoded: vector.plaintext))
                XCTAssertEqual(Data(base64Encoded: vector.nonce), sealed.prefix(12))
            }
        }
    }

    // MARK: - manifest.json

    struct ManifestCase: Codable, Equatable {
        var name: String
        var passphrase: String?
        var manifestJSON: String
        var expect: String
        var keyID: String?
    }

    func testManifests() async throws {
        let passphrase = "correct horse battery staple"
        let nfc = "caf\u{E9}"
        let nfd = "cafe\u{301}"
        func encrypted(_ passphrase: String, salt: Data, iterations: Int = 210_000, formatVersion: Int = 1,
                       checkPlaintext: Data = SyncEngine.keyCheckPlaintext, keyCheck: ((Data) -> Data)? = nil) throws -> Manifest {
            let key = try KeyDerivation.checkedKey(passphrase: passphrase, salt: salt, iterations: iterations)
            var check = try DeterministicAESCipher(key: key).seal(checkPlaintext, context: SyncEngine.keyCheckContext)
            if let keyCheck { check = keyCheck(check) }
            return Manifest(formatVersion: formatVersion, encryption: .init(salt: salt, iterations: iterations, keyCheck: check),
                            createdAt: VectorIO.epoch)
        }
        let salt = VectorIO.bytes("manifest-salt", count: 16)
        let main = try encrypted(passphrase, salt: salt)
        let accented = try encrypted(nfc, salt: VectorIO.bytes("manifest-salt-nfc", count: 16), iterations: 100_000)
        let inputs: [(String, String?, Manifest)] = [
            ("plain", nil, Manifest(createdAt: VectorIO.epoch)),
            ("plain-passphrase-ignored", passphrase, Manifest(createdAt: VectorIO.epoch)),
            ("encrypted", passphrase, main),
            ("encrypted-wrong-passphrase", "correct horse battery stapler", main),
            ("encrypted-nfc-passphrase", nfc, accented),
            ("encrypted-nfd-passphrase-not-normalized", nfd, accented),
            ("format-3-plain", nil, Manifest(formatVersion: 3, createdAt: VectorIO.epoch)),
            ("format-3-encrypted", passphrase, try encrypted(passphrase, salt: salt, formatVersion: 3)),
            ("iterations-below-range", passphrase, Manifest(encryption: .init(salt: salt, iterations: 99_999, keyCheck: main.encryption!.keyCheck),
                                                             createdAt: VectorIO.epoch)),
            ("salt-15-bytes", passphrase, Manifest(encryption: .init(salt: salt.prefix(15), iterations: 210_000, keyCheck: main.encryption!.keyCheck),
                                                    createdAt: VectorIO.epoch)),
            ("empty-key-check", passphrase, Manifest(encryption: .init(salt: salt, iterations: 210_000, keyCheck: Data()), createdAt: VectorIO.epoch)),
            // Stores created by Inkwell (before 0.4.0) seal the legacy key check.
            ("encrypted-inkwell-key-check", passphrase,
             try encrypted(passphrase, salt: salt, checkPlaintext: SyncEngine.legacyKeyCheckPlaintext)),
        ]
        var cases: [ManifestCase] = []
        for (name, phrase, manifest) in inputs {
            let json = String(decoding: try SyncEngine.encode(manifest), as: UTF8.self)
            cases.append(ManifestCase(name: name, passphrase: phrase, manifestJSON: json, expect: await connectOutcome(json, phrase)))
        }
        XCTAssertEqual(cases.map(\.expect), ["ok", "ok", "ok", "wrongPassphrase", "ok", "wrongPassphrase", "unsupportedFormat",
                                             "unsupportedFormat", "invalidManifest", "invalidManifest", "invalidManifest", "ok"])

        // Keyring stores (Task 3.2). `expect` describes the manifest and its unwrapped key, not what this build opens.
        func keyring(_ label: String, passphrase: String) throws -> Manifest {
            let dataKey = SymmetricKey(data: VectorIO.bytes("keyring-data-key-\(label)", count: 32))
            let ring = try Keyring.make(dataKey: dataKey, passphrase: passphrase, deviceName: "Vector Mac", now: VectorIO.epoch,
                                        iterations: 100_000, salt: VectorIO.bytes("keyring-salt-\(label)", count: 16),
                                        nonce: try AES.GCM.Nonce(data: VectorIO.bytes("keyring-nonce-\(label)", count: 12)))
            return Manifest(formatVersion: 2, createdAt: VectorIO.epoch, features: ["keyring"], keyring: ring)
        }
        let ascii = try keyring("ascii", passphrase: passphrase)
        let madeNFC = try keyring("nfc", passphrase: nfc)
        let madeNFD = try keyring("nfd", passphrase: nfd)
        let keyringInputs: [(String, String?, Manifest)] = [
            ("keyring", passphrase, ascii),
            ("keyring-wrong-passphrase", "correct horse battery stapler", ascii),
            ("keyring-nfc-made-nfc-opened", nfc, madeNFC),
            ("keyring-nfc-made-nfd-opened", nfd, madeNFC),
            ("keyring-nfd-made-nfc-opened", nfc, madeNFD),
            ("keyring-nfd-made-nfd-opened", nfd, madeNFD),
        ]
        var keyringCases: [ManifestCase] = []
        for (name, phrase, manifest) in keyringInputs {
            let json = String(decoding: try SyncEngine.encode(manifest), as: UTF8.self)
            let (expect, keyID) = keyringOutcome(json, phrase)
            keyringCases.append(ManifestCase(name: name, passphrase: phrase, manifestJSON: json, expect: expect, keyID: keyID))
        }
        XCTAssertEqual(keyringCases.map(\.expect), ["ok", "wrongPassphrase", "ok", "ok", "ok", "ok"])
        XCTAssertEqual(keyringCases[0].keyID, KeyIdentity.keyID(for: SymmetricKey(data: VectorIO.bytes("keyring-data-key-ascii", count: 32))))
        cases += keyringCases
        try VectorIO.check("manifest.json", cases)

        for stored in try VectorIO.load("manifest.json", as: ManifestCase.self) where stored.name.hasPrefix("keyring") {
            let (expect, keyID) = keyringOutcome(stored.manifestJSON, stored.passphrase)
            XCTAssertEqual(expect, stored.expect, stored.name)
            XCTAssertEqual(keyID, stored.keyID, stored.name)
        }
    }

    private func keyringOutcome(_ manifestJSON: String, _ passphrase: String?) -> (String, String?) {
        do {
            let manifest = try SyncEngine.decode(Manifest.self, from: Data(manifestJSON.utf8))
            try SyncEngine.checkOpenable(manifest, supported: [.keyring])
            guard let ring = manifest.keyring else { return ("error: no keyring", nil) }
            let key = try ring.unwrap(passphrase: passphrase ?? "")
            return ("ok", KeyIdentity.keyID(for: key))
        } catch SyncError.wrongPassphrase {
            return ("wrongPassphrase", nil)
        } catch SyncError.invalidManifest {
            return ("invalidManifest", nil)
        } catch {
            return ("error: \(error)", nil)
        }
    }

    private func connectOutcome(_ manifestJSON: String, _ passphrase: String?) async -> String {
        let backend = InMemoryBackend()
        do {
            try await backend.put(RemoteLayout.manifest(), data: Data(manifestJSON.utf8), ifMatch: nil, ifNoneMatch: true)
            _ = try await SyncEngine.connect(backend: backend, passphrase: passphrase, encryptNew: false)
            return "ok"
        } catch SyncError.wrongPassphrase {
            return "wrongPassphrase"
        } catch SyncError.unsupportedFormat {
            return "unsupportedFormat"
        } catch SyncError.invalidManifest {
            return "invalidManifest"
        } catch {
            return "error: \(error)"
        }
    }

    // MARK: - envelopes.json

    struct EnvelopeCase: Codable, Equatable {
        var name: String
        var key: String
        var context: String
        var keyB64: String
        var sealed: String
        var plaintextJSON: String
        var decoded: JSONValue
    }

    func testEnvelopes() throws {
        let cipher = DeterministicAESCipher(key: SymmetricKey(data: VectorIO.bytes("envelope-key", count: 32)))
        let noteID = VectorIO.uuid("envelope-note")
        let notebookID = VectorIO.uuid("envelope-notebook")
        let modifiedAt = VectorIO.epoch.addingTimeInterval(86_400.25)
        let noteMeta = NoteMeta(id: noteID, notebookID: notebookID, title: "Plans / ideas", preview: "Road trip: A/B testing",
                                isPinned: true, createdAt: VectorIO.epoch, updatedAt: VectorIO.epoch.addingTimeInterval(86_400),
                                tags: ["work/2026", "ideas"], revision: VectorIO.uuid("envelope-note-rev"))
        let notebook = Notebook(id: notebookID, name: "Home/Work", symbol: "folder", colorHex: "#3478F6", sortIndex: 2,
                                revision: VectorIO.uuid("envelope-notebook-rev"), modifiedAt: VectorIO.epoch.addingTimeInterval(3_600))
        let nestedNotebook = Notebook(id: VectorIO.uuid("envelope-notebook-nested"), name: "Clients", symbol: "folder", colorHex: "#34C759",
                                      sortIndex: 0, revision: VectorIO.uuid("envelope-notebook-nested-rev"),
                                      modifiedAt: VectorIO.epoch.addingTimeInterval(3_660), parent: notebookID)
        let noteMetaData = try LibraryCoding.encoder.encode(noteMeta)
        let body = Data("{\\rtf1\\ansi Plans}".utf8)
        let inputs: [(String, String, any Encodable)] = [
            ("note-envelope", RemoteLayout.meta(.note, noteID),
             RemoteEnvelope(id: noteID, kind: .note, revision: noteMeta.revision!, modifiedAt: modifiedAt, deviceID: "device-1",
                            deviceName: "Work Mac/Studio", meta: noteMetaData, bodySHA256: SyncEngine.sha256Hex(body))),
            ("note-envelope-legacy-without-body-sha", RemoteLayout.meta(.note, noteID),
             RemoteEnvelope(id: noteID, kind: .note, revision: noteMeta.revision!, modifiedAt: modifiedAt, deviceID: "device-1",
                            deviceName: "Work Mac", meta: noteMetaData)),
            ("notebook-envelope", RemoteLayout.meta(.notebook, notebookID),
             RemoteEnvelope(id: notebookID, kind: .notebook, revision: notebook.revision!, modifiedAt: notebook.modifiedAt!,
                            deviceID: "device-2", deviceName: "Laptop", meta: try LibraryCoding.encoder.encode(notebook))),
            ("notebook-envelope-nested", RemoteLayout.meta(.notebook, nestedNotebook.id),
             RemoteEnvelope(id: nestedNotebook.id, kind: .notebook, revision: nestedNotebook.revision!, modifiedAt: nestedNotebook.modifiedAt!,
                            deviceID: "device-2", deviceName: "Laptop", meta: try LibraryCoding.encoder.encode(nestedNotebook))),
            ("tombstone", RemoteLayout.tombstone(noteID),
             Tombstone(id: noteID, kind: .note, deletedAt: VectorIO.epoch.addingTimeInterval(172_800.5), deviceID: "device-2",
                       deletedMetaETag: "\"5d41402abc4b2a76b9719d911017c592\"")),
            ("tombstone-legacy-without-etag", RemoteLayout.tombstone(notebookID),
             Tombstone(id: notebookID, kind: .notebook, deletedAt: VectorIO.epoch, deviceID: "device-1")),
            ("device", RemoteLayout.device("device-1"),
             DeviceInfo(deviceID: "device-1", name: "Work Mac/Studio", lastSync: VectorIO.epoch.addingTimeInterval(0.125))),
        ]
        // web-app Task 0.4: a noteit-doc envelope and the versioned body it names, sealed with the body key's context.
        let docBody = BodyContainer(doc: .doc([
            .heading(level: 1, align: nil, indent: nil, content: [.text("Plans / ideas", marks: [])]),
            .paragraph(align: nil, indent: nil, content: [.text("Road trip: A/B testing", marks: [.bold])]),
        ]))
        let docBodyPlain = try docBody.encoded()
        let docVersion = VectorIO.uuid("envelope-note-body-version")
        let docTag = RemoteLayout.baseTag("\"5d41402abc4b2a76b9719d911017c592\"")
        let docInputs: [(String, String, any Encodable)] = [
            ("note-envelope-noteit-doc", RemoteLayout.meta(.note, noteID),
             RemoteEnvelope(id: noteID, kind: .note, revision: noteMeta.revision!, modifiedAt: modifiedAt, deviceID: "device-1",
                            deviceName: "Work Mac/Studio", meta: noteMetaData, bodySHA256: SyncEngine.sha256Hex(docBodyPlain),
                            bodyFormat: BodyFormat.noteItDocV1, bodyVersion: docVersion)),
        ]
        var cases: [EnvelopeCase] = []
        func add(_ name: String, _ key: String, _ plain: Data) throws {
            let context = SyncEngine.context(key)
            cases.append(EnvelopeCase(name: name, key: key, context: context, keyB64: VectorIO.keyData(cipher.key).base64EncodedString(),
                                      sealed: try cipher.seal(plain, context: context).base64EncodedString(),
                                      plaintextJSON: String(decoding: plain, as: UTF8.self), decoded: try Self.decoded(plain)))
        }
        for (name, key, value) in inputs + docInputs {
            try add(name, key, try SyncEngine.encode(value))
        }
        try add("noteit-doc-body", RemoteLayout.docBody(noteID, version: docVersion, tag: docTag), docBodyPlain)
        XCTAssertTrue(cases[0].plaintextJSON.contains("\\/"), "Swift escapes slashes in strings")
        XCTAssertEqual(cases.last?.context, "bodies/\(noteID.uuidString).\(docVersion.uuidString).\(docTag).body", "context without the root")
        try VectorIO.check("envelopes.json", cases)

        for vector in try VectorIO.load("envelopes.json", as: EnvelopeCase.self) {
            let key = SymmetricKey(data: Data(base64Encoded: vector.keyB64)!)
            let plain = try AESGCMCipher(key: key).open(Data(base64Encoded: vector.sealed)!, context: vector.context)
            XCTAssertEqual(String(decoding: plain, as: UTF8.self), vector.plaintextJSON, vector.name)
            XCTAssertEqual(vector.context, SyncEngine.context(vector.key))
            let reencoded: Data
            switch vector.name {
            case let name where name.hasPrefix("tombstone"): reencoded = try SyncEngine.encode(SyncEngine.decode(Tombstone.self, from: plain))
            case "device": reencoded = try SyncEngine.encode(SyncEngine.decode(DeviceInfo.self, from: plain))
            case "noteit-doc-body": reencoded = try BodyContainer.decode(plain).encoded()
            default:
                let envelope = try SyncEngine.decode(RemoteEnvelope.self, from: plain)
                reencoded = try SyncEngine.encode(envelope)
                if envelope.kind == .note {
                    XCTAssertEqual(try LibraryCoding.encoder.encode(LibraryCoding.decoder.decode(NoteMeta.self, from: envelope.meta)), envelope.meta)
                } else {
                    XCTAssertEqual(try LibraryCoding.encoder.encode(LibraryCoding.decoder.decode(Notebook.self, from: envelope.meta)), envelope.meta)
                }
            }
            XCTAssertEqual(reencoded, plain, "\(vector.name) re-encodes to the same bytes")
            XCTAssertEqual(try Self.decoded(plain), vector.decoded, vector.name)
        }
    }

    // MARK: - base-tags.json (web-app Task 0.4)

    /// `etag` as a backend returns it (quotes included or not); `tag` = `RemoteLayout.baseTag(etag)`.
    struct BaseTagCase: Codable, Equatable {
        var etag: String
        var tag: String
    }

    func testBaseTags() throws {
        let etags = ["5d41402abc4b2a76b9719d911017c592", "\"5d41402abc4b2a76b9719d911017c592\"", "d41d8cd98f00b204e9800998ecf8427e-2",
                     "0x8DCF2A3B4C5D6E7", "9B2CF535-F277-31C9-7434-3645A3985328", "etag-1", "\"\"", "x"]
        let cases = etags.map { BaseTagCase(etag: $0, tag: RemoteLayout.baseTag($0)) }
        XCTAssertEqual(cases[0].tag, cases[1].tag, "quotes are not part of the ETag")
        XCTAssertTrue(cases.allSatisfy { $0.tag.count == 16 && RemoteLayout.isTag($0.tag) })
        try VectorIO.check("base-tags.json", cases)
    }

    /// The plaintext as JSON, with an envelope's `meta` bytes replaced by the inner meta's JSON.
    private static func decoded(_ plain: Data) throws -> JSONValue {
        guard case .object(var fields) = try JSONValue.decode(plain) else { return try JSONValue.decode(plain) }
        if case .string(let base64)? = fields["meta"], let inner = Data(base64Encoded: base64) {
            fields["meta"] = try JSONValue.decode(inner)
        }
        return .object(fields)
    }

    // MARK: - planner.json

    struct PlannerCase: Codable, Equatable {
        struct Local: Codable, Equatable { var revision: String; var modifiedAt: String }
        struct Tomb: Codable, Equatable { var deletedAt: String; var deletedMetaETag: String? }
        struct Remote: Codable, Equatable { var metaETag: String?; var tombstone: Tomb? }
        struct Base: Codable, Equatable { var revision: String; var remoteMetaETag: String; var replacedMetaETag: String? }

        var local: Local?
        var localDeletedAt: String?
        var remote: Remote
        var base: Base?
        var expect: String
    }

    func testPlanner() throws {
        let t1 = VectorIO.iso(VectorIO.epoch.addingTimeInterval(3_600))
        let t2 = VectorIO.iso(VectorIO.epoch.addingTimeInterval(7_200))
        let t3 = VectorIO.iso(VectorIO.epoch.addingTimeInterval(10_800))
        let t4 = VectorIO.iso(VectorIO.epoch.addingTimeInterval(14_400))
        let locals: [PlannerCase.Local?] = [nil, .init(revision: "R0", modifiedAt: t2), .init(revision: "R1", modifiedAt: t2)]
        let deletions: [String?] = [nil, t4]
        let tombstones: [PlannerCase.Tomb?] = [nil] + [t1, t3].flatMap { at in [nil, "E0", "E1", "E2"].map { PlannerCase.Tomb(deletedAt: at, deletedMetaETag: $0) } }
        let bases: [PlannerCase.Base?] = [nil] + [nil, "E1", "E2"].map { PlannerCase.Base(revision: "R0", remoteMetaETag: "E0", replacedMetaETag: $0) }
        var cases: [PlannerCase] = []
        for local in locals {
            for deletion in deletions {
                for etag in [nil, "E0", "E1"] {
                    for tombstone in tombstones {
                        for base in bases {
                            var vector = PlannerCase(local: local, localDeletedAt: deletion, remote: .init(metaETag: etag, tombstone: tombstone),
                                                     base: base, expect: "")
                            vector.expect = Self.decide(vector)
                            cases.append(vector)
                        }
                    }
                }
            }
        }
        try VectorIO.check("planner.json", cases)
        for vector in try VectorIO.load("planner.json", as: PlannerCase.self) {
            XCTAssertEqual(Self.decide(vector), vector.expect, "\(vector)")
        }
    }

    private static func decide(_ vector: PlannerCase) -> String {
        let id = VectorIO.uuid("planner-record")
        func revision(_ symbol: String) -> UUID { VectorIO.uuid("planner-\(symbol)") }
        let local = vector.local.map { LocalRecord(id: id, kind: .note, revision: revision($0.revision), modifiedAt: VectorIO.date(iso: $0.modifiedAt)!) }
        let tombstone = vector.remote.tombstone.map {
            Tombstone(id: id, kind: .note, deletedAt: VectorIO.date(iso: $0.deletedAt)!, deviceID: "other", deletedMetaETag: $0.deletedMetaETag)
        }
        let base = vector.base.map { SyncState.Base(revision: revision($0.revision), remoteMetaETag: $0.remoteMetaETag, replacedMetaETag: $0.replacedMetaETag) }
        let action = SyncPlanner.decide(local: local, localDeletedAt: vector.localDeletedAt.flatMap(VectorIO.date(iso:)),
                                        remote: RemoteInfo(metaETag: vector.remote.metaETag, tombstone: tombstone), base: base)
        return String(describing: action)
    }

    // MARK: - store-snapshot.json

    struct SnapshotCase: Codable, Equatable {
        struct Object: Codable, Equatable { var key: String; var etag: String; var data: String }
        struct Record: Codable, Equatable {
            var id: String
            var kind: String
            var revision: String
            var modifiedAt: String
            var deviceID: String
            var meta: String
            var body: String?
        }

        var passphrase: String
        var objects: [Object]
        var expectRecords: [Record]
    }

    func testStoreSnapshot() async throws {
        let passphrase = "correct horse battery staple"
        let generated = try await makeSnapshot(passphrase: passphrase)
        XCTAssertEqual(generated.expectRecords.count, 3)
        try VectorIO.check("store-snapshot.json", [generated])

        let stored = try XCTUnwrap(try VectorIO.load("store-snapshot.json", as: SnapshotCase.self).first)
        let pulled = try await pull(stored.objects, passphrase: stored.passphrase)
        XCTAssertEqual(pulled, stored.expectRecords)
    }

    private func makeSnapshot(passphrase: String) async throws -> SnapshotCase {
        let backend = VectorBackend()
        let salt = VectorIO.bytes("snapshot-salt", count: 16)
        let key = try KeyDerivation.checkedKey(passphrase: passphrase, salt: salt, iterations: KeyDerivation.defaultIterations)
        let cipher = DeterministicAESCipher(key: key)
        let manifest = Manifest(encryption: .init(salt: salt, iterations: KeyDerivation.defaultIterations,
                                                  keyCheck: try cipher.seal(SyncEngine.keyCheckPlaintext, context: SyncEngine.keyCheckContext)),
                                createdAt: VectorIO.epoch)
        try await backend.put(RemoteLayout.manifest(), data: try SyncEngine.encode(manifest), ifMatch: nil, ifNoneMatch: true)

        let notebookID = VectorIO.uuid("snapshot-notebook")
        let notebook = Notebook(id: notebookID, name: "Projects", symbol: "folder", colorHex: "#34C759", sortIndex: 0,
                                revision: VectorIO.uuid("snapshot-notebook-rev"), modifiedAt: VectorIO.epoch.addingTimeInterval(60))
        func note(_ label: String, title: String, pinned: Bool, tags: [String], body: String) throws -> RecordPayload {
            let id = VectorIO.uuid(label)
            let meta = NoteMeta(id: id, notebookID: notebookID, title: title, preview: body, isPinned: pinned, createdAt: VectorIO.epoch,
                                updatedAt: VectorIO.epoch.addingTimeInterval(120), tags: tags, revision: VectorIO.uuid(label + "-rev"))
            return RecordPayload(id: id, kind: .note, revision: meta.revision!, modifiedAt: meta.updatedAt, deviceID: "snapshot-device",
                                 meta: try LibraryCoding.encoder.encode(meta), body: Data("{\\rtf1\\ansi \(body)}".utf8))
        }
        let local = RecordingLocalStore(
            payloads: [
                RecordPayload(id: notebookID, kind: .notebook, revision: notebook.revision!, modifiedAt: notebook.modifiedAt!,
                              deviceID: "snapshot-device", meta: try LibraryCoding.encoder.encode(notebook)),
                try note("snapshot-note-a", title: "Groceries / week 1", pinned: true, tags: ["home"], body: "Milk, eggs"),
                try note("snapshot-note-b", title: "Smörgåsbord ideas", pinned: false, tags: [], body: "Pickled herring"),
            ],
            deletions: [VectorIO.uuid("snapshot-deleted"): LocalDeletion(kind: .note, deletedAt: VectorIO.epoch.addingTimeInterval(180))]
        )
        let clock = FixedClock(VectorIO.epoch.addingTimeInterval(3_600))
        let engine = SyncEngine(backend: backend, cipher: cipher, local: local, stateURL: scratch.appendingPathComponent("snapshot.json"),
                                deviceID: "snapshot-device", deviceName: "Snapshot Mac", now: { clock.now() })
        let report = try await engine.sync()
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.pushed, 3)

        let objects = await backend.objects().map {
            SnapshotCase.Object(key: $0.key, etag: $0.etag, data: $0.data.base64EncodedString())
        }
        return SnapshotCase(passphrase: passphrase, objects: objects, expectRecords: try await pull(objects, passphrase: passphrase))
    }

    /// What a new device pulls from the objects, opening the store with the passphrase and the production cipher.
    private func pull(_ objects: [SnapshotCase.Object], passphrase: String) async throws -> [SnapshotCase.Record] {
        let backend = VectorBackend()
        for object in objects { await backend.seed(object.key, data: Data(base64Encoded: object.data)!, etag: object.etag) }
        let cipher = try await SyncEngine.connect(backend: backend, passphrase: passphrase, encryptNew: false).1
        XCTAssertTrue(cipher is AESGCMCipher)
        let local = RecordingLocalStore()
        let engine = SyncEngine(backend: backend, cipher: cipher, local: local, stateURL: scratch.appendingPathComponent("pull-\(UUID()).json"),
                                deviceID: "reader", deviceName: "Reader", now: { VectorIO.epoch.addingTimeInterval(7_200) })
        let report = try await engine.sync()
        XCTAssertEqual(report.errors, [])
        return await local.payloads.values.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            SnapshotCase.Record(id: $0.id.uuidString, kind: $0.kind.rawValue, revision: $0.revision.uuidString, modifiedAt: VectorIO.iso($0.modifiedAt),
                                deviceID: $0.deviceID, meta: $0.meta.base64EncodedString(), body: $0.body?.base64EncodedString())
        }
    }

    // MARK: - engine-scenarios.json

    struct ScenarioCase: Codable, Equatable {
        /// Op arguments; ids and revisions are UUIDs, `at` is the step's clock time.
        struct Args: Codable, Equatable {
            var id: String?
            var kind: String?
            var title: String?
            var revision: String?
            var at: String?
            var seconds: Int?
            var count: Int?
        }
        struct Step: Codable, Equatable { var device: String; var op: String; var args: Args }
        struct Record: Codable, Equatable {
            /// "new" for a conflict copy, whose id and revision are fresh.
            var id: String
            var kind: String
            var revision: String
            var title: String
            var body: String?
            var conflictSource: String?
        }

        var name: String
        var steps: [Step]
        var expectRemoteKeys: [String]
        var expectLocal: [String: [Record]]
    }

    func testEngineScenarios() async throws {
        var cases: [ScenarioCase] = []
        for (name, steps) in Self.scenarios {
            cases.append(try await run(name, steps))
        }
        XCTAssertEqual(cases.count, 10)
        try VectorIO.check("engine-scenarios.json", cases)
    }

    private typealias ScriptStep = (device: String, op: String, args: ScenarioCase.Args)

    private static func step(_ device: String, _ op: String, id: String? = nil, kind: String? = nil, title: String? = nil,
                             revision: String? = nil, seconds: Int? = nil, count: Int? = nil) -> ScriptStep {
        let idString = id.map { VectorIO.uuid("scenario-\($0)").uuidString }
        let revisionString = revision.map { VectorIO.uuid("scenario-rev-\($0)").uuidString }
        return (device, op, .init(id: idString, kind: kind, title: title, revision: revisionString, seconds: seconds, count: count))
    }

    private static func sync(_ device: String) -> ScriptStep { step(device, "sync") }

    private static let scenarios: [(String, [ScriptStep])] = [
        ("create-propagates", [
            step("A", "create", id: "n1", kind: "note", title: "First", revision: "1"),
            sync("A"), sync("B"),
        ]),
        ("edit-propagates", [
            step("A", "create", id: "n1", kind: "note", title: "Draft", revision: "1"),
            sync("A"), sync("B"),
            step("A", "edit", id: "n1", title: "Final", revision: "2"),
            sync("A"), sync("B"),
        ]),
        ("concurrent-edit-conflict-copy", [
            step("A", "create", id: "n1", kind: "note", title: "Shared", revision: "1"),
            sync("A"), sync("B"),
            step("A", "edit", id: "n1", title: "From A", revision: "2"),
            step("B", "edit", id: "n1", title: "From B", revision: "3"),
            sync("A"), sync("B"), sync("A"),
        ]),
        ("delete-propagates", [
            step("A", "create", id: "n1", kind: "note", title: "Doomed", revision: "1"),
            sync("A"), sync("B"),
            step("A", "delete", id: "n1"),
            sync("A"), sync("B"),
        ]),
        ("edit-resurrects-remote-delete", [
            step("A", "create", id: "n1", kind: "note", title: "Keep me", revision: "1"),
            sync("A"), sync("B"),
            step("A", "delete", id: "n1"),
            step("B", "edit", id: "n1", title: "Kept", revision: "2"),
            sync("A"), sync("B"), sync("A"),
        ]),
        ("delete-loses-to-remote-edit", [
            step("A", "create", id: "n1", kind: "note", title: "Shared", revision: "1"),
            sync("A"), sync("B"),
            step("A", "delete", id: "n1"),
            step("B", "edit", id: "n1", title: "Edited", revision: "2"),
            sync("B"), sync("A"),
        ]),
        ("both-delete", [
            step("A", "create", id: "n1", kind: "note", title: "Gone", revision: "1"),
            sync("A"), sync("B"),
            step("A", "delete", id: "n1"),
            step("B", "delete", id: "n1"),
            sync("A"), sync("B"), sync("A"),
        ]),
        ("notebook-last-writer-wins", [
            step("A", "create", id: "b1", kind: "notebook", title: "Inbox", revision: "1"),
            sync("A"), sync("B"),
            step("A", "edit", id: "b1", title: "Inbox A", revision: "2"),
            step("B", "edit", id: "b1", title: "Inbox B", revision: "3"),
            sync("A"), sync("B"), sync("A"),
        ]),
        ("push-retried-after-network-failure", [
            step("A", "create", id: "n1", kind: "note", title: "Retry", revision: "1"),
            step("A", "failNextPuts", count: 1),
            sync("A"), sync("A"), sync("B"),
        ]),
        ("tombstone-swept-after-30-days", [
            step("A", "create", id: "n1", kind: "note", title: "Old", revision: "1"),
            sync("A"), sync("B"),
            step("A", "delete", id: "n1"),
            sync("A"), sync("B"),
            step("A", "advanceClock", seconds: 31 * 86_400),
            sync("A"),
        ]),
    ]

    /// Runs a script on a plaintext `InMemoryBackend`. Every step moves the shared clock one minute; create, edit and
    /// delete record that time in `args.at`.
    private func run(_ name: String, _ script: [ScriptStep]) async throws -> ScenarioCase {
        let backend = InMemoryBackend()
        let cipher = try await SyncEngine.connect(backend: backend, passphrase: nil, encryptNew: false).1
        let clock = FixedClock(VectorIO.epoch)
        var stores: [String: FakeLocalStore] = [:]
        var engines: [String: SyncEngine] = [:]
        var steps: [ScenarioCase.Step] = []
        for (device, op, scripted) in script {
            clock.advance(60)
            var args = scripted
            let store = stores[device] ?? FakeLocalStore()
            stores[device] = store
            let engine = engines[device] ?? SyncEngine(backend: backend, cipher: cipher, local: store,
                                                         stateURL: scratch.appendingPathComponent("\(name)-\(device).json"),
                                                         deviceID: "device-\(device)", deviceName: device, now: { clock.now() })
            engines[device] = engine
            switch op {
            case "create", "edit":
                args.at = VectorIO.iso(clock.now())
                let id = UUID(uuidString: args.id!)!
                let kind = op == "create" ? RecordKind(rawValue: args.kind!)! : await store.entries[id]!.record.kind
                let meta = try JSONSerialization.data(withJSONObject: ["title": args.title!], options: [.sortedKeys])
                try await store.apply(RecordPayload(id: id, kind: kind, revision: UUID(uuidString: args.revision!)!, modifiedAt: clock.now(),
                                                    deviceID: "device-\(device)", meta: meta,
                                                    body: kind == .note ? FakeLocalStore.body(for: args.title!) : nil))
            case "delete":
                args.at = VectorIO.iso(clock.now())
                await store.delete(UUID(uuidString: args.id!)!, at: clock.now())
            case "sync":
                _ = try await engine.sync()
            case "failNextPuts":
                await backend.failNextPuts(args.count!)
            case "advanceClock":
                clock.advance(TimeInterval(args.seconds!))
            default:
                XCTFail("Unknown op \(op)")
            }
            steps.append(.init(device: device, op: op, args: args))
        }
        var local: [String: [ScenarioCase.Record]] = [:]
        for (device, store) in stores {
            local[device] = await store.entries.values.map { entry in
                let copy = entry.conflictSource != nil
                return ScenarioCase.Record(id: copy ? "new" : entry.record.id.uuidString, kind: entry.record.kind.rawValue,
                                           revision: copy ? "new" : entry.record.revision.uuidString, title: entry.title,
                                           body: entry.body.map { String(decoding: $0, as: UTF8.self) }, conflictSource: entry.conflictSource)
            }.sorted { ($0.kind, $0.id, $0.title) < ($1.kind, $1.id, $1.title) }
        }
        // A conflict copy's id is fresh, so its keys name it "new", as its record does.
        let known = Set(script.compactMap(\.args.id))
        let keys = try await backend.list(prefix: RemoteLayout.root).map(\.key).map { key -> String in
            let file = key.split(separator: "/").last.map(String.init) ?? key
            let id = String(file.prefix(36))
            guard UUID(uuidString: id) != nil, !known.contains(id) else { return key }
            return key.replacingOccurrences(of: id, with: "new")
        }.sorted()
        return ScenarioCase(name: name, steps: steps, expectRemoteKeys: keys, expectLocal: local)
    }
}
