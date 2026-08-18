import Foundation

extension String {
    /// Shared display rule for collection and sub-collection names in
    /// constrained UI (picker rows, sheet headers, breadcrumbs): at most 24
    /// characters, tail-ellipsized. Presentation only — stored names are
    /// never mutated, and editing flows always expose the full value.
    var collectionDisplayName: String {
        count <= 24 ? self : String(prefix(24)) + "…"
    }

    /// Tighter rule for the most compact navigation surfaces — collection
    /// tabs and collection/sub-collection pills — where several names share
    /// one horizontal row: at most 14 characters, tail-ellipsized. Other
    /// contexts keep `collectionDisplayName`; empty states show the full
    /// name and the composer placeholder ellipsizes by width.
    var collectionCompactDisplayName: String {
        count <= 14 ? self : String(prefix(14)) + "…"
    }
}

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
