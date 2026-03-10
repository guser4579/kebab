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

struct Entry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let user_id: UUID
    let parent_id: UUID?
    let root_id: UUID?
    let content: String
    let created_at: Date
    let pinned_at: Date?
    let isContentHidden: Bool
    let comment_count: Int?
    let attachments: [EntryAttachment]?

    var linkAttachment: EntryAttachment? {
        attachments?.first { $0.attachmentType == .link }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case user_id
        case parent_id
        case root_id
        case content
        case created_at
        case pinned_at
        case isContentHidden = "is_content_hidden"
        case comment_count
        case attachments
    }
}
