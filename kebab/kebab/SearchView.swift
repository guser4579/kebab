import SwiftUI
import Supabase

struct SearchView: View {

    @StateObject private var searchViewModel: SearchViewModel
    @Environment(\.dismiss) private var dismiss

    init(supabase: SupabaseClient) {
        _searchViewModel = StateObject(wrappedValue: SearchViewModel(supabase: supabase))
    }

    private var isActiveQuery: Bool {
        searchViewModel.query.count >= 3
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
                            EntryRowView(entry: entry)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.Color.background)
        .foregroundColor(Style.Color.primaryText)
        .ignoresSafeArea(edges: .top)
        .background(Style.Color.background.ignoresSafeArea())
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
