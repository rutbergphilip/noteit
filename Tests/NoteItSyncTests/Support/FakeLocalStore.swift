import Foundation
@testable import NoteItSync

/// In-memory `SyncLocalStore`. Meta is JSON `{title, conflictSource}`; notes carry a body derived from the title.
public actor FakeLocalStore: SyncLocalStore {
    public struct Entry: Sendable, Equatable {
        public var record: LocalRecord
        public var title: String
        public var body: Data?
        public var conflictSource: String?
    }

    struct Meta: Codable {
        var title: String
        var conflictSource: String?
    }

    public private(set) var entries: [UUID: Entry] = [:]
    private var journal: [UUID: LocalDeletion] = [:]
    public private(set) var applyCount = 0
    /// Titles this store can't keep; applying or copying them throws `SyncRecordRefused`.
    public var refusedTitles: Set<String> = []
    public private(set) var refusedCount = 0

    public func refuse(_ titles: Set<String>) { refusedTitles = titles }
    /// Notes this store can't export or apply yet; they throw `SyncRecordDeferred`.
    public private(set) var deferredIDs: Set<UUID> = []

    public func deferRecords(_ ids: Set<UUID>) { deferredIDs = ids }

    /// With a session, note bodies are exported as `RTFD:<body>` or `DOC:<body>` by the session's body encoding, with
    /// the matching `bodyFormat` (web-app Task 0.4); applied bodies lose the prefix again. Without one, bodies travel
    /// as they are, as before.
    private let session: StoreSessionRef?
    /// Overrides the exported `bodyFormat` per note (publish-validation tests); `.some(nil)` exports none.
    public private(set) var formatOverrides: [UUID: String?] = [:]
    /// The `bodyFormat` of the last payload applied for each note.
    public private(set) var appliedFormats: [UUID: String?] = [:]

    public func overrideFormat(_ id: UUID, _ format: String?) { formatOverrides[id] = .some(format) }
    public func clearFormatOverride(_ id: UUID) { formatOverrides[id] = nil }

    public init(session: StoreSessionRef? = nil) {
        self.session = session
    }

    @discardableResult
    public func create(kind: RecordKind = .note, title: String) -> UUID {
        let id = UUID()
        entries[id] = Entry(
            record: LocalRecord(id: id, kind: kind, revision: UUID(), modifiedAt: Date()),
            title: title,
            body: kind == .note ? Self.body(for: title) : nil
        )
        return id
    }

    public func edit(_ id: UUID, title: String) {
        guard var entry = entries[id] else { return }
        entry.title = title
        if entry.record.kind == .note { entry.body = Self.body(for: title) }
        entry.record.revision = UUID()
        entry.record.modifiedAt = Date()
        entries[id] = entry
    }

    public func delete(_ id: UUID, at date: Date = Date()) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        journal[id] = LocalDeletion(kind: entry.record.kind, deletedAt: date)
    }

    public func title(_ id: UUID) -> String? { entries[id]?.title }

    public func conflictCopies() -> [Entry] { entries.values.filter { $0.conflictSource != nil } }

    public func titles() -> Set<String> { Set(entries.values.map(\.title)) }

    /// Everything that must match across devices after convergence.
    public func snapshot() -> Set<String> {
        Set(entries.values.map { "\($0.record.id)|\($0.record.revision)|\($0.title)|\($0.body?.base64EncodedString() ?? "-")" })
    }

    public func journaledDeletions() -> [UUID: LocalDeletion] { journal }

    static func body(for title: String) -> Data { Data("Body of \(title)".utf8) }

    // MARK: SyncLocalStore

    public func records() -> [LocalRecord] { entries.values.map(\.record) }

    public func deletions() -> [UUID: LocalDeletion] { journal }

    public func export(_ id: UUID, kind: RecordKind) throws -> RecordPayload {
        if deferredIDs.contains(id) { throw SyncRecordDeferred(reason: "not ready") }
        guard let entry = entries[id], entry.record.kind == kind else { throw StorageError.notFound("local \(id)") }
        let meta = try JSONEncoder().encode(Meta(title: entry.title, conflictSource: entry.conflictSource))
        var body = entry.body
        var format: String?
        if let session, let plain = entry.body {
            let doc = session.current.bodyEncoding == .noteItDocV1
            body = Data((doc ? "DOC:" : "RTFD:").utf8) + plain
            format = doc ? BodyFormat.noteItDocV1 : nil
        }
        if let override = formatOverrides[id] { format = override }
        return RecordPayload(id: id, kind: kind, revision: entry.record.revision, modifiedAt: entry.record.modifiedAt,
                             deviceID: "fake", meta: meta, body: body, bodyFormat: format)
    }

    public func apply(_ payload: RecordPayload) throws {
        if deferredIDs.contains(payload.id) { throw SyncRecordDeferred(reason: "not ready") }
        let meta = try JSONDecoder().decode(Meta.self, from: payload.meta)
        try refuseIfNeeded(meta.title)
        applyCount += 1
        if payload.kind == .note { appliedFormats[payload.id] = .some(payload.bodyFormat) }
        entries[payload.id] = Entry(
            record: LocalRecord(id: payload.id, kind: payload.kind, revision: payload.revision, modifiedAt: payload.modifiedAt),
            title: meta.title, body: payload.body.map(Self.unprefixed), conflictSource: meta.conflictSource
        )
    }

    /// The body without its `RTFD:`/`DOC:` transport prefix.
    static func unprefixed(_ body: Data) -> Data {
        for prefix in ["RTFD:", "DOC:"] where body.starts(with: Data(prefix.utf8)) {
            return body.dropFirst(prefix.utf8.count)
        }
        return body
    }

    public func applyDeletion(_ id: UUID, kind: RecordKind) {
        entries[id] = nil
    }

    public func importConflictCopy(_ payload: RecordPayload, fromDevice name: String) throws {
        let meta = try JSONDecoder().decode(Meta.self, from: payload.meta)
        try refuseIfNeeded(meta.title)
        let id = UUID()
        entries[id] = Entry(
            record: LocalRecord(id: id, kind: payload.kind, revision: UUID(), modifiedAt: Date()),
            title: "\(meta.title) (conflict — \(name))", body: payload.body.map(Self.unprefixed), conflictSource: name
        )
    }

    private func refuseIfNeeded(_ title: String) throws {
        guard refusedTitles.contains(title) else { return }
        refusedCount += 1
        throw SyncRecordRefused(reason: "“\(title)” is too large")
    }

    public func clearDeletion(_ id: UUID) {
        journal[id] = nil
    }
}
