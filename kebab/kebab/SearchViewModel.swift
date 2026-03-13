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

    private let repository: EntryRepository
    private var debounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?

    init(supabase: SupabaseClient) {
        self.repository = EntryRepository(supabase: supabase)
    }

    private func queryDidChange() {
        if query.count < 3 {
            cancelAll()
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
                self.performSearch(query: self.query)
            }
        }
    }

    private func cancelAll() {
        debounceTask?.cancel()
        searchTask?.cancel()
        spinnerTask?.cancel()
    }

    func refreshResults() {
        guard query.count >= 3, hasCompletedSearch else { return }
        performSearch(query: query)
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        spinnerTask?.cancel()
        showSpinner = false
        isSearching = true

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
                if !Task.isCancelled {
                    self.results = entries
                    self.isSearching = false
                    self.showSpinner = false
                    self.hasCompletedSearch = true
                    self.spinnerTask?.cancel()
                }
            } catch {
                if !Task.isCancelled {
                    self.isSearching = false
                    self.showSpinner = false
                    self.spinnerTask?.cancel()
                }
            }
        }
    }
}
