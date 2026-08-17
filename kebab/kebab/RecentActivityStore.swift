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

/// One recorded action. Identity belongs to the EVENT, never the entry:
/// several events may target the same root (create, then three comments,
/// then a resurface — five rows). `contextEntryId` is the exact object the
/// user last inhabited — a deeply nested comment reopens that comment.
nonisolated struct RecentActivityItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let rootId: UUID
    var contextEntryId: UUID
    var kind: RecentActivityKind
    var date: Date

    init(id: UUID = UUID(), rootId: UUID, contextEntryId: UUID, kind: RecentActivityKind, date: Date) {
        self.id = id
        self.rootId = rootId
        self.contextEntryId = contextEntryId
        self.kind = kind
        self.date = date
    }

    // Rows persisted before events carried their own identity lack `id`;
    // mint one on decode so existing history survives the migration.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        rootId = try container.decode(UUID.self, forKey: .rootId)
        contextEntryId = try container.decode(UUID.self, forKey: .contextEntryId)
        kind = try container.decode(RecentActivityKind.self, forKey: .kind)
        date = try container.decode(Date.self, forKey: .date)
    }
}

/// Local-only resume stack behind Search's resting state — a chronological
/// event log of qualifying actions, NOT a unique-entry list. Strong signals
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

    /// Appends one event for one action. Never deduplicates by root — all
    /// eight slots pointing at the same thought is valid history. Overflow
    /// drops the oldest event.
    func record(rootId: UUID, contextEntryId: UUID, kind: RecentActivityKind) {
        guard userId != nil else { return }
        var updated = items
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
