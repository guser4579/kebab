import Foundation

struct EntryAttachment: Codable, Sendable, Equatable {
    let type: String
    let url: String
    let title: String?
    let favicon_url: String?

    enum AttachmentType: String {
        case link
        case image
    }

    var attachmentType: AttachmentType? {
        AttachmentType(rawValue: type)
    }
}

struct Entry: Identifiable, Sendable, Equatable {
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
    let attachments: [EntryAttachment]?

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
        case resurface_count
        case attachments
    }
}

extension Entry: Codable {
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
        attachments = try c.decodeIfPresent([EntryAttachment].self, forKey: .attachments)
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
            attachments: attachments
        )
    }
}
