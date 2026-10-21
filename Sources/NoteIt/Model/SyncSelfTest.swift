#if DEBUG
import AppKit
import NoteItSync

/// Debug-only sync-store exercise (`NOTEIT_SYNC_SELFTEST=1` with `NOTEIT_DATA_DIR`): runs scratch stores in
/// subfolders of the data dir (never `NoteStore.shared`), prints `SYNCTEST` lines and exits non-zero on failure.
/// `NOTEIT_SYNC_SELFTEST_LIBRARY=<path>`: a library.json copied (read-only) into a scratch store to check that
/// files without revisions still load.
@MainActor
enum SyncSelfTest {
    private static var failures = 0

    static func run() -> Int32 {
        guard let dir = AppEnvironment.value("DATA_DIR"), !dir.isEmpty else {
            log("FAIL NOTEIT_DATA_DIR must point at a scratch folder")
            return 2
        }
        let base = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        for sub in ["legacy", "a", "b", "perf-src", "perf-dst", "copy-1", "copy-2", "att", "nb-a", "nb-b", "sf-a", "sf-b"] { try? FileManager.default.removeItem(at: base.appendingPathComponent(sub)) }

        legacyLibrary(base)
        let a = NoteStore(rootURL: base.appendingPathComponent("a", isDirectory: true))
        let b = NoteStore(rootURL: base.appendingPathComponent("b", isDirectory: true))
        revisions(a)
        roundTrip(a, b, base)
        conflictCopy(a, b)
        journal(a, base)
        remoteDeletions(b)
        adapter(a, b)
        stagedEditorCommit(a, b)
        conflictResolution(a)
        deterministicRevisions(base)
        attachments(base)
        exportCache(a)
        bulkApply(base)
        nestedNotebooks(base)
        smartFolders(base)
        NoteStore.syncJournalEnabled = false

        log(failures == 0 ? "PASS all checks" : "FAIL \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Cases

    private static func legacyLibrary(_ base: URL) {
        guard let source = AppEnvironment.value("SYNC_SELFTEST_LIBRARY") else {
            log("skip legacy library (NOTEIT_SYNC_SELFTEST_LIBRARY not set)")
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
        let token = NotificationCenter.default.addObserver(forName: .noteItLocalChange, object: b, queue: nil) { _ in posted += 1 }
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
        check(posted == 0, "roundtrip: remote apply posts no noteItLocalChange")
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

    /// A2: an editor snapshot staged for a later main-queue turn must win over a pull that arrives first.
    private static func stagedEditorCommit(_ a: NoteStore, _ b: NoteStore) {
        guard let id = b.notes.first?.id, a.note(with: id) != nil || true else { return }
        let adapterB = NoteStoreSyncAdapter(store: b, deviceID: "dev-b")
        _ = runAsync { await adapterB.records() }
        let before = b.note(with: id)?.revision
        b.stageEditorCommit(id, styledBody(title: "Typed locally", line: "keystrokes"))
        check(b.hasStagedEditorBody(id), "staged: snapshot pending")
        guard let remote = makePayload(from: b, id: id) else { return check(false, "staged: payload") }
        let result = runAsync { try await adapterB.apply(remote) }
        if case .failure(let error) = result, case NoteStoreSyncAdapter.AdapterError.localEditInProgress = error {
            check(true, "staged: apply refused while a commit was staged")
        } else {
            check(false, "staged: apply should be refused, got \(result)")
        }
        check(!b.hasStagedEditorBody(id), "staged: snapshot committed before the revision check")
        check(b.note(with: id)?.title == "Typed locally" && b.note(with: id)?.revision != before, "staged: keystrokes kept with a new revision")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(b.body(for: id).string.contains("keystrokes"), "staged: later main-queue turn is a no-op")
        let retry = runAsync { () -> UUID? in
            _ = await adapterB.records()
            try await adapterB.apply(remote)
            return await adapterB.revision(of: id, kind: .note)
        }
        if case .success(let rev) = retry {
            check(rev == remote.revision, "staged: next pass applies once local edit is a known base")
        } else {
            check(false, "staged: retry \(retry)")
        }
    }

    /// A6: conflict copies leave the Conflicts filter when edited, resolved, or their original is deleted.
    private static func conflictResolution(_ a: NoteStore) {
        guard let original = a.notes.first(where: { $0.conflictSource == nil })?.id,
              let payload = try? a.exportPayload(id: original, kind: .note, deviceID: "dev-a") else { return check(false, "resolve: no note") }
        func copy() -> NoteMeta? { try? a.importConflictCopy(payload, fromDevice: "Other Mac") }
        guard let edited = copy(), let marked = copy(), let orphanedLocal = copy() else { return check(false, "resolve: import") }
        check(edited.conflictOriginalID == original, "resolve: copy remembers its original")
        let filtered = Set(a.notes(for: .conflicts, search: "").map(\.id))
        check(filtered.isSuperset(of: [edited.id, marked.id, orphanedLocal.id]) && !filtered.contains(original),
              "resolve: Conflicts filter shows only copies (\(filtered.count))")

        a.updateBody(edited.id, styledBody(title: "Merged by hand", line: "x"))
        check(a.note(with: edited.id)?.conflictSource == nil && a.note(with: edited.id)?.revision != edited.revision,
              "resolve: editing a copy clears the flag as a user edit")
        a.markConflictResolved(marked.id)
        check(a.note(with: marked.id)?.conflictSource == nil && a.note(with: marked.id)?.revision != marked.revision,
              "resolve: Mark Resolved clears the flag with a new revision")

        a.deleteNote(original)
        let after = a.note(with: orphanedLocal.id)
        check(after?.conflictSource == nil && after?.revision != orphanedLocal.revision,
              "resolve: local delete of the original clears copies (bumped)")
        check(a.notes(for: .conflicts, search: "").isEmpty, "resolve: Conflicts filter empty")

        guard let second = a.notes.first(where: { $0.conflictSource == nil })?.id,
              let p2 = try? a.exportPayload(id: second, kind: .note, deviceID: "dev-a"),
              let remoteCopy = try? a.importConflictCopy(p2, fromDevice: "Other Mac") else { return check(false, "resolve: second copy") }
        a.applyRemoteDeletion(second, kind: .note)
        let kept = a.note(with: remoteCopy.id)
        check(kept?.conflictSource == nil && kept?.revision == remoteCopy.revision,
              "resolve: remote delete of the original clears copies without a new revision")
    }

    /// A3: libraries copied between Macs (no revisions yet) get identical revisions; differing content doesn't.
    private static func deterministicRevisions(_ base: URL) {
        let src = base.appendingPathComponent("copy-1", isDirectory: true)
        let dst = base.appendingPathComponent("copy-2", isDirectory: true)
        let seed = NoteStore(rootURL: src)
        for i in 0..<3 { _ = seed.createNote(in: seed.notebooks.first?.id, initial: styledBody(title: "Copied \(i)", line: "same")) }
        seed.flush()
        let library = src.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: library), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return check(false, "copied: read library")
        }
        for key in ["notes", "notebooks"] {
            json[key] = (json[key] as? [[String: Any]])?.map { var r = $0; r["revision"] = nil; return r }
        }
        guard let stripped = try? JSONSerialization.data(withJSONObject: json) else { return check(false, "copied: strip") }
        try? stripped.write(to: library)
        try? FileManager.default.copyItem(at: src, to: dst)

        let one = NoteStore(rootURL: src), two = NoteStore(rootURL: dst)
        check(one.notes.allSatisfy { $0.revision == nil }, "copied: revisions stripped")
        guard let changedNote = two.notes.last?.id, let changedBook = two.notebooks.last?.id,
              let renamed = two.notes.first(where: { $0.id != changedNote })?.id else { return check(false, "copied: no records") }
        two.updateBody(changedNote, styledBody(title: "Different on Mac 2", line: "x"))
        two.flush()
        if let i = two.notes.firstIndex(where: { $0.id == changedNote }) { two.notes[i].revision = nil }
        var nb = two.notebook(with: changedBook)!
        nb.name += " (renamed)"
        two.updateNotebook(nb)
        if let i = two.notebooks.firstIndex(where: { $0.id == changedBook }) { two.notebooks[i].revision = nil }
        let adapter1 = NoteStoreSyncAdapter(store: one, deviceID: "m1"), adapter2 = NoteStoreSyncAdapter(store: two, deviceID: "m2")
        guard case .success(let (r1, r2)) = runAsync({ (await adapter1.records(), await adapter2.records()) }) else {
            return check(false, "copied: records")
        }
        let map1 = Dictionary(uniqueKeysWithValues: r1.map { ($0.id, $0.revision) })
        let map2 = Dictionary(uniqueKeysWithValues: r2.map { ($0.id, $0.revision) })
        let same = map1.keys.filter { $0 != changedNote && $0 != changedBook }
        check(!same.isEmpty && same.allSatisfy { map1[$0] == map2[$0] }, "copied: \(same.count) identical records get equal revisions")
        check(map1[changedNote] != map2[changedNote], "copied: different body -> different revision")
        check(map1[changedBook] != map2[changedBook], "copied: different notebook name -> different revision")
        check(map1[renamed] == map2[renamed], "copied: unchanged sibling still equal")
        let reloaded = NoteStore(rootURL: src)
        check(reloaded.notes.allSatisfy { map1[$0.id] == $0.revision }, "copied: derived revisions persisted")
        let fresh = NoteStore(rootURL: dst)
        let again = Dictionary(uniqueKeysWithValues: fresh.syncRecords().map { ($0.id, $0.revision) })
        check(again == map2, "copied: stable across reloads")
    }

    /// RTFD with an image attachment survives the off-main serialize/parse path used by export and apply.
    private static func attachments(_ base: URL) {
        let store = NoteStore(rootURL: base.appendingPathComponent("att", isDirectory: true))
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return check(false, "attachment: image")
        }
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "dot.png"
        let text = NSMutableAttributedString(attributedString: styledBody(title: "With image", line: "below"))
        text.append(NSAttributedString(string: "\n"))
        text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let note = store.createNote(in: nil, initial: text)
        store.flush()
        let adapter = NoteStoreSyncAdapter(store: store, deviceID: "att")
        let result = runAsync { () -> (Int, Int, Bool) in
            // runAsync's detached task: this parse runs off the main thread, like the adapter's apply.
            let payload = try await adapter.export(note.id, kind: .note)
            let parsed = try NoteStore.deserializeBody(payload.body ?? Data())
            var count = 0, bytes = 0
            parsed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: parsed.length)) { value, _, _ in
                guard let a = value as? NSTextAttachment else { return }
                count += 1
                bytes = a.fileWrapper?.regularFileContents?.count ?? 0
            }
            return (count, bytes, parsed.string.contains("With image"))
        }
        if case .success(let (count, bytes, title)) = result {
            check(count == 1 && bytes == png.count && title, "attachment: off-main RTFD round trip (\(count) image, \(bytes) bytes)")
        } else {
            check(false, "attachment: \(result)")
        }
    }

    /// Export reads bodies that aren't cached straight from disk instead of filling the LRU cache.
    private static func exportCache(_ a: NoteStore) {
        a.flush()
        let reopened = NoteStore(rootURL: a.rootURL)
        let adapter = NoteStoreSyncAdapter(store: reopened, deviceID: "dev-a")
        let before = reopened.debugCachedBodyCount
        let ids = reopened.notes.map(\.id)
        let result = runAsync { () -> Int in
            var bytes = 0
            for id in ids { bytes += try await adapter.export(id, kind: .note).body?.count ?? 0 }
            return bytes
        }
        if case .success(let bytes) = result {
            check(bytes > 0 && reopened.debugCachedBodyCount == before,
                  "export: \(ids.count) notes, \(bytes) bytes, body cache \(before) -> \(reopened.debugCachedBodyCount)")
        } else {
            check(false, "export: \(result)")
        }
    }

    /// A1: applies 500 remote notes through the adapter and reports main-actor time per apply.
    private static func bulkApply(_ base: URL) {
        let source = NoteStore(rootURL: base.appendingPathComponent("perf-src", isDirectory: true))
        for i in 0..<500 {
            _ = source.createNote(in: nil, initial: styledBody(title: "Bulk \(i)", line: String(repeating: "lorem ipsum \(i) ", count: 40)))
        }
        source.flush()
        let ids = source.notes.map(\.id)
        let exporter = NoteStoreSyncAdapter(store: source, deviceID: "src")
        guard case .success(let payloads) = runAsync({ () -> [RecordPayload] in
            var out: [RecordPayload] = []
            for id in ids { out.append(try await exporter.export(id, kind: .note)) }
            return out
        }, timeout: 120) else { return check(false, "bulk: export") }

        let target = NoteStore(rootURL: base.appendingPathComponent("perf-dst", isDirectory: true))
        let adapter = NoteStoreSyncAdapter(store: target, deviceID: "dst")
        _ = runAsync { await adapter.records() }
        let start = Date()
        SyncMainThreadMetrics.reset()
        let result = runAsync({ () -> Int in
            for payload in payloads { try await adapter.apply(payload) }
            return payloads.count
        }, timeout: 300)
        let elapsed = Date().timeIntervalSince(start)
        let applies = SyncMainThreadMetrics.count
        let maxMs = Double(SyncMainThreadMetrics.maxNanos) / 1e6
        let avgMs = applies == 0 ? 0 : Double(SyncMainThreadMetrics.totalNanos) / 1e6 / Double(applies)
        if case .success(let n) = result {
            check(n == payloads.count && ids.allSatisfy { target.note(with: $0) != nil }, "bulk: applied \(n) remote notes")
            log(String(format: "bulk: total %.2fs, main-actor per apply avg %.2fms p50 %.2fms p95 %.2fms max %.2fms (hop #%d of %d)",
                       elapsed, avgMs, Double(SyncMainThreadMetrics.percentile(0.5)) / 1e6,
                       Double(SyncMainThreadMetrics.percentile(0.95)) / 1e6, maxMs, SyncMainThreadMetrics.slowestIndex, applies))
        } else {
            check(false, "bulk: \(result)")
        }
        let reloaded = NoteStore(rootURL: target.rootURL)
        check(reloaded.notes.count == target.notes.count, "bulk: every apply persisted in library.json before returning")
        _ = runAsync { await adapter.passDidFinish() }
        let index = (try? Data(contentsOf: target.searchIndexURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let indexed = (index?["entries"] as? [String: Any])?.count ?? (index?.count ?? 0)
        check(indexed >= ids.count, "bulk: search index saved once at pass end (\(indexed) entries)")

        // Reference: what one apply used to cost when it saved library.json and the whole search index.
        target.updateBody(ids[0], styledBody(title: "Bulk 0", line: "touch"))
        let flushStart = DispatchTime.now().uptimeNanoseconds
        target.markSearchIndexDirtyForDebug()
        target.flush()
        log(String(format: "bulk: old per-apply flush at %d notes ~%.2fms", target.notes.count,
                   Double(DispatchTime.now().uptimeNanoseconds - flushStart) / 1e6))
    }

    /// A nests a notebook, B applies it, an older client strips `parent` while renaming, and A keeps and repairs it.
    private static func nestedNotebooks(_ base: URL) {
        let a = NoteStore(rootURL: base.appendingPathComponent("nb-a", isDirectory: true))
        let b = NoteStore(rootURL: base.appendingPathComponent("nb-b", isDirectory: true))
        let parent = a.createNotebook(name: "Work", symbol: "folder", colorHex: "#0A84FF")
        let child = a.createNotebook(name: "Clients", symbol: "folder", colorHex: "#0A84FF", parentID: parent.id)
        let countA = a.notebooks.count, countB = b.notebooks.count + 2
        do {
            for id in [parent.id, child.id] { try b.applyRemote(try a.exportPayload(id: id, kind: .notebook, deviceID: "nb-a")) }
            check(b.notebook(with: child.id)?.parent == parent.id, "nested: parent reaches the other Mac")

            let exported = try a.exportPayload(id: child.id, kind: .notebook, deviceID: "nb-a")
            guard var json = try JSONSerialization.jsonObject(with: exported.meta) as? [String: Any] else {
                return check(false, "nested: read meta")
            }
            json["parent"] = nil
            json["name"] = "Customers"
            let legacy = RecordPayload(id: child.id, kind: .notebook, revision: UUID(), modifiedAt: Date(), deviceID: "old",
                                       meta: try JSONSerialization.data(withJSONObject: json))
            try a.applyRemote(legacy)
            let repaired = a.notebook(with: child.id)
            check(repaired?.name == "Customers" && repaired?.parent == parent.id, "nested: older client's rename keeps the parent")
            check(repaired?.revision != legacy.revision, "nested: repair gets a new revision")

            try b.applyRemote(try a.exportPayload(id: child.id, kind: .notebook, deviceID: "nb-a"))
            check(b.notebook(with: child.id)?.parent == parent.id && b.notebook(with: child.id)?.name == "Customers",
                  "nested: repair reaches the other Mac")
            check(a.notebooks.count == countA && b.notebooks.count == countB, "nested: no duplicate notebooks")
        } catch {
            check(false, "nested: \(error)")
        }
        a.flush()
        b.flush()
    }

    private static func smartFolders(_ base: URL) {
        let a = NoteStore(rootURL: base.appendingPathComponent("sf-a", isDirectory: true))
        let b = NoteStore(rootURL: base.appendingPathComponent("sf-b", isDirectory: true))
        let notesB = b.notes.count
        do {
            let folder = try a.createSmartFolder(name: "Synced", query: "is:pinned")
            var payload = try a.exportPayload(id: folder.id, kind: .smartFolder, deviceID: "sf-a")
            guard var json = try JSONSerialization.jsonObject(with: payload.meta) as? [String: Any] else {
                return check(false, "smart: read meta")
            }
            json["futureField"] = 7
            payload.meta = try JSONSerialization.data(withJSONObject: json)
            try b.applyRemote(payload)
            check(b.smartFolder(with: folder.id)?.query == "is:pinned" && !b.hasUnsavedSmartFolders, "smart: folder reaches the other Mac")
            try b.updateSmartFolder(folder.id, name: "Renamed", query: "is:pinned", symbol: "star")
            let back = try JSONSerialization.jsonObject(with: b.exportPayload(id: folder.id, kind: .smartFolder, deviceID: "sf-b").meta)
            check((back as? [String: Any])?["futureField"] as? Int == 7, "smart: unknown keys survive a local edit")
            b.applyRemoteDeletion(folder.id, kind: .smartFolder)
            check(b.smartFolder(with: folder.id) == nil && !b.hasUnsavedSmartFolders, "smart: tombstone removes it")
            check(b.notes.count == notesB, "smart: notes untouched")
        } catch {
            check(false, "smart: \(error)")
        }
        a.flush()
        b.flush()
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
    private static func runAsync<T>(_ work: @escaping @Sendable () async throws -> T, timeout: TimeInterval = 10) -> Result<T, Error> {
        let box = ResultBox<T>()
        Task.detached {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(timeout)
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
