import Foundation
import Combine

nonisolated struct RecentSearch: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let query: String
    let searchedAt: Date
}

/// Recent Searches: final meaningful queries only. A query is committed when
/// the user submits it from the keyboard or opens a result it produced —
/// intermediate live-search keystrokes are never persisted. (Same intent
/// model the previous Search shipped with; result counts are gone.)
@MainActor
final class RecentSearchesStore: ObservableObject {

    @Published private(set) var items: [RecentSearch] = []

    private static let maxItems = 10
    private var userId: UUID?
    /// Same key the previous implementation used — existing history decodes
    /// cleanly (the retired resultCount field is simply ignored).
    private var storageKey: String {
        "searchHistory_\(userId?.uuidString ?? "anonymous")"
    }

    // The query already committed in the current active-query cycle;
    // prevents duplicate saves without time heuristics.
    private var committedQuery: String?
    // A query explicitly submitted via keyboard, pending its evaluation.
    private var pendingSubmittedQuery: String?

    func configure(userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        items = LocalStore.load([RecentSearch].self, from: storageKey) ?? []
    }

    // MARK: - Intent

    /// The effective query changed; intent tied to a different query ends.
    func queryChanged(to trimmed: String) {
        if trimmed.lowercased() != pendingSubmittedQuery?.lowercased() {
            pendingSubmittedQuery = nil
        }
        if trimmed.lowercased() != committedQuery?.lowercased() {
            committedQuery = nil
        }
    }

    /// Keyboard submit: commit the current query once results have shown.
    func recordExplicitSubmit(query trimmed: String, resultsAreCurrent: Bool) {
        guard !trimmed.isEmpty else { return }
        guard committedQuery?.lowercased() != trimmed.lowercased() else { return }
        if resultsAreCurrent {
            commit(trimmed)
        } else {
            pendingSubmittedQuery = trimmed
        }
    }

    /// Evaluation finished for `query`; a parked submit for it commits now.
    func resultsDidArrive(for query: String) {
        guard let pending = pendingSubmittedQuery,
              pending.lowercased() == query.lowercased() else { return }
        pendingSubmittedQuery = nil
        if committedQuery?.lowercased() != query.lowercased() {
            commit(query)
        }
    }

    /// The user opened a result: the query that produced it was meaningful.
    func recordResultActivation(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard committedQuery?.lowercased() != trimmed.lowercased() else { return }
        commit(trimmed)
    }

    // MARK: - Mutation

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func commit(_ query: String) {
        let dedupeKey = query.lowercased()
        items.removeAll {
            $0.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == dedupeKey
        }
        items.insert(RecentSearch(id: UUID(), query: query, searchedAt: Date()), at: 0)
        if items.count > Self.maxItems {
            items = Array(items.prefix(Self.maxItems))
        }
        committedQuery = query
        save()
    }

    private func save() {
        LocalStore.save(items, as: storageKey)
    }
}
