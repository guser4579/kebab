import SwiftUI
import Supabase

struct CollectionDetailView: View {

    let collection: Collection
    @ObservedObject var collectionsViewModel: CollectionsViewModel

    @StateObject private var collectionFeedVM: CollectionFeedViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var displayedName: String

    // Collection-level action sheet (rename / delete)
    @State private var isCollectionActionSheetPresented = false
    @State private var isCollectionActionSheetVisible = false
    @State private var isRenameVisible = false
    @State private var deleteErrorMessage: String?

    // Entry-level action sheet (edit / remove / hide / delete)
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false

    // Full-screen edit overlay
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false

    // Scroll-to-bottom control (mirrors FeedScrollContent pattern)
    @State private var hasScrolledToBottom = false

    init(
        collection: Collection,
        collectionsViewModel: CollectionsViewModel,
        feedViewModel: FeedViewModel,
        supabase: SupabaseClient
    ) {
        self.collection = collection
        self.collectionsViewModel = collectionsViewModel
        _displayedName = State(initialValue: collection.name)
        _collectionFeedVM = StateObject(wrappedValue: CollectionFeedViewModel(
            collection: collection,
            supabase: supabase,
            feedViewModel: feedViewModel,
            collectionsViewModel: collectionsViewModel
        ))
    }

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                detailHeader

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if collectionFeedVM.hasCompletedInitialLoad && collectionFeedVM.entries.isEmpty {
                                EmptyStateView(
                                    iconName: "folder",
                                    title: "No entries yet",
                                    primaryBody: "Add entries to this collection from the feed.",
                                    secondaryBody: "Tap the ••• menu on any entry and choose \"Add to collection\"."
                                )
                                .padding(Style.Spacing.emptyStateMargin)
                            }

                            ForEach(collectionFeedVM.entries) { entry in
                                EntryRowView(
                                    entry: entry,
                                    feedViewModel: collectionFeedVM.feedViewModel,
                                    showResurface: false,
                                    onMoreTapped: {
                                        activeEntryMenuEntry = entry
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isEntryActionSheetVisible = true
                                        }
                                    },
                                    onFireTapped: {
                                        Task { await collectionFeedVM.fireEntry(entry: entry) }
                                    },
                                    onRemoveFromGroup: {
                                        await collectionFeedVM.removeFromCollection(entryId: entry.id)
                                    }
                                )
                            }
                        }
                        .padding(.bottom, 16)

                        Color.clear
                            .frame(height: 1)
                            .id("collection-feed-bottom")
                    }
                    .defaultScrollAnchor(.top)
                    .onChange(of: collectionFeedVM.entries.count) {
                        if !hasScrolledToBottom && !collectionFeedVM.entries.isEmpty {
                            hasScrolledToBottom = true
                            proxy.scrollTo("collection-feed-bottom", anchor: .bottom)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Style.Color.background)
                .foregroundColor(Style.Color.primaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Style.Color.background)
            .ignoresSafeArea(edges: .top)
        }
        .background(Style.Color.background.ignoresSafeArea())
        // Entry-level action sheet overlay
        .overlay(alignment: .bottom) {
            if activeEntryMenuEntry != nil {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .transaction { $0.animation = nil }
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isEntryActionSheetVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                activeEntryMenuEntry = nil
                            }
                        }

                    if isEntryActionSheetVisible, let sheetEntry = activeEntryMenuEntry {
                        EntryActionSheetView(
                            entry: sheetEntry,
                            onDelete: {
                                Task {
                                    await collectionFeedVM.deleteEntry(id: sheetEntry.id)
                                }
                            },
                            onToggleContentHidden: {
                                Task {
                                    await collectionFeedVM.toggleEntryHidden(
                                        id: sheetEntry.id,
                                        currentValue: sheetEntry.isContentHidden
                                    )
                                }
                            },
                            onBeginTextEdit: {
                                let toEdit = sheetEntry
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    activeEntryMenuEntry = nil
                                    fullScreenEditEntry = toEdit
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isFullScreenEditVisible = true
                                    }
                                }
                            },
                            onRemoveFromGroup: {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    activeEntryMenuEntry = nil
                                    Task {
                                        await collectionFeedVM.removeFromCollection(entryId: sheetEntry.id)
                                    }
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
        // Collection-level action sheet overlay (rename / delete)
        .overlay(alignment: .bottom) {
            if isCollectionActionSheetPresented {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .transaction { $0.animation = nil }
                        .onTapGesture {
                            dismissCollectionActionSheet()
                        }

                    if isCollectionActionSheetVisible {
                        CollectionActionSheetView(
                            onRename: {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isRenameVisible = true
                                    }
                                }
                            },
                            onDelete: {
                                Task {
                                    let ok = await collectionsViewModel.deleteCollection(id: collection.id)
                                    if ok {
                                        dismiss()
                                    } else {
                                        deleteErrorMessage = collectionsViewModel.errorMessage
                                    }
                                }
                            },
                            onDismiss: {
                                dismissCollectionActionSheet()
                            }
                        )
                        .transition(.move(edge: .bottom))
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        // Full-screen edit overlay
        .overlay {
            if isFullScreenEditVisible, let editEntry = fullScreenEditEntry {
                EditEntryFullScreenView(
                    entry: editEntry,
                    initialText: editEntry.content,
                    feedViewModel: collectionFeedVM.feedViewModel,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isFullScreenEditVisible = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            fullScreenEditEntry = nil
                        }
                    },
                    onPersistSuccess: {
                        Task { await collectionFeedVM.loadEntries() }
                    },
                    onSaveSuccess: { updated in
                        collectionFeedVM.entries = collectionFeedVM.entries.map {
                            $0.id == updated.id ? updated : $0
                        }
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
        // Rename collection overlay
        .overlay {
            if isRenameVisible {
                RenameCollectionFullScreenView(
                    collection: Collection(
                        id: collection.id,
                        name: displayedName,
                        updatedAt: collection.updatedAt,
                        itemCount: collection.itemCount
                    ),
                    collectionsViewModel: collectionsViewModel,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isRenameVisible = false
                        }
                    },
                    onSuccess: { newName in
                        displayedName = newName
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .alert("Couldn't delete collection", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            if let deleteErrorMessage {
                Text(deleteErrorMessage)
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            await collectionFeedVM.loadEntries()
        }
    }

    // MARK: - Header

    private var detailHeader: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            ZStack {
                Text(displayedName)
                    .font(.custom("DMSans-Medium", size: 16))
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 80)

                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Text("Back")
                            .font(.custom("DMSans-Regular", size: 16))
                            .foregroundColor(Style.Color.secondary)
                    }

                    Spacer(minLength: 0)

                    Button {
                        isCollectionActionSheetPresented = true
                        withAnimation(.easeOut(duration: 0.25)) {
                            isCollectionActionSheetVisible = true
                        }
                    } label: {
                        Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                            .foregroundColor(Style.Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Style.Spacing.x4)
                .frame(height: 24, alignment: .center)
            }
            .frame(height: 24)

            Color.clear
                .frame(height: 12)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(Style.Color.background)
    }

    private func dismissCollectionActionSheet() {
        withAnimation(.easeOut(duration: 0.25)) {
            isCollectionActionSheetVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isCollectionActionSheetPresented = false
        }
    }
}

// MARK: - Collection Action Sheet

private struct CollectionActionSheetView: View {

    let onRename: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    private let sheetTopCornerRadius: CGFloat = 32
    private let actionRowCornerRadius: CGFloat = 16
    private let actionRowSpacing: CGFloat = 8
    private let sheetPaddingTop: CGFloat = 32
    private let sheetPaddingBottom: CGFloat = 40
    private let sheetPaddingHorizontal: CGFloat = 16
    private let actionRowPaddingVertical: CGFloat = 12
    private let actionRowPaddingHorizontal: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: actionRowSpacing) {
                actionRow(
                    title: "Rename",
                    iconName: "pencil-edit-02",
                    color: Style.Color.primaryText,
                    action: {
                        onRename()
                        onDismiss()
                    }
                )
                actionRow(
                    title: "Delete",
                    iconName: "trash-2",
                    color: Style.Color.destructive,
                    action: {
                        onDelete()
                        onDismiss()
                    }
                )
            }
            .padding(.horizontal, sheetPaddingHorizontal)
            .padding(.top, sheetPaddingTop)
            .padding(.bottom, sheetPaddingBottom)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.background)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: sheetTopCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: sheetTopCornerRadius
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: sheetTopCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: sheetTopCornerRadius
            )
            .stroke(Style.Color.separator, lineWidth: 1)
        )
    }

    private func actionRow(
        title: String,
        iconName: String,
        color: SwiftUI.Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(color)
                    .lineSpacing(24 - 16)
                Spacer(minLength: 0)
                Icon(iconName)
                    .foregroundColor(color)
            }
            .padding(.top, actionRowPaddingVertical)
            .padding(.bottom, actionRowPaddingVertical)
            .padding(.leading, actionRowPaddingHorizontal)
            .padding(.trailing, actionRowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.Color.composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: actionRowCornerRadius))
        }
        .buttonStyle(.plain)
    }
}
