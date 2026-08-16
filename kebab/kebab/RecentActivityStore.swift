import Foundation
import Combine

/// The action that most recently touched a thought — drives the quiet cue
/// ("Commented · 2h") and decides nothing else: latest action wins wholesale.
nonisolated enum RecentActivityKind: String, Codable, Sendable {
    case created
    case commented
    case edited
    case resurfaced
    case viewed

    var label: String {
        switch self {
        case .created: return "Created"
        case .commented: return "Commented"
        case .edited: return "Edited"
        case .resurfaced: return "Resurfaced"
        case .viewed: return "Viewed"
        }
    }
}

/// One resumable thought context. `contextEntryId` is the exact object the
/// user last inhabited — a deeply nested comment reopens that comment.
nonisolated struct RecentActivityItem: Codable, Identifiable, Equatable, Sendable {
    let rootId: UUID
    var contextEntryId: UUID
    var kind: RecentActivityKind
    var date: Date

    var id: UUID { rootId }
}

/// Local-only resume stack behind Search's resting state. Strong signals
/// (create / comment / edit / resurface) and deliberate opens are recorded at
/// their call sites; passive feed exposure never reaches this store.
@MainActor
final class RecentActivityStore: ObservableObject {

    @Published private(set) var items: [RecentActivityItem] = []

    private static let maxItems = 8
    private var userId: UUID?
    private var storageKey: String {
        "recentActivity_\(userId?.uuidString ?? "anonymous")"
    }

    func configure(userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        items = LocalStore.load([RecentActivityItem].self, from: storageKey) ?? []
    }

    /// Records an action on a thought. Deduplicates by root — one thought,
    /// one slot — with the latest action defining both cue and context.
    func record(rootId: UUID, contextEntryId: UUID, kind: RecentActivityKind) {
        guard userId != nil else { return }
        var updated = items.filter { $0.rootId != rootId }
        updated.insert(
            RecentActivityItem(rootId: rootId, contextEntryId: contextEntryId, kind: kind, date: Date()),
            at: 0
        )
        if updated.count > Self.maxItems {
            updated = Array(updated.prefix(Self.maxItems))
        }
        items = updated
        LocalStore.save(items, as: storageKey)
    }

    /// Drops items whose root no longer exists (deleted thoughts).
    func prune(existingRoot: (UUID) -> Bool) {
        let pruned = items.filter { existingRoot($0.rootId) }
        guard pruned.count != items.count else { return }
        items = pruned
        LocalStore.save(items, as: storageKey)
    }

    func clear() {
        items = []
        LocalStore.save(items, as: storageKey)
    }
}
