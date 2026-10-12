#if DEBUG
import AppKit

/// Debug-only persistence exercise (`INKWELL_STORE_SELFTEST=1`, use with `INKWELL_DATA_DIR`): forces body
/// write failures by making `notes/` read-only, checks library/index consistency, then quits.
/// `INKWELL_STORE_SELFTEST=newnote`: a new note whose first write fails must be listed in library.json and
/// get exactly one recovery copy; then simulates a crash (`_exit`, no terminate flush).
/// `INKWELL_STORE_SELFTEST=quit`: logs the on-disk state after launch and quits (for launch scenarios).
@MainActor
enum StoreSelfTest {
    private static var started = false

    static func startIfRequested() {
        guard !started, let mode = ProcessInfo.processInfo.environment["INKWELL_STORE_SELFTEST"] else { return }
        started = true
        switch mode {
        case "1": Task { @MainActor in await run() }
        case "newnote": Task { @MainActor in await runNewNote() }
        case "quit": Task { @MainActor in await runQuit() }
        default: break
        }
    }

    private static func log(_ s: String) {
        FileHandle.standardOutput.write(("STORETEST " + s + "\n").data(using: .utf8)!)
    }

    private static func diskTitle(_ store: NoteStore, _ id: UUID) -> String {
        guard let data = try? Data(contentsOf: store.libraryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notes = json["notes"] as? [[String: Any]],
              let note = notes.first(where: { ($0["id"] as? String) == id.uuidString }) else { return "<missing>" }
        return note["title"] as? String ?? "<no title>"
    }

    private static func diskIndex(_ store: NoteStore, _ id: UUID) -> String {
        guard let data = try? Data(contentsOf: store.searchIndexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [String: Any],
              let entry = entries[id.uuidString] as? [String: Any] else { return "<none>" }
        return String((entry["text"] as? String ?? "").prefix(40))
    }

    private static func setNotesWritable(_ store: NoteStore, _ writable: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: store.notesURL.path)
    }

    private static func recoveryCopies(_ store: NoteStore, _ id: UUID) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: store.recoveryURL.path)) ?? []
        return items.filter { $0.hasPrefix(id.uuidString) }.sorted()
    }

    private static func runNewNote() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let store = NoteStore.shared
        setNotesWritable(store, false)
        let id = store.createNote(in: nil, initial: NSAttributedString(string: "Brand new note\nzxcvnewuniq body")).id
        store.flush()
        let body = FileManager.default.fileExists(atPath: store.notesURL.appendingPathComponent("\(id.uuidString).rtfd").path)
        log("newnote id=\(id.uuidString) body on disk=\(body)")
        log("after first failed write: disk title=\(diskTitle(store, id).debugDescription) recovery=\(recoveryCopies(store, id))")
        store.flush()
        store.flush()
        log("after 2 more failed flushes: disk title=\(diskTitle(store, id).debugDescription) recovery count=\(recoveryCopies(store, id).count)")
        setNotesWritable(store, true)
        log("simulating crash (_exit) before any successful body write")
        _exit(0)
    }

    private static func runQuit() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let store = NoteStore.shared
        log("launched: notes in memory=\(store.notes.map(\.title))")
        NSApp.terminate(nil)
    }

    private static func run() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let store = NoteStore.shared
        guard let id = store.notes.first(where: { $0.id != store.selectedNoteID })?.id else { log("no note"); return }
        log("before: disk title=\(diskTitle(store, id).debugDescription)")

        setNotesWritable(store, false)
        store.updateBody(id, NSAttributedString(string: "Changed title\nqwertyuniq body"))
        store.flush()
        log("after failed write: memory title=\(store.note(with: id)?.title.debugDescription ?? "-") disk title=\(diskTitle(store, id).debugDescription) disk index=\(diskIndex(store, id).debugDescription)")

        setNotesWritable(store, true)
        store.flush()
        log("after retry: disk title=\(diskTitle(store, id).debugDescription) disk index=\(diskIndex(store, id).debugDescription)")

        store.updateBody(id, NSAttributedString(string: "Unsaved at quit\nlost body"))
        setNotesWritable(store, false)
        log("terminating with notes/ read-only")
        NSApp.terminate(nil)
    }
}
#endif
