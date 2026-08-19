import SwiftUI

/// Search: a suspended workspace pushed over the feed. The push transition,
/// header geometry, and swipe-back are unchanged from the previous
/// implementation; the field — not a title — is the screen's identity.
///
/// Three states:
///   1. field unfocused, query empty  → Recent Activity (resume stack)
///   2. field focused, query empty    → Recent Searches
///   3. query has ≥ 1 character       → live results (local, instantaneous)
struct SearchView: View {

    let workspace: SearchWorkspace
    @ObservedObject var feedViewModel: FeedViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchHeaderView(
                field: workspace.field,
                isFieldFocused: $isFieldFocused,
                onBack: { dismiss() },
                onSubmit: { workspace.recordSubmit() }
            )

            SearchContentView(
                workspace: workspace,
                results: workspace.results,
                recentSearches: workspace.recentSearches,
                recentActivity: workspace.recentActivity,
                corpus: workspace.corpus,
                feedViewModel: feedViewModel,
                isFieldFocused: isFieldFocused
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.Color.background)
        .foregroundColor(Style.Color.primaryText)
        .ignoresSafeArea(edges: .top)
        .background(Style.Color.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .enablesSwipeBack()
    }
}

// MARK: - Header

/// Back + field. Observes only the field model, so keystrokes never
/// invalidate the content below.
private struct SearchHeaderView: View {

    @ObservedObject var field: SearchFieldModel
    var isFieldFocused: FocusState<Bool>.Binding
    let onBack: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            // One navigation row: chevron + field, chevron centered against
            // the field. The push/pop behavior itself is unchanged.
            HStack(spacing: 12) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Style.Color.secondary)
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                searchField
            }
            .padding(.horizontal, Style.Spacing.x4)

            Color.clear
                .frame(height: 16)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(Style.Color.background)
    }

    private var searchField: some View {
        TextField(
            "",
            text: $field.query,
            prompt: Text("Search your thoughts")
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.secondary)
        )
        .font(Style.Typography.body())
        .foregroundColor(Style.Color.primaryText)
        .tint(Style.Color.composerSend)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .lineLimit(1)
        .focused(isFieldFocused)
        .submitLabel(.search)
        .onSubmit { onSubmit() }
        .padding(.leading, Style.Spacing.x4)
        .padding(.trailing, Style.Spacing.x4 + Style.Icon.grid)
        .padding(.vertical, Style.Spacing.x3)
        .background(Style.Color.composerBackground)
        .clipShape(Capsule())
        .overlay(alignment: .trailing) {
            if !field.query.isEmpty {
                // X: clears the query, keeps the keyboard — landing on
                // Recent Searches (state 2), never ending the session.
                Button {
                    field.query = ""
                } label: {
                    Icon("close", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.secondary)
                }
                .padding(.trailing, Style.Spacing.x4)
            }
        }
    }
}

// MARK: - Content (three states)

private struct SearchContentView: View {

    let workspace: SearchWorkspace
    @ObservedObject var results: SearchResultsModel
    @ObservedObject var recentSearches: RecentSearchesStore
    @ObservedObject var recentActivity: RecentActivityStore
    @ObservedObject var corpus: SearchCorpusStore
    let feedViewModel: FeedViewModel
    let isFieldFocused: Bool

    var body: some View {
        Group {
            if results.hasActiveQuery {
                resultsList
            } else if isFieldFocused {
                recentSearchesList
            } else {
                recentActivityList
            }
        }
        .onAppear {
            workspace.surfaceDidAppear()
        }
    }

    // MARK: - State 3 · Live results

    private var displayResults: [SearchResultItem] {
        guard let refinement = results.collectionRefinement else {
            return results.resultSet.results
        }
        return results.resultSet.results.filter { $0.collectionId == refinement }
    }

    /// Refinement surfaces only when breadth makes it useful, and only
    /// collections actually represented in the current result set.
    private var showsRefinement: Bool {
        results.resultSet.results.count >= 8 && results.resultSet.facets.count >= 2
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if showsRefinement {
                    refinementRow
                }

                if results.resultSet.isEmpty {
                    // "No matches" only when evaluation for the CURRENT query
                    // has definitively come back empty — never while a fresh
                    // query is still evaluating (no false-negative flash).
                    if !results.resultSet.query.isEmpty,
                       results.resultSet.query == workspace.effectiveQuery {
                        Text("No matches")
                            .font(Style.Typography.body())
                            .foregroundColor(Style.Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    }
                } else {
                    ForEach(displayResults) { item in
                        row(for: item)
                    }

                    if !results.resultSet.possible.isEmpty && results.collectionRefinement == nil {
                        Text("Possible matches")
                            .font(Style.Typography.meta())
                            .foregroundColor(Style.Color.secondary)
                            .padding(.horizontal, Style.Layout.entryContentPadding)
                            .padding(.top, 24)
                            // A section heading attaches to its content: the
                            // first row's own 16pt inset minus this pull-up
                            // leaves ~8pt under the overline, while the
                            // larger gap stays above it.
                            .padding(.bottom, -8)

                        ForEach(results.resultSet.possible) { item in
                            row(for: item)
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func row(for item: SearchResultItem) -> some View {
        SearchResultRowView(
            item: item,
            reacquisitionEntryId: results.reacquisitionEntryId,
            feedViewModel: feedViewModel,
            onOpen: { entryId in
                workspace.noteOpened(entryId: entryId)
            },
            onReacquisitionShown: {
                results.reacquisitionEntryId = nil
            }
        )
    }

    /// Refinement pills reuse the sub-collection chip language: ink fill with
    /// inverted text when selected; white fill with Kebab's quiet border when
    /// not. No Search-specific chip style.
    private var refinementRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Style.Spacing.x2) {
                ForEach(results.resultSet.facets) { facet in
                    let isActive = results.collectionRefinement == facet.collectionId
                    Button {
                        results.collectionRefinement = isActive ? nil : facet.collectionId
                    } label: {
                        Text(facet.name.collectionCompactDisplayName)
                            .font(Style.Typography.pill(selected: isActive))
                            .foregroundColor(
                                isActive ? Style.Color.composerSendForeground : Style.Color.secondary
                            )
                            .lineLimit(1)
                            .padding(.horizontal, Style.Spacing.x3)
                            .frame(height: 32)
                            .background(
                                Capsule()
                                    .fill(isActive ? Style.Color.composerSend : Style.Color.composerBackground)
                                    .overlay(
                                        Capsule().stroke(
                                            isActive ? SwiftUI.Color.clear : Style.Color.separator,
                                            lineWidth: 1
                                        )
                                    )
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Style.Spacing.x4)
        }
        .padding(.vertical, Style.Spacing.x3)
    }

    // MARK: - State 2 · Recent Searches

    private var recentSearchesList: some View {
        Group {
            if recentSearches.items.isEmpty {
                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture { resignKeyboard() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(title: "Recent searches")

                        ForEach(recentSearches.items) { item in
                            recentSearchRow(item)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    /// Quiet section heading shared by the two landing states — the surface
    /// names itself; rows stay lightweight.
    private func sectionHeader(title: String, trailing: (() -> AnyView)? = nil) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.custom("DMSans-Medium", size: 16))
                .foregroundColor(Style.Color.primaryText)

            Spacer(minLength: 0)

            if let trailing {
                trailing()
            }
        }
        .padding(.horizontal, Style.Spacing.x4)
        .padding(.top, Style.Spacing.x4)
        .padding(.bottom, Style.Spacing.x2)
    }

    private func recentSearchRow(_ item: RecentSearch) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Button {
                    // Re-runs immediately: the query pipeline reacts to the
                    // field change; the keyboard stays as it is.
                    workspace.field.query = item.query
                } label: {
                    Text(item.query)
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    recentSearches.delete(id: item.id)
                } label: {
                    Icon("close", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.secondary)
                }
            }
            .padding(.horizontal, Style.Spacing.x4)
            .padding(.vertical, Style.Spacing.x3)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - State 1 · Recent Activity

    /// Items resolvable against the corpus (deleted thoughts drop away).
    private var resolvedActivityItems: [(item: RecentActivityItem, root: Entry)] {
        // Reading corpus.revision ties this to index updates.
        _ = corpus.revision
        return recentActivity.items.compactMap { item in
            guard let root = corpus.entry(id: item.rootId), root.parent_id == nil else { return nil }
            return (item, root)
        }
    }

    private var recentActivityList: some View {
        Group {
            let resolved = resolvedActivityItems
            if resolved.isEmpty {
                VStack(spacing: 0) {
                    Text("Nothing recent yet")
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.secondary)
                        .padding(.top, 120)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Clear is a deliberate section-level action, anchored
                        // to the heading — not floating in space.
                        sectionHeader(title: "Recent activity") {
                            AnyView(
                                Button {
                                    recentActivity.clear()
                                } label: {
                                    Text("Clear")
                                        .font(Style.Typography.meta())
                                        .foregroundColor(Style.Color.secondary)
                                }
                            )
                        }

                        ForEach(resolved, id: \.item.id) { pair in
                            activityRow(pair.item, root: pair.root)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    /// Resume rows invert the search-result hierarchy — action cue first,
    /// content second — so the surface reads as "my recent activity", never
    /// as a stack of results.
    private func activityRow(_ item: RecentActivityItem, root: Entry) -> some View {
        // Exact-context restoration: a deeply nested comment reopens that
        // comment; anything else reopens the thought.
        let context = item.contextEntryId != item.rootId
            ? corpus.entry(id: item.contextEntryId)
            : nil

        return VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                NavigationLink(destination: activityDestination(root: root, context: context)) {
                    Color.clear
                        .contentShape(Rectangle())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.kind.label) · \(Style.Timestamp.relative(for: item.date))")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .lineLimit(1)

                    // Same checklist-aware renderer as results (no highlights
                    // here) — markers never leak as raw text.
                    SearchSnippetView(
                        snippet: SearchSnippet(
                            text: SearchDisplay.previewText(for: root),
                            highlights: []
                        ),
                        maxSourceLines: 2,
                        perLineLimit: 1
                    )
                }
                .allowsHitTesting(false)
            }
            .padding(.horizontal, Style.Spacing.x4)
            .padding(.vertical, Style.Spacing.x3)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func activityDestination(root: Entry, context: Entry?) -> some View {
        if let context, context.parent_id != nil {
            CommentDetailView(
                comment: context,
                rootId: root.id,
                feedViewModel: feedViewModel,
                // Recent Activity is a Search-surface arrival too — same
                // mid-thread landing, same one-time orientation tint.
                highlightAnchorOnArrival: true
            )
        } else {
            EntryDetailView(
                entry: root,
                feedViewModel: feedViewModel,
                highlightOnArrival: true
            )
        }
    }

    private func resignKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
