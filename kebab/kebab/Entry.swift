import Foundation

nonisolated struct EntryAttachment: Codable, Sendable, Equatable {
    let type: String
    let url: String
    let title: String?
    let favicon_url: String?
    let image_url: String?

    enum AttachmentType: String {
        case link
        case image
    }

    var attachmentType: AttachmentType? {
        AttachmentType(rawValue: type)
    }
}

nonisolated struct Entry: Identifiable, Sendable, Equatable {
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
    let resurface_count: Int
    let fire_count: Int
    let attachments: [EntryAttachment]?
    let collection_id: UUID?
    let collection_name: String?
    let collection_parent_id: UUID?
    let collection_parent_name: String?
    /// True for entries still in the local outbox (composed offline, not yet
    /// synced). Display-only — never encoded or sent to the server.
    var isPending: Bool = false
    /// True when the outbox gave up after repeated server rejections; shows
    /// the tappable warning glyph.
    var pendingFailed: Bool = false

    var linkAttachment: EntryAttachment? {
        attachments?.first { $0.attachmentType == .link }
    }

    var imageAttachments: [EntryAttachment] {
        attachments?.filter { $0.attachmentType == .image } ?? []
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
        case resurface_count
        case fire_count
        case attachments
        case collection_id
        case collection_name
        case collection_parent_id
        case collection_parent_name
    }
}

nonisolated extension Entry: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        user_id = try c.decode(UUID.self, forKey: .user_id)
        parent_id = try c.decodeIfPresent(UUID.self, forKey: .parent_id)
        root_id = try c.decodeIfPresent(UUID.self, forKey: .root_id)
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        content = try c.decode(String.self, forKey: .content)
        created_at = try c.decode(Date.self, forKey: .created_at)
        pinned_at = try c.decodeIfPresent(Date.self, forKey: .pinned_at)
        isContentHidden = try c.decode(Bool.self, forKey: .isContentHidden)
        comment_count = try c.decodeIfPresent(Int.self, forKey: .comment_count)
        resurface_count = try c.decodeIfPresent(Int.self, forKey: .resurface_count) ?? 0
        fire_count = try c.decodeIfPresent(Int.self, forKey: .fire_count) ?? 0
        attachments = try c.decodeIfPresent([EntryAttachment].self, forKey: .attachments)
        collection_id = try c.decodeIfPresent(UUID.self, forKey: .collection_id)
        collection_name = try c.decodeIfPresent(String.self, forKey: .collection_name)
        collection_parent_id = try c.decodeIfPresent(UUID.self, forKey: .collection_parent_id)
        collection_parent_name = try c.decodeIfPresent(String.self, forKey: .collection_parent_name)
    }
}

extension Entry {
    func withContent(_ newContent: String) -> Entry {
        Entry(
            id: id,
            user_id: user_id,
            parent_id: parent_id,
            root_id: root_id,
            depth: depth,
            content: newContent,
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

    func withAttachments(_ newAttachments: [EntryAttachment]?) -> Entry {
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
            attachments: newAttachments,
            collection_id: collection_id,
            collection_name: collection_name,
            collection_parent_id: collection_parent_id,
            collection_parent_name: collection_parent_name
        )
    }

    func withIsContentHidden(_ hidden: Bool) -> Entry {
        Entry(
            id: id,
            user_id: user_id,
            parent_id: parent_id,
            root_id: root_id,
            depth: depth,
            content: content,
            created_at: created_at,
            pinned_at: pinned_at,
            isContentHidden: hidden,
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

    func withCommentCount(_ count: Int?) -> Entry {
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
            comment_count: count,
            resurface_count: resurface_count,
            fire_count: fire_count,
            attachments: attachments,
            collection_id: collection_id,
            collection_name: collection_name,
            collection_parent_id: collection_parent_id,
            collection_parent_name: collection_parent_name
        )
    }

    func withResurfaceCount(_ count: Int) -> Entry {
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
            resurface_count: count,
            fire_count: fire_count,
            attachments: attachments,
            collection_id: collection_id,
            collection_name: collection_name,
            collection_parent_id: collection_parent_id,
            collection_parent_name: collection_parent_name
        )
    }

    func withCollection(
        id newCollectionId: UUID?,
        name newCollectionName: String?,
        parentId newParentId: UUID?,
        parentName newParentName: String?
    ) -> Entry {
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
            collection_id: newCollectionId,
            collection_name: newCollectionName,
            collection_parent_id: newParentId,
            collection_parent_name: newParentName
        )
    }

    func withFireCount(_ count: Int) -> Entry {
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
            fire_count: count,
            attachments: attachments,
            collection_id: collection_id,
            collection_name: collection_name,
            collection_parent_id: collection_parent_id,
            collection_parent_name: collection_parent_name
        )
    }
}
