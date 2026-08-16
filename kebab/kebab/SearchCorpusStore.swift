import Foundation
import Combine
import Supabase

/// App-lived local mirror of the user's full committed corpus (roots +
/// comments + collection memberships) — the durable retrieval layer Search
/// runs on. Serves the cached snapshot instantly (offline included) and
/// revalidates quietly whenever Search is looking; mutations mark it stale
/// through the same hooks the warm feed stores already use.
@MainActor
final class SearchCorpusStore: ObservableObject {

    /// Bumped after every engine index update; the search workspace
    /// re-evaluates the active query when it changes.
    @Published private(set) var revision: Int = 0

    let engine = SearchEngine()

    private(set) var entries: [Entry] = []
    private(set) var membership: [UUID: UUID] = [:]
    private var entryById: [UUID: Entry] = [:]

    /// Committed-but-unsynced outbox entries; they are real content the user
    /// finished, so they are searchable immediately. Set by MainAppView.
    var pendingProvider: (() -> [Entry])?
    /// Collection id → name, resolved from the warm collections model.
    var collectionNamesProvider: (() -> [UUID: String])?

    private let supabase: SupabaseClient
    private var userId: UUID?
    private var isStale = true
    private var isRefreshing = false
    private var lastRefreshAt: Date?
    /// Quiet revalidation cadence when nothing marked the corpus stale.
    private static let refreshInterval: TimeInterval = 300

    private nonisolated struct DiskSnapshot: Codable {
        let entries: [Entry]
        let membership: [UUID: UUID]
    }

    private var cacheKey: String {
        "searchCorpus_\(userId?.uuidString ?? "anonymous")"
    }

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func configure(userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        if let cached = LocalStore.load(DiskSnapshot.self, from: cacheKey) {
            adopt(entries: cached.entries, membership: cached.membership, persist: false)
        }
        isStale = true
    }

    // MARK: - Staleness

    /// Something changed (comment sent, entry moved, edit landed elsewhere):
    /// the next refresh opportunity refetches.
    func markStale() {
        isStale = true
    }

    /// Refreshes when stale or quietly overdue. Serves current truth for
    /// Search — called whenever the Search surface (re)appears.
    func refreshIfNeeded() async {
        guard userId != nil, !isRefreshing else { return }
        let overdue = lastRefreshAt.map {
            Date().timeIntervalSince($0) > Self.refreshInterval
        } ?? true
        guard isStale || overdue else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let fetchedEntries: [Entry] = supabase
                .from("entries")
                .select("id,user_id,parent_id,root_id,depth,content,created_at,pinned_at,is_content_hidden,resurface_count,fire_count,attachments")
                .order("created_at", ascending: false)
                .execute()
                .value
            async let fetchedMemberships: [MembershipRow] = supabase
                .from("collection_entries")
                .select("entry_id,collection_id")
                .execute()
                .value

            let (freshEntries, memberships) = try await (fetchedEntries, fetchedMemberships)
            let membershipMap = Dictionary(
                memberships.map { ($0.entry_id, $0.collection_id) },
                uniquingKeysWith: { first, _ in first }
            )
            adopt(entries: freshEntries, membership: membershipMap, persist: true)
            isStale = false
            lastRefreshAt = Date()
        } catch {
            // Offline or failed refresh: the cached corpus stays authoritative.
        }
    }

    // MARK: - Immediate local truth

    /// A confirmed delete: the thought (or comment subtree) leaves the corpus
    /// now, without waiting for a refetch.
    func removeEntry(id: UUID) {
        guard entryById[id] != nil else { return }
        var doomed: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for entry in entries {
                if let parent = entry.parent_id,
                   doomed.contains(parent), !doomed.contains(entry.id) {
                    doomed.insert(entry.id)
                    changed = true
                }
            }
        }
        adopt(
            entries: entries.filter { !doomed.contains($0.id) },
            membership: membership.filter { !doomed.contains($0.key) },
            persist: true
        )
        markStale()
    }

    /// An in-place patch or a newly promoted row, already reflected in the
    /// feed model: mirror it without a refetch.
    func upsert(_ entry: Entry) {
        if entryById[entry.id] != nil {
            adopt(
                entries: entries.map { $0.id == entry.id ? entry : $0 },
                membership: membership,
                persist: true
            )
        } else {
            adopt(entries: [entry] + entries, membership: membership, persist: true)
        }
    }

    /// Pending outbox content changed (created or discarded): rebuild the
    /// index from the current mirror + pending, no network involved.
    func rebuildIndex() {
        pushToEngine()
    }

    // MARK: - Lookups (exact-context restoration)

    func entry(id: UUID) -> Entry? {
        entryById[id]
    }

    func rootEntry(of id: UUID) -> Entry? {
        guard let entry = entryById[id] else { return nil }
        guard let rootId = entry.root_id, entry.parent_id != nil else { return entry }
        return entryById[rootId]
    }

    func containsRoot(_ id: UUID) -> Bool {
        if let entry = entryById[id] { return entry.parent_id == nil }
        return false
    }

    // MARK: - Internals

    private func adopt(entries newEntries: [Entry], membership newMembership: [UUID: UUID], persist: Bool) {
        entries = newEntries
        membership = newMembership
        entryById = Dictionary(uniqueKeysWithValues: newEntries.map { ($0.id, $0) })
        if persist {
            LocalStore.save(DiskSnapshot(entries: newEntries, membership: newMembership), as: cacheKey)
        }
        pushToEngine()
    }

    /// Rebuilds the engine index from the current mirror plus any pending
    /// outbox entries, then bumps `revision` so an active query re-evaluates.
    private func pushToEngine() {
        var combined = entries
        if let pending = pendingProvider?() {
            let known = Set(combined.map(\.id))
            combined += pending.filter { !known.contains($0.id) }
        }
        let snapshot = SearchCorpusSnapshot(
            entries: combined,
            membership: membership,
            collectionNames: collectionNamesProvider?() ?? [:]
        )
        Task {
            await engine.update(snapshot: snapshot)
            revision += 1
        }
    }

    private nonisolated struct MembershipRow: Decodable, Sendable {
        let entry_id: UUID
        let collection_id: UUID
    }
}
