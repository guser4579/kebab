import Foundation

// MARK: - Corpus snapshot

/// Immutable input handed to the search engine: the user's full committed
/// corpus (roots + comments) plus the collection metadata needed for display
/// and for the collection-name relevance signal.
nonisolated struct SearchCorpusSnapshot: Sendable {
    let entries: [Entry]
    /// Root entry id → collection id (single canonical home).
    let membership: [UUID: UUID]
    /// Collection id → display name.
    let collectionNames: [UUID: String]
}

// MARK: - Snippet

/// A compact preview built around the strongest matching phrase, with the
/// actually-matched character ranges (offsets into `text`) for highlighting.
/// Offsets — not String.Index — so the value is trivially Equatable/Sendable
/// and safe to carry across actors.
nonisolated struct SearchSnippet: Equatable, Sendable {
    let text: String
    let highlights: [Range<Int>]
}

// MARK: - Results

/// One flat search result: a matched root or comment, independently ranked.
/// Thread information (rootId, collection ownership) is carried only for
/// exact-context navigation, metadata, and ranking — the visible list never
/// explains relationships between matches. Search list = individual relevant
/// matches; detail = full context.
nonisolated struct SearchResultItem: Identifiable, Equatable, Sendable {
    let entry: Entry
    let snippet: SearchSnippet
    /// The thought this match lives in (== entry.id for root matches).
    let rootId: UUID
    let collectionId: UUID?
    let collectionName: String?
    let score: Double

    var id: UUID { entry.id }
    var isComment: Bool { entry.parent_id != nil }
}

/// Collection represented in a result set, for the quiet refinement row.
nonisolated struct SearchCollectionFacet: Identifiable, Equatable, Sendable {
    let collectionId: UUID
    let name: String
    let clusterCount: Int

    var id: UUID { collectionId }
}

/// The atomic output of one query evaluation. Swapped in wholesale — the UI
/// never renders a partial or intermediate state.
nonisolated struct SearchResultSet: Equatable, Sendable {
    let query: String
    let results: [SearchResultItem]
    /// Near-miss candidates, never interleaved with true matches. Max ~3.
    let possible: [SearchResultItem]
    let facets: [SearchCollectionFacet]

    var isEmpty: Bool { results.isEmpty && possible.isEmpty }

    static let none = SearchResultSet(query: "", results: [], possible: [], facets: [])
}
