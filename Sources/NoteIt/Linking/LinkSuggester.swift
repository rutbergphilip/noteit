import Foundation

struct LinkCandidate: Sendable {
    var id: UUID
    var title: String
    var notebookName: String
    var updatedAt: Date
}
