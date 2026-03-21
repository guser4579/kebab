import Foundation
import Combine
import Supabase

@MainActor
final class SearchViewModel: ObservableObject {

    @Published var query: String = "" {
        didSet { queryDidChange() }
    }
    @Published private(set) var results: [Entry] = []
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var showSpinner: Bool = false
    @Published private(set) var hasCompletedSearch: Bool = false
    @Published private(set) var history: [SearchHistoryItem] = []

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private let userId: UUID
    private let repository: EntryRepository
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var searchGeneration: Int = 0

    // The exact query whose results are currently displayed.
    private var lastSearchedQuery: String?
    // A valid query explicitly submitted via keyboard whose matching search has not yet completed.
    private var pendingSubmittedQuery: String?
    // The query already committed in the current active-query cycle; prevents duplicate saves without time heuristics.
    private var committedDisplayedQuery: String?

    private static let legacyHistoryKey = "searchHistory"
    private var historyKey: String { "searchHistory_\(userId.uuidString)" }
    private static let maxHistoryItems = 10

    init(supabase: SupabaseClient, userId: UUID) {
        self.userId = userId
        self.repository = EntryRepository(supabase: supabase)
        self.history = []
        self.history = loadHistory()
        UserDefaults.standard.removeObject(forKey: Self.legacyHistoryKey)
    }

    // MARK: - Search

    private func queryDidChange() {
        let trimmed = trimmedQuery

        // End the active-query cycle for any intent state that no longer matches the current effective query.
        if trimmed.lowercased() != pendingSubmittedQuery?.lowercased() {
            pendingSubmittedQuery = nil
        }
        if trimmed.lowercased() != committedDisplayedQuery?.lowercased() {
            committedDisplayedQuery = nil
        }

        if trimmed.count < 3 {
            cancelAll()
            lastSearchedQuery = nil
            results = []
            isSearching = false
            showSpinner = false
            hasCompletedSearch = false
            return
        }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled {
                self.performSearch(query: self.trimmedQuery, recordHistory: true)
            }
        }
    }

    private func cancelAll() {
        debounceTask?.cancel()
        searchTask?.cancel()
        spinnerTask?.cancel()
    }

    func refreshResults() {
        guard trimmedQuery.count >= 3, hasCompletedSearch else { return }
        performSearch(query: trimmedQuery, recordHistory: false)
    }

    /// Replaces a single entry in the current search results array in-place.
    /// Used for optimistic local patching (e.g. fire_count increment) without
    /// triggering a full search re-fetch.
    func patchEntry(_ updated: Entry) {
        results = results.map { $0.id == updated.id ? updated : $0 }
    }

    private func performSearch(query: String, recordHistory: Bool) {
        searchTask?.cancel()
        spinnerTask?.cancel()
        showSpinner = false
        isSearching = true

        searchGeneration += 1
        let generation = searchGeneration

        if !hasCompletedSearch {
            spinnerTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !Task.isCancelled && self.isSearching {
                    self.showSpinner = true
                }
            }
        }

        searchTask = Task {
            do {
                let entries = try await self.repository.searchEntries(query: query)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.results = entries
                self.isSearching = false
                self.showSpinner = false
                self.hasCompletedSearch = true
                self.spinnerTask?.cancel()
                self.lastSearchedQuery = query
                if recordHistory,
                   let pending = self.pendingSubmittedQuery,
                   pending.lowercased() == query.lowercased(),
                   self.committedDisplayedQuery?.lowercased() != query.lowercased() {
                    self.commitToHistory(query: query, resultCount: entries.count)
                    self.committedDisplayedQuery = query
                    self.pendingSubmittedQuery = nil
                }
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.isSearching = false
                self.showSpinner = false
                self.spinnerTask?.cancel()
                if self.pendingSubmittedQuery?.lowercased() == query.lowercased() {
                    self.pendingSubmittedQuery = nil
                }
            }
        }
    }

    // MARK: - Explicit Intent

    /// Called when the user presses Enter/Search on the keyboard.
    /// Source of truth: current trimmed input field.
    func recordExplicitSubmitIntent() {
        let trimmed = trimmedQuery
        guard trimmed.count >= 3 else { return }
        guard committedDisplayedQuery?.lowercased() != trimmed.lowercased() else { return }

        if hasCompletedSearch && lastSearchedQuery?.lowercased() == trimmed.lowercased() {
            // Results for this exact query are already displayed — commit immediately.
            commitToHistory(query: trimmed, resultCount: results.count)
            committedDisplayedQuery = trimmed
            pendingSubmittedQuery = nil
        } else {
            // Search not yet complete for this query — park intent and commit when it succeeds.
            pendingSubmittedQuery = trimmed
        }
    }

    /// Called when the user activates a search result (e.g. taps the comment icon).
    /// Source of truth: the query that produced the currently displayed results.
    func recordDisplayedResultActivation() {
        guard let displayed = lastSearchedQuery, displayed.count >= 3 else { return }
        guard committedDisplayedQuery?.lowercased() != displayed.lowercased() else { return }
        commitToHistory(query: displayed, resultCount: results.count)
        committedDisplayedQuery = displayed
    }

    // MARK: - History

    func deleteHistoryItem(id: UUID) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    private func commitToHistory(query: String, resultCount: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }

        let dedupeKey = trimmed.lowercased()
        history.removeAll {
            $0.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == dedupeKey
        }

        let item = SearchHistoryItem(
            id: UUID(),
            query: trimmed,
            resultCount: resultCount,
            searchedAt: Date()
        )
        history.insert(item, at: 0)

        if history.count > Self.maxHistoryItems {
            history = Array(history.prefix(Self.maxHistoryItems))
        }

        saveHistory()
    }

    private func loadHistory() -> [SearchHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([SearchHistoryItem].self, from: data)) ?? []
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}
