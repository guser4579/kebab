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

    private let repository: EntryRepository
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var searchGeneration: Int = 0

    private struct HistoryCandidate {
        let query: String
        let resultCount: Int
    }

    private var pendingCandidate: HistoryCandidate?
    private var settleTask: Task<Void, Never>?

    private static let historyKey = "searchHistory"
    private static let maxHistoryItems = 10
    private static let settleDuration: UInt64 = 2_000_000_000

    init(supabase: SupabaseClient) {
        self.repository = EntryRepository(supabase: supabase)
        self.history = Self.loadHistory()
    }

    // MARK: - Search

    private func queryDidChange() {
        if trimmedQuery.count < 3 {
            cancelAll()
            settleTask?.cancel()
            pendingCandidate = nil
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
                if recordHistory {
                    self.setPendingCandidate(query: query, resultCount: entries.count)
                }
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.isSearching = false
                self.showSpinner = false
                self.spinnerTask?.cancel()
            }
        }
    }

    // MARK: - History

    private func setPendingCandidate(query: String, resultCount: Int) {
        pendingCandidate = HistoryCandidate(query: query, resultCount: resultCount)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleDuration)
            guard let self, !Task.isCancelled else { return }
            if let candidate = self.pendingCandidate {
                self.commitToHistory(query: candidate.query, resultCount: candidate.resultCount)
                self.pendingCandidate = nil
            }
        }
    }

    func flushPendingHistory() {
        settleTask?.cancel()
        if let candidate = pendingCandidate {
            commitToHistory(query: candidate.query, resultCount: candidate.resultCount)
            pendingCandidate = nil
        }
    }

    func deleteHistoryItem(id: UUID) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    private func commitToHistory(query: String, resultCount: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

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

    private static func loadHistory() -> [SearchHistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([SearchHistoryItem].self, from: data)) ?? []
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
}
