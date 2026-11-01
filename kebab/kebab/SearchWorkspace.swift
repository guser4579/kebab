import Foundation
import Combine

/// The query text, isolated in its own observable so a keystroke invalidates
/// the field — not the whole Search screen.
@MainActor
final class SearchFieldModel: ObservableObject {
    @Published var query: String = ""
}

/// Result-side state, published only when something the results surface
/// renders actually changes.
@MainActor
final class SearchResultsModel: ObservableObject {
    /// True while the (trimmed) query has ≥ 1 character — drives the
    /// three-state switch without re-publishing per keystroke.
    @Published fileprivate(set) var hasActiveQuery = false
    @Published fileprivate(set) var resultSet: SearchResultSet = .none
    /// Active collection refinement (nil = unrefined); collection-only filter.
    @Published var collectionRefinement: UUID?
    /// The object whose result card gets the quiet reacquisition treatment
    /// after returning from it. Cleared by the card once shown.
    @Published var reacquisitionEntryId: UUID?
}

/// Explore tiles for the resting state. Recomputed once per corpus revision
/// and whenever Recent Activity changes — never per body evaluation.
@MainActor
final class SearchLensModel: ObservableObject {

    @Published private(set) var tiles: [SearchTile] = []

    private var generation = 0
    private var cancellables: Set<AnyCancellable> = []

    init(corpus: SearchCorpusStore, recentActivity: RecentActivityStore) {
        // First frame renders with tiles in place (one synchronous pass when
        // Search opens); later changes compute off-main.
        tiles = Self.compute(entries: corpus.indexedEntries(), activity: recentActivity.items)

        // @Published emits on willSet: Recent Activity arrives as the new
        // value; the corpus's entries are already adopted by the time its
        // revision bumps.
        corpus.$revision
            .combineLatest(recentActivity.$items)
            .dropFirst()
            .sink { [weak self, weak corpus] _, items in
                guard let self, let corpus else { return }
                self.recompute(entries: corpus.indexedEntries(), activity: items)
            }
            .store(in: &cancellables)
    }

    private func recompute(entries: [Entry], activity: [RecentActivityItem]) {
        generation += 1
        let current = generation
        Task {
            let fresh = await Task.detached(priority: .userInitiated) {
                Self.compute(entries: entries, activity: activity)
            }.value
            guard current == self.generation, fresh != self.tiles else { return }
            self.tiles = fresh
        }
    }

    private nonisolated static func compute(entries: [Entry], activity: [RecentActivityItem]) -> [SearchTile] {
        SearchLenses.tiles(entries: entries, recentActivity: activity, now: Date(), calendar: .current)
    }
}

/// One Search session: a suspended workspace. Created when Search opens,
/// destroyed when the user fully backs out — never resurrected across cold
/// launches. Everything in between (entering results, editing, deleting,
/// backgrounding) returns to this exact state.
@MainActor
final class SearchWorkspace {

    let field = SearchFieldModel()
    let results = SearchResultsModel()

    let corpus: SearchCorpusStore
    let recentSearches: RecentSearchesStore
    let recentActivity: RecentActivityStore
    let lenses: SearchLensModel

    private var generation = 0
    /// Random's draws this session, oldest first — in memory only.
    private var randomPicks: [UUID] = []
    private var cancellables: Set<AnyCancellable> = []
    private var hasAppeared = false
    private var lastOpenedEntryId: UUID?

    init(
        corpus: SearchCorpusStore,
        recentSearches: RecentSearchesStore,
        recentActivity: RecentActivityStore
    ) {
        self.corpus = corpus
        self.recentSearches = recentSearches
        self.recentActivity = recentActivity
        self.lenses = SearchLensModel(corpus: corpus, recentActivity: recentActivity)

        // Deduplicate on the EFFECTIVE (trimmed) query: whitespace-only edits
        // never re-run the same search or reset per-query state (like an
        // active collection refinement).
        field.$query
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .sink { [weak self] trimmed in
                self?.queryDidChange(trimmed)
            }
            .store(in: &cancellables)

        // Corpus refreshed mid-session (mutation, revalidation): current truth
        // flows into the open result set without reshuffling it.
        corpus.$revision
            .dropFirst()
            .sink { [weak self] _ in
                self?.reevaluatePreservingOrder()
            }
            .store(in: &cancellables)
    }

    private var trimmedQuery: String {
        field.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The current effective query, for render-time gating (e.g. the empty
    /// state only shows once results for THIS query have arrived).
    var effectiveQuery: String { trimmedQuery }

    // MARK: - Query pipeline

    private func queryDidChange(_ trimmed: String) {
        recentSearches.queryChanged(to: trimmed)

        guard !trimmed.isEmpty else {
            generation += 1
            if results.hasActiveQuery { results.hasActiveQuery = false }
            results.resultSet = .none
            clearPerQueryState()
            return
        }

        if !results.hasActiveQuery { results.hasActiveQuery = true }
        generation += 1
        let current = generation
        let activityRoots = Set(recentActivity.items.map(\.rootId))

        Task {
            let fresh = await corpus.engine.search(
                rawQuery: trimmed,
                recentActivityRoots: activityRoots
            )
            guard current == self.generation else { return }
            // A changed query may fully re-rank; per-query state resets with it.
            self.clearPerQueryState()
            if fresh != self.results.resultSet {
                self.results.resultSet = fresh          // atomic swap
            }
            self.recentSearches.resultsDidArrive(for: trimmed)
        }
    }

    /// Re-evaluates the active query against fresh corpus truth while keeping
    /// surviving results in their current order — nothing reshuffles under
    /// the user. Genuinely new results append; vanished ones drop.
    private func reevaluatePreservingOrder() {
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else { return }
        generation += 1
        let current = generation
        let activityRoots = Set(recentActivity.items.map(\.rootId))

        Task {
            let fresh = await corpus.engine.search(
                rawQuery: trimmed,
                recentActivityRoots: activityRoots
            )
            guard current == self.generation else { return }

            let previousOrder = self.results.resultSet.results.map(\.id)
            let freshById = Dictionary(uniqueKeysWithValues: fresh.results.map { ($0.id, $0) })
            var stable: [SearchResultItem] = previousOrder.compactMap { freshById[$0] }
            let surviving = Set(stable.map(\.id))
            stable += fresh.results.filter { !surviving.contains($0.id) }

            let merged = SearchResultSet(
                query: fresh.query,
                results: stable,
                possible: fresh.possible.filter { !surviving.contains($0.id) },
                facets: fresh.facets
            )
            if merged != self.results.resultSet {
                self.results.resultSet = merged
            }

            if let refinement = self.results.collectionRefinement,
               !merged.facets.contains(where: { $0.collectionId == refinement }) {
                self.results.collectionRefinement = nil
            }
        }
    }

    private func clearPerQueryState() {
        results.collectionRefinement = nil
        results.reacquisitionEntryId = nil
    }

    // MARK: - Intent

    /// Keyboard submit — a final meaningful query.
    func recordSubmit() {
        let trimmed = trimmedQuery
        recentSearches.recordExplicitSubmit(
            query: trimmed,
            resultsAreCurrent: results.resultSet.query == trimmed
        )
    }

    /// The user is entering a result: remember the doorway for reacquisition
    /// and commit the query that produced it.
    func noteOpened(entryId: UUID) {
        lastOpenedEntryId = entryId
        if results.hasActiveQuery {
            recentSearches.recordResultActivation(query: results.resultSet.query)
        }
    }

    /// Random's tap: a fresh draw from the tile's members that avoids the
    /// last few picks this session.
    func drawRandom(from tile: SearchTile) -> Entry? {
        var generator = SystemRandomNumberGenerator()
        guard let id = SearchLenses.pickRandom(
            from: tile.entryIds,
            recentPicks: randomPicks,
            using: &generator
        ) else { return nil }
        randomPicks.append(id)
        randomPicks = Array(randomPicks.suffix(SearchLensTuning.randomAvoidedRecentPicks))
        return corpus.indexedEntry(id: id)
    }

    // MARK: - Lifecycle

    /// The Search surface became visible. First appearance seeds the corpus;
    /// every return from a result re-arms reacquisition and refreshes truth.
    func surfaceDidAppear() {
        if hasAppeared, let opened = lastOpenedEntryId {
            results.reacquisitionEntryId = opened
            lastOpenedEntryId = nil
        }
        hasAppeared = true
        Task {
            await corpus.refreshIfNeeded()
            self.recentActivity.prune { self.corpus.containsRoot($0) }
        }
    }
}
