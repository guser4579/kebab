import SwiftUI
import Supabase

struct CollectionsView: View {

    @ObservedObject var collectionsViewModel: CollectionsViewModel
    let feedViewModel: FeedViewModel
    let supabase: SupabaseClient
    let onNewCollectionTapped: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                newCollectionRow

                if let errorMessage = collectionsViewModel.errorMessage {
                    Text(errorMessage)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .padding(.horizontal, Style.Layout.entryContentPadding)
                        .padding(.vertical, Style.Spacing.x4)
                }

                if collectionsViewModel.hasCompletedInitialLoad
                    && collectionsViewModel.parentCollections.isEmpty
                    && collectionsViewModel.errorMessage == nil
                {
                    EmptyStateView(
                        iconName: "add-circle",
                        title: "No collections yet",
                        primaryBody: "Create a collection to organize your top entries.",
                        secondaryBody: "Tap \"New collection\" above to get started."
                    )
                    .padding(Style.Spacing.emptyStateMargin)
                }

                ForEach(collectionsViewModel.parentCollections) { collection in
                    CollectionRowView(
                        collection: collection,
                        collectionsViewModel: collectionsViewModel,
                        feedViewModel: feedViewModel,
                        supabase: supabase
                    )
                }
            }
        }
        .defaultScrollAnchor(.top)
        .scrollDismissesKeyboard(.interactively)
    }

    private var newCollectionRow: some View {
        VStack(spacing: 0) {
            Button {
                onNewCollectionTapped()
            } label: {
                HStack(spacing: Style.Spacing.x3) {
                    Icon("add-circle")
                        .foregroundColor(Style.Color.primaryText)

                    Text("New collection")
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.primaryText)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Style.Layout.entryContentPadding)
                .padding(.vertical, Style.Spacing.x4)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Collection Row

private struct CollectionRowView: View {

    let collection: Collection
    @ObservedObject var collectionsViewModel: CollectionsViewModel
    let feedViewModel: FeedViewModel
    let supabase: SupabaseClient

    private var itemCountLabel: String {
        collection.itemCount == 1 ? "1 item" : "\(collection.itemCount) items"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                NavigationLink(destination: CollectionDetailView(
                    collection: collection,
                    collectionsViewModel: collectionsViewModel,
                    feedViewModel: feedViewModel,
                    supabase: supabase
                )) {
                    Color.clear
                        .contentShape(Rectangle())
                }

                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 16)

                    Text(collection.name)
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 4)

                    HStack(spacing: 0) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(Style.Timestamp.relative(for: collection.updatedAt, relativeTo: context.date))
                                .font(Style.Typography.meta())
                                .foregroundColor(Style.Color.secondary)
                        }

                        Spacer(minLength: 0)

                        Text(itemCountLabel)
                            .font(Style.Typography.meta())
                            .foregroundColor(Style.Color.secondary)
                    }

                    Color.clear
                        .frame(height: 16)
                }
                .padding(.horizontal, Style.Layout.entryContentPadding)
            }

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }
}
