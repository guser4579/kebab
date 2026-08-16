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

    private var generation = 0
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

        field.$query
            .removeDuplicates()
            .sink { [weak self] query in
                self?.queryDidChange(query)
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

    // MARK: - Query pipeline

    private func queryDidChange(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
