import Foundation
import Combine
import Supabase

/// One row from `get_feed_page`. Wraps the standard Entry plus the row's
/// cursor value kept as the VERBATIM server string — the keyset cursor
/// carries microseconds, and a round-trip through a Date formatter would
/// corrupt it.
nonisolated struct FeedPageRow: Decodable {
    let entry: Entry
    let feedOrderAtRaw: String

    private enum RawKeys: String, CodingKey { case feed_order_at }

    init(from decoder: Decoder) throws {
        entry = try Entry(from: decoder)
        let c = try decoder.container(keyedBy: RawKeys.self)
        feedOrderAtRaw = try c.decode(String.self, forKey: .feed_order_at)
    }
}

private nonisolated struct FeedPageParams: Encodable, Sendable {
    let p_collection_id: UUID?
    let p_include_subs: Bool
    let p_limit: Int
    let p_before_order_at: String?
    let p_before_id: UUID?
}

/// Paged, stale-while-revalidate store for ONE feed scope (All, a parent
/// aggregate, or a sub-collection). Owns the canonical
/// newest-first entry array, keyset pagination into history, ID-based merge
/// reconciliation, and the pending-arrival buffer that backs the unseen-entry
/// FAB state. Knows nothing about inverted coordinates — it reasons only in
/// product terms: newest, older, live edge, arrivals.
@MainActor
final class FeedStore: ObservableObject {

    /// Loaded server entries, newest first. Never wholesale-replaced after
    /// first render — every update is an ID-based merge or append.
    @Published private(set) var entries: [Entry] = []
    /// Arrivals held while the user is away from the live edge. Not rendered
    /// until the user returns; their count drives the FAB label.
    @Published private(set) var unseenCount: Int = 0
    /// True while the newest loaded entry is (or should be) on screen.
    /// Written by the scroll container; read by send/arrival logic.
    @Published var isAtLiveEdge: Bool = true
    @Published private(set) var hasLoadedOnce: Bool = false
    @Published private(set) var isLoadingOlder: Bool = false

    private(set) var hasMoreHistory: Bool = true
    private var pendingArrivals: [Entry] = []          // newest-first buffer
    /// Outbox entry ids created while away — excluded from display until the
    /// user returns to the live edge (their creation still happens normally).
    private(set) var heldPendingIds: Set<UUID> = []

    private var loadedIds: Set<UUID> = []
    /// Cursor of the oldest loaded row: verbatim (feed_order_at, id).
    private var oldestCursor: (raw: String, id: UUID)?
    private var isRevalidating = false

    let scope: FeedScope
    var initialPageSize: Int { scope == .all ? 75 : 50 }
    static let olderPageSize = 50
    private var cacheKey: String { scope.cacheKey }

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient, scope: FeedScope) {
        self.supabase = supabase
        self.scope = scope
        // SWR: open instantly on the cached newest page.
        if let cached = LocalStore.load([Entry].self, from: cacheKey), !cached.isEmpty {
            entries = cached
            loadedIds = Set(cached.map(\.id))
            hasLoadedOnce = true
            // Cache holds only the newest page — cursors come from the network.
            hasMoreHistory = true
        }
    }

    // MARK: - Fetching

    private func fetchPage(limit: Int, before: (raw: String, id: UUID)?) async throws -> [FeedPageRow] {
        let rows: [FeedPageRow] = try await supabase
            .rpc("get_feed_page", params: FeedPageParams(
                p_collection_id: scope.collectionId,
                p_include_subs: scope.includeSubs,
                p_limit: limit,
                p_before_order_at: before?.raw,
                p_before_id: before?.id
            ))
            .execute()
            .value
        return rows
    }

    /// Silent newest-page revalidation: never replaces the array, never shows
    /// loading UI. New ids flow in at the live edge or into the arrival
    /// buffer; known ids are patched in place; resurfaced ids become
    /// move-to-live-edge events.
    func revalidateNewest() async {
        guard !isRevalidating else { return }
        isRevalidating = true
        defer { isRevalidating = false }

        do {
            let rows = try await fetchPage(limit: initialPageSize, before: nil)
            defer { hasLoadedOnce = true }
            guard !rows.isEmpty else {
                if entries.isEmpty { hasMoreHistory = false }
                saveCache()
                return
            }

            // First-ever load with no cache: adopt directly (nothing rendered yet).
            if entries.isEmpty {
                entries = rows.map(\.entry)
                loadedIds = Set(entries.map(\.id))
                oldestCursor = rows.last.map { ($0.feedOrderAtRaw, $0.entry.id) }
                hasMoreHistory = rows.count == initialPageSize
                saveCache()
                return
            }

            mergeNewestPage(rows)
        } catch {
            // Silent: cached/loaded content remains authoritative offline.
        }
    }


    /// Inserts arrivals at the live edge (index 0 side of newest-first),
    /// removing any older copies of moved ids.
    private func integrate(arrivals: [Entry]) {
        let ids = Set(arrivals.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        entries.insert(contentsOf: arrivals, at: 0)
        loadedIds.formUnion(ids)
    }

    /// Loads the next older page and appends it. Absence of a previously
    /// loaded id from an older page is NOT deletion — rows are only ever
    /// added or patched here.
    func loadOlderIfNeeded() async {
        guard hasMoreHistory, !isLoadingOlder, !entries.isEmpty else { return }
        // The first network page establishes the cursor when we started from cache.
        if oldestCursor == nil && hasLoadedOnce && isRevalidating { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            let cursor: (raw: String, id: UUID)
            if let existing = oldestCursor {
                cursor = existing
            } else {
                // Started from cache: fetch newest page once to obtain cursors.
                let rows = try await fetchPage(limit: initialPageSize, before: nil)
                mergeNewestPage(rows)
                guard let last = rows.last else { hasMoreHistory = false; return }
                oldestCursor = (last.feedOrderAtRaw, last.entry.id)
                hasMoreHistory = rows.count == initialPageSize
                guard hasMoreHistory else { return }
                cursor = oldestCursor!
            }

            let rows = try await fetchPage(limit: Self.olderPageSize, before: cursor)
            if let last = rows.last {
                oldestCursor = (last.feedOrderAtRaw, last.entry.id)
            }
            hasMoreHistory = rows.count == Self.olderPageSize
            let newOnes = rows.map(\.entry).filter { !loadedIds.contains($0.id) }
            guard !newOnes.isEmpty else { return }
            entries.append(contentsOf: newOnes)
            loadedIds.formUnion(newOnes.map(\.id))
        } catch {
            // Retry happens on the next boundary approach.
        }
    }

    /// Patches known ids from a page without reordering (used when re-fetching
    /// the newest page purely to establish cursors).
    /// Newest-page merge with two modes:
    ///
    /// AT THE LIVE EDGE the page is authoritative for its window: rows are
    /// re-laid in exact server order (arrivals, moves, and drift all settle
    /// visibly at the edge, which is where the user is looking anyway).
    ///
    /// AWAY FROM THE EDGE the merge is conservative: known rows are patched
    /// in place, unknown rows within the window are spliced silently as
    /// backfill, and anything ranked above our local newest — new entries OR
    /// moved (resurfaced) known rows — is buffered as an unseen arrival.
    /// Nothing already rendered changes position under the user.
    private func mergeNewestPage(_ rows: [FeedPageRow]) {
        if isAtLiveEdge {
            var window: [Entry] = []
            for row in rows {
                if let idx = pendingArrivals.firstIndex(where: { $0.id == row.entry.id }) {
                    pendingArrivals.remove(at: idx)
                }
                window.append(row.entry)
            }
            let windowIds = Set(window.map(\.id))
            let firstWindowIdx = entries.firstIndex { windowIds.contains($0.id) } ?? entries.count
            var racingFront: [Entry] = []
            var demoted: [Entry] = []
            for (idx, entry) in entries.enumerated() where !windowIds.contains(entry.id) && idx < firstWindowIdx {
                // Local rows above the window: keep just-promoted own sends
                // racing replication; demote stale misplacements below it.
                if Date().timeIntervalSince(entry.created_at) < 300 {
                    racingFront.append(entry)
                } else {
                    demoted.append(entry)
                }
            }
            let olderTail = entries.filter { entry in
                !windowIds.contains(entry.id)
                    && !racingFront.contains(where: { $0.id == entry.id })
                    && !demoted.contains(where: { $0.id == entry.id })
            }
            entries = racingFront + window + demoted + olderTail
            loadedIds.formUnion(windowIds)
        } else {
            let localNewestId = entries.first?.id
            var reachedLocalNewest = false
            var lastKnownLocalIdx: Int? = nil
            var arrivals: [Entry] = []

            for row in rows {
                let e = row.entry
                if e.id == localNewestId { reachedLocalNewest = true }
                let localIdx = entries.firstIndex { $0.id == e.id }

                if !reachedLocalNewest {
                    // Ranked above everything the user currently sees: a new
                    // entry or a moved known row — buffer either way. The
                    // moved row's old copy stays rendered; reveal dedupes.
                    if let idx = pendingArrivals.firstIndex(where: { $0.id == e.id }) {
                        pendingArrivals[idx] = e
                    } else if localIdx == nil || localIdx! > 0 {
                        arrivals.append(e)
                    }
                } else if let idx = localIdx {
                    entries[idx] = e
                    lastKnownLocalIdx = idx
                } else if let anchor = lastKnownLocalIdx {
                    entries.insert(e, at: anchor + 1)   // silent backfill
                    loadedIds.insert(e.id)
                    lastKnownLocalIdx = anchor + 1
                }
            }

            if !arrivals.isEmpty {
                pendingArrivals = (arrivals + pendingArrivals).uniqued(by: \.id)
                unseenCount = pendingArrivals.count
            }
        }
        saveCache()
    }

    // MARK: - Live-edge transitions

    /// The user reached the live edge (manually or via the FAB): reveal
    /// buffered arrivals and clear the unseen state.
    func didReachLiveEdge() {
        isAtLiveEdge = true
        heldPendingIds.removeAll()
        guard !pendingArrivals.isEmpty else { unseenCount = 0; return }
        // Buffer is newest-first; prepending preserves server order without
        // any re-sort (a sort by created_at would wrongly demote resurfaced
        // entries, whose rank comes from feed_order_at).
        integrate(arrivals: pendingArrivals)
        pendingArrivals.removeAll()
        unseenCount = 0
        saveCache()
    }

    func didLeaveLiveEdge() {
        isAtLiveEdge = false
    }

    // MARK: - Own entries (outbox integration)

    /// A locally composed entry was queued while away from the live edge:
    /// hold it out of the rendered list and count it as unseen.
    func holdOwnEntry(id: UUID) {
        heldPendingIds.insert(id)
        unseenCount += 1
    }

    /// The outbox promoted a pending entry into a server row. Follows this
    /// scope's own live-edge rule (each scope has independent unseen state).
    func adoptPromoted(_ entry: Entry) {
        guard !loadedIds.contains(entry.id) else { return }
        if heldPendingIds.contains(entry.id) {
            // Still unseen: buffer it; count was already incremented on hold.
            heldPendingIds.remove(entry.id)
            pendingArrivals.insert(entry, at: 0)
        } else if isAtLiveEdge {
            entries.insert(entry, at: 0)
            loadedIds.insert(entry.id)
            saveCache()
        } else {
            pendingArrivals.insert(entry, at: 0)
            unseenCount = pendingArrivals.count
        }
    }

    /// Membership-aware reconciliation after a mutation: patch if it still
    /// belongs here, remove if it left this scope, arrive if it just joined.
    func reconcile(_ entry: Entry) {
        let belongs = scope.matches(entry)
        let known = loadedIds.contains(entry.id)
            || pendingArrivals.contains(where: { $0.id == entry.id })
        if known && belongs {
            patch(entry)
            if let idx = pendingArrivals.firstIndex(where: { $0.id == entry.id }) {
                pendingArrivals[idx] = entry
            }
            saveCache()
        } else if known && !belongs {
            remove(id: entry.id)
        } else if !known && belongs {
            adoptPromoted(entry)
        }
    }

    // MARK: - Targeted mutations (no whole-array replacement)

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        if pendingArrivals.contains(where: { $0.id == id }) {
            pendingArrivals.removeAll { $0.id == id }
            unseenCount = pendingArrivals.count
        }
        loadedIds.remove(id)
        saveCache()
    }

    func patch(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        }
    }

    /// Resurface performed locally: the entry moves to the live edge.
    func noteLocalResurface(id: UUID) async {
        await revalidateNewest()
    }

    private func saveCache() {
        LocalStore.save(Array(entries.prefix(initialPageSize)), as: cacheKey)
    }
}

private extension Array where Element == Entry {
    func uniqued(by key: (Element) -> UUID) -> [Entry] {
        var seen = Set<UUID>()
        return filter { seen.insert(key($0)).inserted }
    }
}
