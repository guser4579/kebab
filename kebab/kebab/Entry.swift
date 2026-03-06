import Foundation

struct Entry: Identifiable, Codable, Sendable {
    let id: UUID
    let user_id: UUID
    let parent_id: UUID?
    let root_id: UUID?
    let content: String
    let created_at: Date
    let pinned_at: Date?
}
