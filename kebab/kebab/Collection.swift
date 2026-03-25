import Foundation

struct Collection: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    /// Non-nil when this collection is a sub-collection; the value is the parent's UUID.
    let parentId: UUID?
    let updatedAt: Date
    /// Total items = root entries directly in this collection + all their descendant comments.
    /// For parent collections this also includes items inside child sub-collections.
    let itemCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentId = "parent_id"
        case updatedAt = "updated_at"
        case itemCount = "item_count"
    }
}
