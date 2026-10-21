import AppKit
import Foundation
import NoteItCore

enum LinkResolution: Equatable {
    case note(UUID, heading: String?)
    case unresolved(title: String)
    case deleted(UUID)
    case missing(UUID)
}

struct Backlink: Identifiable {
    var id: UUID { source }
    var source: UUID
    var occurrences: [OutgoingLink]
}

extension NoteStore {
    /// The link index registered with the derived-index registry; installed on first use.
    var linkIndex: LinkIndex {
        if let index = derivedIndexes.first(where: { $0.indexID == "links" }) as? LinkIndex { return index }
        return installLinkIndex()
    }

    /// Registers the link index, starts reading `link-index.json`, then rebuilds so entries the file lacks are
    /// extracted (the store's own load-time rebuild ran before the index existed).
    @discardableResult
    func installLinkIndex() -> LinkIndex {
        if let index = derivedIndexes.first(where: { $0.indexID == "links" }) as? LinkIndex { return index }
        let index = LinkIndex()
        index.store = self
        index.fileURL = rootURL.appendingPathComponent(LinkIndex.fileName)
        registerDerivedIndex(index)
        index.startLoading(store: self)
        index.observeTermination()
        rebuildDerivedIndexes()
        return index
    }

    // MARK: Resolution

    func resolve(_ link: NoteLink, from source: UUID?) -> LinkResolution {
        switch link {
        case .note(let id, let heading):
            guard let meta = note(with: id) else { return .missing(id) }
            if meta.deletedAt != nil { return .deleted(id) }
            return .note(id, heading: heading)
        case .unresolved(let title, let heading):
            let preferred = note(with: source)?.notebookID
            if let id = noteID(forTitle: title, preferring: preferred) { return .note(id, heading: heading) }
            return .unresolved(title: title)
        }
    }

    /// The live note with this title (folded): the one in `notebookID` first, else the most recently edited.
    func noteID(forTitle title: String, preferring notebookID: UUID?) -> UUID? {
        let key = TextFold.fold(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty, let ids = linkIndex.titleIndex(for: self)[key], !ids.isEmpty else { return nil }
        let metas = ids.compactMap { note(with: $0) }
        if let notebookID, let same = metas.filter({ $0.notebookID == notebookID }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return same.id
        }
        return metas.max(by: { $0.updatedAt < $1.updatedAt })?.id
    }

    func linkCandidates(excluding id: UUID?) -> [LinkCandidate] {
        let names = Dictionary(notebooks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let templates = templatesNotebookIDIfSet
        return notes.compactMap { meta in
            guard meta.deletedAt == nil, meta.id != id,
                  !meta.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  templates == nil || meta.notebookID != templates else { return nil }
            return LinkCandidate(id: meta.id, title: meta.title,
                                 notebookName: meta.notebookID.flatMap { names[$0] } ?? "",
                                 updatedAt: meta.updatedAt)
        }
    }

    // MARK: Queries

    func outgoingLinks(from id: UUID) -> [OutgoingLink] {
        guard let meta = note(with: id), !meta.isLocked else { return [] }
        return linkIndex.outgoing(from: id)
    }

    /// Live sources linking to `id`, newest first; self-links are left to `outgoingLinks`.
    func backlinks(to id: UUID) -> [Backlink] {
        guard let target = note(with: id) else { return [] }
        let templates = templatesNotebookIDIfSet
        var result: [(Backlink, Date)] = []
        for source in linkIndex.sources(linkingTo: id, title: target.title) where source != id {
            guard let meta = note(with: source), meta.deletedAt == nil, !meta.isLocked,
                  templates == nil || meta.notebookID != templates else { continue }
            let occurrences = linkIndex.outgoing(from: source).filter { item in
                guard let link = item.link else { return false }
                if case .note(let resolved, _) = resolve(link, from: source) { return resolved == id }
                return false
            }
            guard !occurrences.isEmpty else { continue }
            result.append((Backlink(source: source, occurrences: occurrences), meta.updatedAt))
        }
        return result.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The templates notebook when one is known; templates stay out of suggestions and backlinks.
    var templatesNotebookIDIfSet: UUID? { nil }
}
