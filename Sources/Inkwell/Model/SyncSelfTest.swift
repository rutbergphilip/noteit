#if DEBUG
import AppKit
import InkwellSync

/// Debug-only sync-store exercise (`INKWELL_SYNC_SELFTEST=1` with `INKWELL_DATA_DIR`): runs scratch stores in
/// subfolders of the data dir (never `NoteStore.shared`), prints `SYNCTEST` lines and exits non-zero on failure.
/// `INKWELL_SYNC_SELFTEST_LIBRARY=<path>`: a library.json copied (read-only) into a scratch store to check that
/// files without revisions still load.
@MainActor
enum SyncSelfTest {
    private static var failures = 0

    static func run() -> Int32 {
        guard let dir = ProcessInfo.processInfo.environment["INKWELL_DATA_DIR"], !dir.isEmpty else {
            log("FAIL INKWELL_DATA_DIR must point at a scratch folder")
            return 2
        }
        let base = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        for sub in ["legacy", "a", "b"] { try? FileManager.default.removeItem(at: base.appendingPathComponent(sub)) }

        legacyLibrary(base)
        let a = NoteStore(rootURL: base.appendingPathComponent("a", isDirectory: true))
        let b = NoteStore(rootURL: base.appendingPathComponent("b", isDirectory: true))
        revisions(a)
        roundTrip(a, b, base)
        conflictCopy(a, b)
        journal(a, base)
        remoteDeletions(b)
        adapter(a, b)
        NoteStore.syncJournalEnabled = false

        log(failures == 0 ? "PASS all checks" : "FAIL \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Cases

    private static func legacyLibrary(_ base: URL) {
        guard let source = ProcessInfo.processInfo.environment["INKWELL_SYNC_SELFTEST_LIBRARY"] else {
            log("skip legacy library (INKWELL_SYNC_SELFTEST_LIBRARY not set)")
            return
        }
        let root = base.appendingPathComponent("legacy", isDirectory: true)
        let library = root.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(contentsOf: URL(fileURLWithPath: source)).write(to: library)
        } catch {
            check(false, "legacy: copy fixture (\(error))")
            return
        }
        let raw = (try? String(contentsOf: library, encoding: .utf8)) ?? ""
        let store = NoteStore(rootURL: root)
        check(!store.notes.isEmpty, "legacy: decoded \(store.notes.count) notes, \(store.notebooks.count) notebooks")
        check(!raw.contains("\"revision\""), "legacy: fixture has no revision keys")
        check(store.notes.allSatisfy { $0.revision == nil } && store.notebooks.allSatisfy { $0.revision == nil },
              "legacy: revisions start nil")
        let records = store.syncRecords()
        check(records.count == store.notes.count + store.notebooks.count, "legacy: syncRecords covers every record")
        let reloaded = NoteStore(rootURL: root)
        let before = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.revision) })
        let after = reloaded.syncRecords()
        check(after.allSatisfy { before[$0.id] == $0.revision }, "legacy: assigned revisions persisted and stable")
        check(reloaded.notes.map(\.title) == store.notes.map(\.title), "legacy: titles unchanged")
    }

    private static func revisions(_ a: NoteStore) {
        let records = a.syncRecords()
        check(!records.isEmpty && records.count == a.notes.count + a.notebooks.count, "revisions: assigned to \(records.count) records")
        guard let id = a.notes.first?.id, let rev0 = a.note(with: id)?.revision else { return check(false, "revisions: no note") }

        a.updateBody(id, styledBody(title: "Sync title", line: "first edit"))
        let rev1 = a.note(with: id)?.revision
        check(rev1 != nil && rev1 != rev0, "revisions: updateBody changes revision \(short(rev0)) -> \(short(rev1))")
        a.togglePin(id)
        check(a.note(with: id)?.revision != rev1, "revisions: togglePin bumps")
        let rev2 = a.note(with: id)?.revision
        a.moveNote(id, to: a.sortedNotebooks.last?.id)
        check(a.note(with: id)?.revision != rev2, "revisions: moveNote bumps")

        let nb = a.createNotebook(name: "Sync NB", symbol: "tray", colorHex: "#0A84FF")
        check(nb.revision != nil && nb.modifiedAt != nil, "revisions: createNotebook has revision + modifiedAt")
        var renamed = nb
        renamed.name = "Sync NB renamed"
        a.updateNotebook(renamed)
        let nbRev = a.notebook(with: nb.id)?.revision
        check(nbRev != nb.revision, "revisions: updateNotebook bumps")
        a.updateNotebook(a.notebook(with: nb.id)!)
        check(a.notebook(with: nb.id)?.revision == nbRev, "revisions: no-op updateNotebook keeps revision")
        let order = a.sortedNotebooks.map { ($0.id, $0.revision) }
        a.moveNotebooks(from: IndexSet(integer: order.count - 1), to: 0)
        let moved = a.sortedNotebooks.filter { nbk in order.first { $0.0 == nbk.id }?.1 != nbk.revision }.count
        check(moved == order.count, "revisions: reorder bumps the \(moved) notebooks whose position changed")

        let captured = a.captureNote(title: "Captured", body: "quick", in: nil)
        check(captured?.revision != nil, "revisions: captureNote gets a revision")
        a.flush()
    }

    private static func roundTrip(_ a: NoteStore, _ b: NoteStore, _ base: URL) {
        guard let id = a.notes.first?.id else { return check(false, "roundtrip: no note") }
        let text = styledBody(title: "Round trip ✓", line: "body with #synctag and emoji 🎉")
        a.updateBody(id, text)
        a.flush()
        let sentinels = paragraphSentinels(text)
        guard let payload = try? a.exportPayload(id: id, kind: .note, deviceID: "dev-a") else { return check(false, "roundtrip: export") }
        check(payload.revision == a.note(with: id)?.revision && payload.body != nil, "roundtrip: export carries revision and \(payload.body?.count ?? 0) body bytes")

        if let nbID = a.note(with: id)?.notebookID, let nbPayload = try? a.exportPayload(id: nbID, kind: .notebook, deviceID: "dev-a") {
            try? b.applyRemote(nbPayload)
            check(b.notebook(with: nbID)?.revision == nbPayload.revision && b.notebook(with: nbID)?.name == a.notebook(with: nbID)?.name,
                  "roundtrip: notebook applied with its revision")
        }

        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .inkwellLocalChange, object: b, queue: nil) { _ in posted += 1 }
        do { try b.applyRemote(payload) } catch { check(false, "roundtrip: apply threw \(error)") }
        NotificationCenter.default.removeObserver(token)
        let applied = b.note(with: id)
        check(applied?.revision == payload.revision, "roundtrip: applyRemote keeps payload revision")
        check(applied?.title == a.note(with: id)?.title, "roundtrip: title \(applied?.title.debugDescription ?? "nil")")
        check(applied?.tags == ["synctag"], "roundtrip: tags derived \(applied?.tags ?? [])")
        check(b.body(for: id).string == text.string, "roundtrip: body text equal")
        let gotSentinels = paragraphSentinels(b.body(for: id))
        check(gotSentinels == sentinels, "roundtrip: paragraph sentinels \(gotSentinels)")
        check(b.externallyUpdatedNoteID == id, "roundtrip: externallyUpdatedNoteID set")
        check(posted == 0, "roundtrip: remote apply posts no inkwellLocalChange")
        let search = b.notes(for: .allNotes, search: "emoji synctag").map(\.id)
        check(search.contains(id), "roundtrip: search index refreshed")

        let reloaded = NoteStore(rootURL: base.appendingPathComponent("b", isDirectory: true))
        check(reloaded.note(with: id)?.revision == payload.revision, "roundtrip: revision persisted in library.json")
        check(paragraphSentinels(reloaded.body(for: id)) == sentinels && reloaded.body(for: id).string == text.string,
              "roundtrip: body persisted through the RTFD write path")

        // Remote edit of the note open (selected) in the editor.
        b.updateBody(id, styledBody(title: "Edited on B", line: "second"))
        b.flush()
        guard let edited = try? b.exportPayload(id: id, kind: .note, deviceID: "dev-b") else { return check(false, "roundtrip: export B") }
        a.selectedNoteID = id
        a.externallyUpdatedNoteID = nil
        try? a.applyRemote(edited)
        check(a.note(with: id)?.title == "Edited on B" && a.note(with: id)?.revision == edited.revision,
              "roundtrip: selected note updated in place, revision not bumped")
        check(a.externallyUpdatedNoteID == id && a.selectedNoteID == id, "roundtrip: selected note flagged as externally updated")
    }

    private static func conflictCopy(_ a: NoteStore, _ b: NoteStore) {
        guard let id = a.selectedNoteID, let payload = try? b.exportPayload(id: id, kind: .note, deviceID: "dev-b") else {
            return check(false, "conflict: no payload")
        }
        let count = a.notes.count
        guard let copy = try? a.importConflictCopy(payload, fromDevice: "Other Mac") else { return check(false, "conflict: import threw") }
        check(copy.id != id && a.notes.count == count + 1, "conflict: new id")
        check(copy.title.hasPrefix("Edited on B (conflict — Other Mac, "), "conflict: title \(copy.title.debugDescription)")
        check(copy.conflictSource == "Other Mac", "conflict: conflictSource set")
        check(copy.revision != nil && copy.revision != payload.revision, "conflict: fresh revision")
        check(a.note(with: id)?.revision == payload.revision, "conflict: original untouched")
    }

    private static func journal(_ a: NoteStore, _ base: URL) {
        NoteStore.syncJournalEnabled = false
        guard a.notes.count >= 3 else { return check(false, "journal: not enough notes") }
        let first = a.notes[0].id
        a.deleteNote(first)
        check(a.syncDeletions().isEmpty && !FileManager.default.fileExists(atPath: a.syncDeletionsURL.path),
              "journal: disabled -> nothing journaled")

        NoteStore.syncJournalEnabled = true
        let second = a.notes[0].id
        a.deleteNote(second)
        let nb = a.createNotebook(name: "Doomed", symbol: "tray", colorHex: "#FF453A")
        a.deleteNotebook(nb.id)
        let journal = a.syncDeletions()
        check(journal[second]?.kind == .note && journal[nb.id]?.kind == .notebook && journal[first] == nil,
              "journal: enabled -> note + notebook journaled")
        let reloaded = NoteStore(rootURL: base.appendingPathComponent("a", isDirectory: true))
        let persisted = reloaded.syncDeletions()
        check(persisted.count == journal.count && journal.allSatisfy { id, entry in
            persisted[id].map { $0.kind == entry.kind && abs($0.deletedAt.timeIntervalSince(entry.deletedAt)) < 1 } ?? false
        }, "journal: persisted to sync-deletions.json")
        a.clearSyncDeletion(nb.id)
        check(a.syncDeletions().keys.sorted { $0.uuidString < $1.uuidString } == [second], "journal: clearSyncDeletion")

        // A remote edit that beats a local delete brings the note back and clears its journal entry and tombstone.
        check(reloaded.note(with: second) == nil, "journal: deleted note stays deleted after reload")
        let resurrect = makePayload(from: a, id: second)
        if let resurrect {
            try? a.applyRemote(resurrect)
            let tombstones = (try? String(contentsOf: a.tombstonesURL, encoding: .utf8)) ?? ""
            check(a.note(with: second) != nil && a.syncDeletions()[second] == nil && !tombstones.contains(second.uuidString),
                  "journal: remote apply resurrects a locally deleted note")
            let again = NoteStore(rootURL: base.appendingPathComponent("a", isDirectory: true))
            check(again.note(with: second) != nil && !again.body(for: second).string.isEmpty, "journal: resurrection survives reload")
        }
    }

    private static func remoteDeletions(_ b: NoteStore) {
        NoteStore.syncJournalEnabled = true
        guard let nb = b.notebooks.first(where: { nbk in b.notes.contains { $0.notebookID == nbk.id } }) else {
            return check(false, "remote delete: no notebook with notes")
        }
        let homed = b.notes.filter { $0.notebookID == nb.id }
        b.applyRemoteDeletion(nb.id, kind: .notebook)
        let after = homed.compactMap { b.note(with: $0.id) }
        check(b.notebook(with: nb.id) == nil, "remote delete: notebook removed")
        check(after.count == homed.count && after.allSatisfy { $0.notebookID == nil }, "remote delete: \(after.count) notes re-homed")
        check(zip(homed, after).allSatisfy { $0.revision == $1.revision }, "remote delete: re-homed notes keep revisions")

        guard let note = b.notes.first?.id else { return }
        b.applyRemoteDeletion(note, kind: .note)
        b.flush()
        let trashed = ((try? FileManager.default.contentsOfDirectory(atPath: b.trashURL.path)) ?? []).contains { $0.hasPrefix(note.uuidString) }
        check(b.note(with: note) == nil && trashed, "remote delete: note removed, body in .trash")
        check(b.syncDeletions().isEmpty, "remote delete: not journaled")
    }

    private static func adapter(_ a: NoteStore, _ b: NoteStore) {
        let adapterA = NoteStoreSyncAdapter(store: a, deviceID: "dev-a")
        let adapterB = NoteStoreSyncAdapter(store: b, deviceID: "dev-b")
        let expected = a.notes.count + a.notebooks.count
        guard let id = a.notes.last?.id else { return check(false, "adapter: no note") }
        let result = runAsync { () -> (Int, UUID?) in
            let records = await adapterA.records()
            let payload = try await adapterA.export(id, kind: .note)
            try await adapterB.apply(payload)
            return (records.count, payload.revision)
        }
        switch result {
        case .success(let (count, revision)):
            check(count == expected, "adapter: records via MainActor hop (\(count))")
            check(b.note(with: id)?.revision == revision, "adapter: export -> apply across stores")
        case .failure(let error):
            check(false, "adapter: \(error)")
        }
    }

    // MARK: Helpers

    private static func makePayload(from store: NoteStore, id: UUID) -> RecordPayload? {
        let meta = NoteMeta(id: id, notebookID: nil, title: "", preview: "", isPinned: false,
                            createdAt: Date(), updatedAt: Date(), tags: [], revision: UUID())
        guard let data = try? NoteStore.encoder.encode(meta),
              let body = try? NoteStore.serializeBody(styledBody(title: "Back from remote", line: "kept")) else { return nil }
        return RecordPayload(id: id, kind: .note, revision: meta.revision!, modifiedAt: Date(), deviceID: "dev-x", meta: data, body: body)
    }

    private static func styledBody(title: String, line: String) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let parts: [(String, BlockKind)] = [(title, .title), ("Heading", .heading), (line, .body),
                                            ("let x = 1", .code), ("A quote", .quote), ("Sub", .subheading)]
        for (i, (string, kind)) in parts.enumerated() {
            text.append(NSAttributedString(string: string + (i == parts.count - 1 ? "" : "\n"), attributes: [
                .font: EditorStyle.font(for: kind),
                .paragraphStyle: EditorStyle.paragraphStyle(for: kind),
            ]))
        }
        return text
    }

    private static func paragraphSentinels(_ text: NSAttributedString) -> [CGFloat] {
        let ns = text.string as NSString
        var result: [CGFloat] = []
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            result.append((text.attribute(.paragraphStyle, at: para.location, effectiveRange: nil) as? NSParagraphStyle)?.defaultTabInterval ?? -1)
            location = NSMaxRange(para)
        }
        return result
    }

    /// Runs async work from this synchronous launch hook; the nested run loop lets `MainActor.run` hops proceed.
    private static func runAsync<T>(_ work: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
        let box = ResultBox<T>()
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(10)
        while box.result == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.result ?? .failure(CocoaError(.featureUnsupported))
    }

    private static func short(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(8)) } ?? "nil"
    }

    private static func check(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        log((ok ? "ok   " : "FAIL ") + message)
    }

    private static func log(_ s: String) {
        FileHandle.standardOutput.write(("SYNCTEST " + s + "\n").data(using: .utf8)!)
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
#endif
