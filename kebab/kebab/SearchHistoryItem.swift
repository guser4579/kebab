import Foundation

struct SearchHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let query: String
    let resultCount: Int
    let searchedAt: Date
}
