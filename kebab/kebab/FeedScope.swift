import Foundation
import Combine
import Supabase

/// Identity of one feed surface. Maps 1:1 onto the get_feed_page contract.
enum FeedScope: Hashable, Identifiable {
    case all
    case parent(UUID)
    case sub(UUID)

    var id: String { cacheKey }

    var collectionId: UUID? {
        switch self {
        case .all: return nil
        case .parent(let id), .sub(let id): return id
        }
    }

    var includeSubs: Bool {
        if case .parent = self { return true }
        return false
    }

    var cacheKey: String {
        switch self {
        case .all: return "feedPage.all"
        case .parent(let id): return "feedPage.parent.\(id.uuidString)"
        case .sub(let id): return "feedPage.sub.\(id.uuidString)"
        }
    }

    init(filter: CollectionFilter?) {
        switch filter {
        case nil: self = .all
        case .all(let parentId): self = .parent(parentId)
        case .single(let id): self = .sub(id)
        }
    }

    /// Membership test for cross-scope reconciliation, using the collection
    /// fields the RPC already joins onto every entry.
    func matches(_ entry: Entry) -> Bool {
        switch self {
        case .all:
            return true
        case .parent(let id):
            return entry.collection_id == id || entry.collection_parent_id == id
        case .sub(let id):
            return entry.collection_id == id
        }
    }
}

/// Session-lived registry of feed stores. Lazily creates a store per scope
/// and keeps every visited scope warm for the foreground session — switching
/// back is instant, with position, unseen count, and pagination state intact.
/// No expiration timers; the lifecycle boundary is the app process (a true
/// cold launch starts fresh from per-scope caches at the live edge).
@MainActor
final class FeedScopeCoordinator: ObservableObject {

    /// Scopes in first-visit order; MainAppView keeps one live feed view per
    /// visited scope so scroll positions survive switching.
    @Published private(set) var visitedScopes: [FeedScope] = []
    private var stores: [FeedScope: FeedStore] = [:]
    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
        // All is the launch surface: seed it synchronously so the first frame
        // renders straight from its cache with no empty-registry flash, and
        // start its silent revalidation immediately (activate() would treat
        // the seeded scope as already visited and skip it).
        visitedScopes = [.all]
        let allStore = FeedStore(supabase: supabase, scope: .all)
        stores[.all] = allStore
        Task { await allStore.revalidateNewest() }
    }

    func store(for scope: FeedScope) -> FeedStore {
        if let existing = stores[scope] { return existing }
        let store = FeedStore(supabase: supabase, scope: scope)
        stores[scope] = store
        return store
    }

    /// Marks a scope active, creating and revalidating its store on first
    /// visit. Returning to a visited scope does no work at all.
    func activate(_ scope: FeedScope) {
        guard !visitedScopes.contains(scope) else { return }
        visitedScopes.append(scope)
        let store = store(for: scope)
        Task { await store.revalidateNewest() }
    }

    /// Newest-page-only prefetch for likely next scopes. Never blocks the
    /// active feed; skips scopes that already have content.
    func prefetch(_ scopes: [FeedScope]) {
        for scope in scopes {
            let store = store(for: scope)
            if store.entries.isEmpty && !store.hasLoadedOnce {
                Task { await store.revalidateNewest() }
            }
        }
    }

    // MARK: - Cross-scope reconciliation (targeted, no reloads)

    /// A promoted outbox entry joins every warm scope it belongs to, obeying
    /// each scope's own live-edge/unseen rule. `heldIn` is the scope whose
    /// user was away at send time (already counted there via holdOwnEntry).
    func fanOutPromoted(_ entry: Entry) {
        for store in stores.values where store.scope.matches(entry) {
            store.adoptPromoted(entry)
        }
    }

    /// Content/membership reconciliation after any mutation: patch where it
    /// still belongs, remove where it no longer does, arrive where it's new.
    func reconcile(_ entry: Entry) {
        for store in stores.values {
            store.reconcile(entry)
        }
    }

    func removeEverywhere(id: UUID) {
        for store in stores.values {
            store.remove(id: id)
        }
    }

    /// Resurface and similar reordering events: revalidate every warm scope
    /// the entry belongs to, so each applies its own arrival rule.
    func revalidateScopes(containing entry: Entry) {
        for store in stores.values where store.scope.matches(entry) {
            Task { await store.revalidateNewest() }
        }
    }

    func revalidateAllWarm() {
        for store in stores.values {
            Task { await store.revalidateNewest() }
        }
    }
}
