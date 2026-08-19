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

    /// In-flight cached-snapshot load (startup decode happens off-main).
    /// Refresh awaits it so Search never treats a still-loading corpus as
    /// empty truth.
    private var cacheLoad: Task<Void, Never>?
    /// Debounce for disk persistence: a burst of mutations writes once.
    private var persistDebounce: Task<Void, Never>?
    /// Strictly ordered writer chain: overlapping writes can never land
    /// out of order, so the latest snapshot always wins on disk.
    private var persistChain: Task<Void, Never> = Task {}
    /// Coalesce for whole-index rebuilds: N rapid corpus changes (outbox
    /// drain on reconnect, delete fan-outs) produce one engine update.
    private var indexPush: Task<Void, Never>?

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
        isStale = true
        // The whole-corpus snapshot decodes off-main; adoption hops back to
        // the main actor when it's ready. Launch never blocks on this.
        let key = cacheKey
        cacheLoad = Task { [weak self] in
            let cached = await Task.detached(priority: .userInitiated) {
                LocalStore.load(DiskSnapshot.self, from: key)
            }.value
            guard let self, let cached, self.userId == userId else { return }
            // Network truth may have landed first; disk never clobbers it.
            if self.entries.isEmpty {
                self.adopt(entries: cached.entries, membership: cached.membership, persist: false)
            }
        }
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
        // The cached corpus must finish adopting first — otherwise a refresh
        // could compare against (and briefly present) an empty mirror.
        await cacheLoad?.value
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
            // No-op refresh short-circuit: a structurally identical corpus is
            // not re-adopted — no repersist of the same snapshot, no revision
            // bump, no whole-index rebuild just because a refresh ran.
            if freshEntries != entries || membershipMap != membership {
                adopt(entries: freshEntries, membership: membershipMap, persist: true)
            }
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

    /// Every comment in a thread, from the mirror — the offline substitute
    /// for a failed `fetchComments` (same shape: comments only, no root).
    func threadComments(rootId: UUID) -> [Entry] {
        entries.filter { $0.root_id == rootId && $0.parent_id != nil }
    }

    // MARK: - Internals

    private func adopt(entries newEntries: [Entry], membership newMembership: [UUID: UUID], persist: Bool) {
        entries = newEntries
        membership = newMembership
        entryById = Dictionary(uniqueKeysWithValues: newEntries.map { ($0.id, $0) })
        if persist {
            schedulePersist()
        }
        pushToEngine()
    }

    /// Debounced, strictly ordered, off-main persistence of the whole-corpus
    /// snapshot. A burst of mutations produces one encode+write, on a
    /// background thread; the writer chain guarantees the latest snapshot is
    /// the one that ends up on disk. A crash can lose at most the last
    /// not-yet-flushed update — the server remains authoritative.
    private func schedulePersist() {
        persistDebounce?.cancel()
        let snapshot = DiskSnapshot(entries: entries, membership: membership)
        let key = cacheKey
        persistDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let previous = self.persistChain
            self.persistChain = Task(priority: .utility) {
                await previous.value
                await Task.detached(priority: .utility) {
                    LocalStore.save(snapshot, as: key)
                }.value
            }
        }
    }

    /// Rebuilds the engine index from the current mirror plus any pending
    /// outbox entries, then bumps `revision` so an active query re-evaluates.
    /// Coalesced: closely spaced corpus changes fold into one rebuild instead
    /// of queueing N full re-tokenizations on the engine actor.
    private func pushToEngine() {
        indexPush?.cancel()
        indexPush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            var combined = self.entries
            if let pending = self.pendingProvider?() {
                let known = Set(combined.map(\.id))
                combined += pending.filter { !known.contains($0.id) }
            }
            let snapshot = SearchCorpusSnapshot(
                entries: combined,
                membership: self.membership,
                collectionNames: self.collectionNamesProvider?() ?? [:]
            )
            await self.engine.update(snapshot: snapshot)
            self.revision += 1
        }
    }

    private nonisolated struct MembershipRow: Decodable, Sendable {
        let entry_id: UUID
        let collection_id: UUID
    }
}
