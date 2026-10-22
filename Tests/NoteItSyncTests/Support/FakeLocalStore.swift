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

    public init() {}

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
        guard let entry = entries[id], entry.record.kind == kind else { throw StorageError.notFound("local \(id)") }
        let meta = try JSONEncoder().encode(Meta(title: entry.title, conflictSource: entry.conflictSource))
        return RecordPayload(id: id, kind: kind, revision: entry.record.revision, modifiedAt: entry.record.modifiedAt,
                             deviceID: "fake", meta: meta, body: entry.body)
    }

    public func apply(_ payload: RecordPayload) throws {
        let meta = try JSONDecoder().decode(Meta.self, from: payload.meta)
        try refuseIfNeeded(meta.title)
        applyCount += 1
        entries[payload.id] = Entry(
            record: LocalRecord(id: payload.id, kind: payload.kind, revision: payload.revision, modifiedAt: payload.modifiedAt),
            title: meta.title, body: payload.body, conflictSource: meta.conflictSource
        )
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
            title: "\(meta.title) (conflict — \(name))", body: payload.body, conflictSource: name
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
