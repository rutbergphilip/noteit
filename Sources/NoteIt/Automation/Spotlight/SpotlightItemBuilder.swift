import CoreSpotlight
import Foundation
import NoteItCore
import UniformTypeIdentifiers

/// One note as Spotlight sees it; turned into a `CSSearchableItem` only when it is handed to Core Spotlight.
struct SpotlightItem: Equatable, Sendable {
    var id: String
    var domain: String
    var title: String
    var contentDescription: String
    var textContent: String?
    var keywords: [String]
    var created: Date
    var modified: Date
}

enum SpotlightItemBuilder {
    static let maxTextCharacters = 20_000
    static let noNotebookDomain = "none"

    static func shouldIndex(_ meta: NoteMeta) -> Bool {
        meta.deletedAt == nil && !meta.isLocked
    }

    static func item(for meta: NoteMeta, text: String?, includeText: Bool) -> SpotlightItem {
        SpotlightItem(id: meta.id.uuidString,
                      domain: meta.notebookID?.uuidString ?? noNotebookDomain,
                      title: meta.displayTitle,
                      contentDescription: meta.preview,
                      textContent: includeText ? text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTextCharacters)) } : nil,
                      keywords: meta.tags,
                      created: meta.createdAt,
                      modified: meta.updatedAt)
    }

    static func searchableItem(_ item: SpotlightItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = item.title
        attributes.contentDescription = item.contentDescription
        attributes.textContent = item.textContent
        attributes.keywords = item.keywords
        attributes.contentCreationDate = item.created
        attributes.contentModificationDate = item.modified
        return CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: item.domain, attributeSet: attributes)
    }
}
