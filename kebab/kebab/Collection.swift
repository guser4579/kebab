import Foundation

struct Collection: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    let updatedAt: Date
    let itemCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case updatedAt = "updated_at"
        case itemCount = "item_count"
    }
}
