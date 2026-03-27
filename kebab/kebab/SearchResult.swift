import Foundation

/// Dedicated result type for the `search_entries_v2` RPC.
/// Kept separate from `Entry` so that search-specific fields (e.g. `parent_preview`)
/// never pollute the core model used by feed, thread, and detail surfaces.
struct SearchResult: Identifiable, Codable, Sendable {

    let id: UUID
    let user_id: UUID
    let parent_id: UUID?
    let root_id: UUID?
    let depth: Int
    let content: String
    let created_at: Date
    let pinned_at: Date?
    let isContentHidden: Bool
    let comment_count: Int?
    let attachments: [EntryAttachment]?
    let resurface_count: Int
    let fire_count: Int
    /// Populated by the backend only for comment results; nil for root results.
    let parent_preview: String?
    let collection_id: UUID?
    let collection_name: String?
    let collection_parent_id: UUID?
    let collection_parent_name: String?

    /// True when this result represents a comment (has a parent).
    var isComment: Bool { parent_id != nil }

    /// Convenience accessor matching the pattern in `Entry`.
    var linkAttachment: EntryAttachment? {
        attachments?.first { $0.attachmentType == .link }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case user_id
        case parent_id
        case root_id
        case depth
        case content
        case created_at
        case pinned_at
        case isContentHidden = "is_content_hidden"
        case comment_count
        case attachments
        case resurface_count
        case fire_count
        case parent_preview
        case collection_id
        case collection_name
        case collection_parent_id
        case collection_parent_name
    }
}

extension SearchResult {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(UUID.self,   forKey: .id)
        user_id          = try c.decode(UUID.self,   forKey: .user_id)
        parent_id        = try c.decodeIfPresent(UUID.self,   forKey: .parent_id)
        root_id          = try c.decodeIfPresent(UUID.self,   forKey: .root_id)
        depth            = try c.decodeIfPresent(Int.self,    forKey: .depth)  ?? 0
        content          = try c.decode(String.self, forKey: .content)
        created_at       = try c.decode(Date.self,   forKey: .created_at)
        pinned_at        = try c.decodeIfPresent(Date.self,   forKey: .pinned_at)
        isContentHidden  = try c.decode(Bool.self,   forKey: .isContentHidden)
        comment_count    = try c.decodeIfPresent(Int.self,    forKey: .comment_count)
        attachments      = try c.decodeIfPresent([EntryAttachment].self, forKey: .attachments)
        resurface_count      = try c.decodeIfPresent(Int.self,    forKey: .resurface_count)      ?? 0
        fire_count           = try c.decodeIfPresent(Int.self,    forKey: .fire_count)           ?? 0
        parent_preview       = try c.decodeIfPresent(String.self, forKey: .parent_preview)
        collection_id        = try c.decodeIfPresent(UUID.self,   forKey: .collection_id)
        collection_name      = try c.decodeIfPresent(String.self, forKey: .collection_name)
        collection_parent_id = try c.decodeIfPresent(UUID.self,   forKey: .collection_parent_id)
        collection_parent_name = try c.decodeIfPresent(String.self, forKey: .collection_parent_name)
    }
}

// MARK: - Bridge to Entry

extension SearchResult {
    /// Converts this search result to a plain `Entry` suitable for passing to
    /// `EntryDetailView` or `CommentDetailView`. The search-only `parent_preview`
    /// field is dropped — detail views re-fetch their own data on appear.
    func toEntry() -> Entry {
        Entry(
            id: id,
            user_id: user_id,
            parent_id: parent_id,
            root_id: root_id,
            depth: depth,
            content: content,
            created_at: created_at,
            pinned_at: pinned_at,
            isContentHidden: isContentHidden,
            comment_count: comment_count,
            resurface_count: resurface_count,
            fire_count: fire_count,
            attachments: attachments,
            collection_id: collection_id,
            collection_name: collection_name,
            collection_parent_id: collection_parent_id,
            collection_parent_name: collection_parent_name
        )
    }
}
