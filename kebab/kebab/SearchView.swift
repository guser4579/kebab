import SwiftUI
import Supabase

struct SearchView: View {

    @StateObject private var searchViewModel: SearchViewModel
    @ObservedObject var feedViewModel: FeedViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false

    init(supabase: SupabaseClient, feedViewModel: FeedViewModel, userId: UUID) {
        _searchViewModel = StateObject(wrappedValue: SearchViewModel(supabase: supabase, userId: userId))
        self.feedViewModel = feedViewModel
    }

    private var isActiveQuery: Bool {
        searchViewModel.trimmedQuery.count >= 3
    }

    private var shouldShowCountRow: Bool {
        isActiveQuery && (searchViewModel.hasCompletedSearch || searchViewModel.showSpinner)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader

            if shouldShowCountRow {
                resultCountRow
            }

            if isActiveQuery {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(searchViewModel.results) { entry in
                            EntryRowView(entry: entry, feedViewModel: feedViewModel, onResultActivated: {
                                searchViewModel.recordDisplayedResultActivation()
                            }, onMoreTapped: {
                                activeEntryMenuEntry = entry
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = true
                                }
                            }, onResurfaceTapped: {
                                Task {
                                    await feedViewModel.resurfaceEntry(entry: entry)
                                    searchViewModel.refreshResults()
                                }
                            }, onPinTapped: {
                                Task {
                                    await feedViewModel.togglePin(entry: entry)
                                    searchViewModel.refreshResults()
                                }
                            })
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { searchViewModel.refreshResults() }
            } else if searchViewModel.history.isEmpty {
                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(searchViewModel.history) { item in
                            historyRow(item)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.Color.background)
        .foregroundColor(Style.Color.primaryText)
        .ignoresSafeArea(edges: .top)
        .background(Style.Color.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if activeEntryMenuEntry != nil {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isEntryActionSheetVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                activeEntryMenuEntry = nil
                            }
                        }

                    if isEntryActionSheetVisible, let entry = activeEntryMenuEntry {
                        EntryActionSheetView(
                            entry: entry,
                            isComment: false,
                            onDelete: {
                                Task {
                                    await feedViewModel.deleteEntry(id: entry.id)
                                    searchViewModel.refreshResults()
                                }
                            },
                            onEdit: {
                                Task {
                                    await feedViewModel.toggleEntryHidden(
                                        id: entry.id,
                                        currentValue: entry.isContentHidden
                                    )
                                    searchViewModel.refreshResults()
                                }
                            },
                            onDismiss: {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    activeEntryMenuEntry = nil
                                }
                            }
                        )
                        .transition(.move(edge: .bottom))
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Header

    private var searchHeader: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            headerTopBar

            Color.clear
                .frame(height: 24)

            searchField

            Color.clear
                .frame(height: 24)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(Style.Color.background)
    }

    private var headerTopBar: some View {
        ZStack {
            Text("Search")
                .font(.custom("DMSans-Medium", size: 16))
                .foregroundColor(Style.Color.primaryText)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Text("Back")
                        .font(.custom("DMSans-Regular", size: 16))
                        .foregroundColor(Style.Color.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Style.Spacing.x4)
            .frame(height: 24, alignment: .center)
        }
        .frame(height: 24)
    }

    private var searchField: some View {
        TextField(
            "",
            text: $searchViewModel.query,
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
        .onSubmit { searchViewModel.recordExplicitSubmitIntent() }
        .padding(.leading, Style.Spacing.x4)
        .padding(.trailing, Style.Spacing.x4 + Style.Icon.grid)
        .padding(.vertical, Style.Spacing.x3)
        .background(Style.Color.composerBackground)
        .clipShape(Capsule())
        .overlay(alignment: .trailing) {
            if !searchViewModel.query.isEmpty {
                Button {
                    searchViewModel.query = ""
                } label: {
                    Icon("close", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.secondary)
                }
                .padding(.trailing, Style.Spacing.x4)
            }
        }
        .padding(.horizontal, Style.Spacing.x4)
    }

    // MARK: - History

    private func historyRow(_ item: SearchHistoryItem) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Button {
                    searchViewModel.query = item.query
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.query)
                            .font(Style.Typography.body())
                            .foregroundColor(Style.Color.primaryText)
                            .lineLimit(1)

                        Text(item.resultCount == 1 ? "1 result" : "\(item.resultCount) results")
                            .font(Style.Typography.meta())
                            .foregroundColor(Style.Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    searchViewModel.deleteHistoryItem(id: item.id)
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

    // MARK: - Result Count

    private var resultCountRow: some View {
        VStack(spacing: 0) {
            Group {
                if searchViewModel.showSpinner && !searchViewModel.hasCompletedSearch {
                    ProgressView()
                        .tint(Style.Color.secondary)
                } else {
                    let count = searchViewModel.results.count
                    Text(count == 1 ? "1 result" : "\(count) results")
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Style.Spacing.x4)
            .padding(.vertical, Style.Spacing.x3)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }
}
