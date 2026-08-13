import SwiftUI
import Supabase

struct MainAppView: View {

    /// UserDefaults key backing the feed composer draft, so an in-progress
    /// message survives app termination and failed sends.
    private static let feedDraftKey = "composer.draft.feed"

    private let supabase: SupabaseClient
    @StateObject private var feedViewModel: FeedViewModel
    @StateObject private var collectionsViewModel: CollectionsViewModel
    @State private var composerText: String =
        UserDefaults.standard.string(forKey: MainAppView.feedDraftKey) ?? ""
    /// Images staged in the feed composer (in-memory only; restored on failed send).
    @State private var composerImages: [PendingImage] = []
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false
    @State private var selectedTab: StickyHeaderView.Tab = .feed
    @State private var isSettingsOpen: Bool = false
    @State private var isSearchActive: Bool = false
    @State private var isNewCollectionVisible: Bool = false
    @State private var addToCollectionEntry: Entry?
    @State private var isAddToCollectionVisible: Bool = false
    // Chip-sheet presentation (parent-collection chip with sub-collections).
    // Same two-phase pattern as activeEntryMenuEntry / isEntryActionSheetVisible.
    @State private var chipSheetParent: Collection?
    @State private var isChipSheetVisible = false
    // Rename/delete action sheet reached via the chip sheet's ellipsis.
    @State private var chipManageParent: Collection?
    @State private var isChipManageVisible = false
    // Overlays launched from the chip sheet.
    @State private var renameChipCollection: Collection?
    @State private var isRenameChipVisible = false
    @State private var newSubChipParent: Collection?
    @State private var isNewSubChipVisible = false
    // Toggled to true by onSent; the FeedScrollContent child reads and clears it
    // to scroll the feed to the bottom after a new entry appears. Keeping this
    // flag here (not inside FeedScrollContent) lets the onSent closure write it
    // without needing a captured proxy reference.
    @State private var scrollToBottomOnSend = false

    let authViewModel: AuthViewModel

    init(supabase: SupabaseClient, authViewModel: AuthViewModel) {
        self.supabase = supabase
        _feedViewModel = StateObject(wrappedValue: FeedViewModel(supabase: supabase))
        _collectionsViewModel = StateObject(wrappedValue: CollectionsViewModel(supabase: supabase))
        self.authViewModel = authViewModel
    }

    /// "Add to <collection>" while a collection filter targets the composer.
    private var composerPlaceholder: String {
        guard let filter = feedViewModel.activeCollectionFilter,
              let target = collectionsViewModel.collections.first(where: {
                  $0.id == filter.targetCollectionId
              })
        else { return "Make an entry" }
        return "Add to \(target.name)"
    }

    private func dismissChipSheet() {
        withAnimation(.easeOut(duration: 0.25)) {
            isChipSheetVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            chipSheetParent = nil
        }
    }

    private func dismissChipManageSheet() {
        withAnimation(.easeOut(duration: 0.25)) {
            isChipManageVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            chipManageParent = nil
        }
    }

    var body: some View {
        NavigationStack {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Style.Color.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    StickyHeaderView(
                        selectedTab: $selectedTab,
                        onSettingsTapped: {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                isSettingsOpen = true
                            }
                        },
                        onSearchTapped: {
                            isSearchActive = true
                        }
                    )

                    ZStack {
                        // Feed tab — isolated into its own child so that
                        // onScrollGeometryChange state updates don't re-render
                        // MainAppView (and therefore don't churn the composer).
                        FeedScrollContent(
                            feedViewModel: feedViewModel,
                            selectedTab: selectedTab,
                            containerHeight: geometry.size.height,
                            scrollToBottomOnSend: $scrollToBottomOnSend,
                            onMoreTapped: { entry in
                                activeEntryMenuEntry = entry
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = true
                                }
                            },
                            onResurfaceTapped: { entry in
                                Task { await feedViewModel.resurfaceEntry(entry: entry) }
                            },
                            onPinTapped: { entry in
                                Task { await feedViewModel.togglePin(entry: entry) }
                            },
                            onFireTapped: { entry in
                                Task { await feedViewModel.fireEntry(entry: entry) }
                            }
                        )

                        CollectionsView(
                            collectionsViewModel: collectionsViewModel,
                            feedViewModel: feedViewModel,
                            supabase: supabase,
                            onNewCollectionTapped: {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isNewCollectionVisible = true
                                }
                            }
                        )
                        .opacity(selectedTab == .collections ? 1 : 0)
                        .allowsHitTesting(selectedTab == .collections)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Style.Color.background)
                    .foregroundColor(Style.Color.primaryText)
                    .task {
                        Haptics.prepare()
                        await feedViewModel.loadEntries()
                        await collectionsViewModel.loadCollections()
                    }
                }
                .ignoresSafeArea(edges: .top)
                // Keep the same modifier node in the tree at all times - only the edges parameter changes.
                // A @ViewBuilder conditional (the prior attempt) changed the view type on toggle, causing
                // SwiftUI to destroy and recreate the ScrollView and reset its offset to zero. A stable
                // node with edges: [] (semantic no-op) vs edges: .bottom is a parameter update, not a
                // type change, so the ScrollView position survives both open and close.
                .ignoresSafeArea(.keyboard, edges: isFullScreenEditVisible ? .bottom : [])
                .safeAreaInset(edge: .bottom) {
                    if !isSettingsOpen && selectedTab == .feed {
                        VStack(spacing: 0) {
                            ChipFilterBarView(
                                parentCollections: collectionsViewModel.parentCollections,
                                subCollections: { collectionsViewModel.subCollections(for: $0) },
                                hasLinkActive: feedViewModel.hasLinkFilterActive,
                                activeCollectionFilter: feedViewModel.activeCollectionFilter,
                                onToggleHasLink: {
                                    withAnimation(Style.Animation.composerState) {
                                        feedViewModel.hasLinkFilterActive.toggle()
                                    }
                                },
                                onParentTapped: { parent in
                                    if collectionsViewModel.subCollections(for: parent.id).isEmpty {
                                        withAnimation(Style.Animation.composerState) {
                                            feedViewModel.toggleCollectionFilter(.all(parentId: parent.id))
                                        }
                                    } else {
                                        chipSheetParent = parent
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isChipSheetVisible = true
                                        }
                                    }
                                },
                                onClearCollectionFilter: {
                                    withAnimation(Style.Animation.composerState) {
                                        feedViewModel.activeCollectionFilter = nil
                                    }
                                }
                            )
                            .padding(.bottom, 8)

                            ComposerView(
                                text: $composerText,
                                maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                                placeholder: composerPlaceholder,
                                allowsAttachments: true,
                                attachedImages: $composerImages,
                                onSent: { content in
                                    scrollToBottomOnSend = true
                                    // Active collection filter targets the composer: the new
                                    // entry lands in the filtered collection.
                                    let targetId = feedViewModel.activeCollectionFilter?.targetCollectionId
                                    let images = composerImages
                                    composerImages = []
                                    Task {
                                        let sent = await feedViewModel.sendEntry(
                                            content: content,
                                            images: images.map(\.image),
                                            collectionId: targetId
                                        )
                                        if sent, targetId != nil {
                                            // Refresh item counts shown in the chip sheet.
                                            await collectionsViewModel.loadCollections()
                                        }
                                        if !sent {
                                            // Restore the draft so a failed send never destroys
                                            // composed content — but only into an empty composer,
                                            // so a message the user has already started isn't stomped.
                                            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                composerText = content
                                            }
                                            if composerImages.isEmpty {
                                                composerImages = images
                                            }
                                            Haptics.destructiveTap()
                                        }
                                    }
                                },
                                onFocus: { }
                            )
                        }
                        // No opaque fill: the chips and glass composer float over
                        // the feed, which scrolls visibly behind them. A soft
                        // fade keeps the very bottom edge legible.
                        .background(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Style.Color.background.opacity(0), location: 0),
                                    .init(color: Style.Color.background.opacity(0.85), location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .ignoresSafeArea(edges: .bottom)
                        )
                    } else {
                        EmptyView()
                    }
                }

                SettingsView(
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            isSettingsOpen = false
                        }
                    },
                    authViewModel: authViewModel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: isSettingsOpen ? 0 : -UIScreen.main.bounds.width)
                .animation(.easeInOut(duration: 0.28), value: isSettingsOpen)
            }
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
                                onDelete: {
                                    Task { await feedViewModel.deleteEntry(id: entry.id) }
                                },
                                onToggleContentHidden: {
                                    Task {
                                        await feedViewModel.toggleEntryHidden(
                                            id: entry.id,
                                            currentValue: entry.isContentHidden
                                        )
                                    }
                                },
                                onBeginTextEdit: {
                                    let toEdit = entry
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
                                onAddToCollection: {
                                    let toAdd = entry
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isEntryActionSheetVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        activeEntryMenuEntry = nil
                                        addToCollectionEntry = toAdd
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isAddToCollectionVisible = true
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
            .overlay {
                if isFullScreenEditVisible, let editEntry = fullScreenEditEntry {
                    EditEntryFullScreenView(
                        entry: editEntry,
                        initialText: editEntry.content,
                        feedViewModel: feedViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isFullScreenEditVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                fullScreenEditEntry = nil
                                // Full authoritative reload runs after the overlay is completely gone and
                                // the keyboard is dismissed, so no overlay or keyboard layout pressure
                                // is active when entries refreshes. The local patch in updateEntryContent
                                // already has the correct content, so this reload produces no diff visible
                                // to the user (same order, same text) and does not shift scroll position.
                                Task { await feedViewModel.loadEntries() }
                            }
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .overlay {
                if isNewCollectionVisible {
                    NewCollectionFullScreenView(
                        collectionsViewModel: collectionsViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isNewCollectionVisible = false
                            }
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .overlay {
                if isAddToCollectionVisible, let entry = addToCollectionEntry {
                    AddToCollectionFullScreenView(
                        entry: entry,
                        supabase: supabase,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isAddToCollectionVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                addToCollectionEntry = nil
                            }
                        },
                        onSuccess: {
                            Task {
                                await collectionsViewModel.loadCollections()
                                await feedViewModel.loadEntries()
                            }
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            // Chip sheet: filter targets + collection management for a parent chip.
            .overlay(alignment: .bottom) {
                if let parent = chipSheetParent {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .transaction { $0.animation = nil }
                            .onTapGesture { dismissChipSheet() }

                        if isChipSheetVisible {
                            CollectionChipSheetView(
                                parent: parent,
                                subCollections: collectionsViewModel.subCollections(for: parent.id),
                                activeFilter: feedViewModel.activeCollectionFilter,
                                onSelectAll: {
                                    feedViewModel.toggleCollectionFilter(.all(parentId: parent.id))
                                    dismissChipSheet()
                                },
                                onSelectSub: { sub in
                                    feedViewModel.toggleCollectionFilter(.single(id: sub.id))
                                    dismissChipSheet()
                                },
                                onNewSubCollection: {
                                    dismissChipSheet()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        newSubChipParent = parent
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isNewSubChipVisible = true
                                        }
                                    }
                                },
                                onManage: {
                                    dismissChipSheet()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        chipManageParent = parent
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isChipManageVisible = true
                                        }
                                    }
                                },
                                onDismiss: { dismissChipSheet() }
                            )
                            .transition(.move(edge: .bottom))
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            // Rename/delete action sheet reached via the chip sheet's ellipsis.
            .overlay(alignment: .bottom) {
                if let parent = chipManageParent {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .transaction { $0.animation = nil }
                            .onTapGesture { dismissChipManageSheet() }

                        if isChipManageVisible {
                            CollectionActionSheetView(
                                onRename: {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        renameChipCollection = parent
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isRenameChipVisible = true
                                        }
                                    }
                                },
                                onDelete: {
                                    Task {
                                        let ok = await collectionsViewModel.deleteCollection(id: parent.id)
                                        if ok {
                                            // Drop the filter if its target no longer exists
                                            // (deleteCollection already reloaded collections).
                                            if let filter = feedViewModel.activeCollectionFilter,
                                               !collectionsViewModel.collections.contains(where: {
                                                   $0.id == filter.targetCollectionId
                                               }) {
                                                feedViewModel.activeCollectionFilter = nil
                                            }
                                            await feedViewModel.loadEntries()
                                        }
                                    }
                                },
                                onDismiss: { dismissChipManageSheet() }
                            )
                            .transition(.move(edge: .bottom))
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            // Rename overlay launched from the chip sheet.
            .overlay {
                if isRenameChipVisible, let collection = renameChipCollection {
                    RenameCollectionFullScreenView(
                        collection: collection,
                        collectionsViewModel: collectionsViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isRenameChipVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                renameChipCollection = nil
                            }
                        },
                        onSuccess: { _ in
                            // Refresh breadcrumb names in the feed.
                            Task { await feedViewModel.loadEntries() }
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            // New sub-collection overlay launched from the chip sheet.
            .overlay {
                if isNewSubChipVisible, let parent = newSubChipParent {
                    NewCollectionFullScreenView(
                        collectionsViewModel: collectionsViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isNewSubChipVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                newSubChipParent = nil
                            }
                        },
                        title: "New sub-collection",
                        parentId: parent.id,
                        existingSiblingNames: collectionsViewModel.subCollections(for: parent.id).map { $0.name }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .navigationDestination(isPresented: $isSearchActive) {
                if let userId = authViewModel.currentUserId {
                    SearchView(supabase: supabase, feedViewModel: feedViewModel, userId: userId)
                }
            }
            .onChange(of: composerText) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: Self.feedDraftKey)
            }
        }
        }
    }
}

// MARK: - FeedScrollContent

// Owns scrollDistanceFromBottom and hasScrolledToBottom so that the high-frequency
// onScrollGeometryChange updates re-render only this view — not MainAppView and not
// the ComposerView subtree in MainAppView's safeAreaInset.
private struct FeedScrollContent: View {

    @ObservedObject var feedViewModel: FeedViewModel
    let selectedTab: StickyHeaderView.Tab
    let containerHeight: CGFloat
    @Binding var scrollToBottomOnSend: Bool
    let onMoreTapped: (Entry) -> Void
    let onResurfaceTapped: (Entry) -> Void
    let onPinTapped: (Entry) -> Void
    let onFireTapped: (Entry) -> Void

    @State private var scrollDistanceFromBottom: CGFloat = 0
    @State private var hasScrolledToBottom = false
    /// Guards the FAB against the initial-load blink: set to true only after the
    /// programmatic scroll-to-bottom has had time to update the scroll geometry,
    /// so scrollDistanceFromBottom is already near 0 before FAB can evaluate.
    @State private var fabEnabled = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if feedViewModel.hasCompletedInitialLoad && feedViewModel.filteredFeedEntries.isEmpty {
                    EmptyStateView(
                        iconName: "bookmark-02",
                        title: "Save it here",
                        primaryBody: "Kebab is a micro journal for thoughts, links, and things you don't want to lose.\n\nLike a sticky note you'll come back to.",
                        secondaryBody: "Recipes, quotes, ideas, movies to watch, random thoughts that come to you at 3am."
                    )
                    .padding(Style.Spacing.emptyStateMargin)
                }
                let entries = feedViewModel.filteredFeedEntries
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        EntryRowView(
                            entry: entry,
                            feedViewModel: feedViewModel,
                            // Newest entry sits flush above the composer — no bottom
                            // hairline — unless it's the only entry (top of screen).
                            showBottomSeparator: entry.id != entries.last?.id || entries.count == 1,
                            onMoreTapped: {
                                onMoreTapped(entry)
                            }, onResurfaceTapped: {
                                onResurfaceTapped(entry)
                            }, onPinTapped: {
                                onPinTapped(entry)
                            }, onFireTapped: {
                                onFireTapped(entry)
                            })
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .id("feed-bottom")
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: feedViewModel.entries.count) {
                if !hasScrolledToBottom && !feedViewModel.entries.isEmpty {
                    hasScrolledToBottom = true
                    scrollToBottom(proxy)
                    // Delay FAB eligibility past the settle pass so the scroll
                    // geometry is final, preventing the one-frame blink where
                    // scrollDistanceFromBottom is still large.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        fabEnabled = true
                    }
                } else if scrollToBottomOnSend {
                    scrollToBottomOnSend = false
                    scrollToBottom(proxy)
                }
            }
            // Any filter change (select, switch, or clear) re-anchors the feed at
            // the newest entry — never leaves the user stranded mid-history.
            .onChange(of: feedViewModel.activeCollectionFilter) { _, _ in
                DispatchQueue.main.async { scrollToBottom(proxy) }
            }
            .onChange(of: feedViewModel.hasLinkFilterActive) { _, _ in
                DispatchQueue.main.async { scrollToBottom(proxy) }
            }
            .onScrollGeometryChange(for: CGFloat.self) { g in
                max(0, g.contentSize.height - g.contentOffset.y - g.containerSize.height)
            } action: { _, newValue in
                scrollDistanceFromBottom = newValue
            }
            .overlay(alignment: .bottom) {
                let shouldShow = fabEnabled
                    && selectedTab == .feed
                    && scrollDistanceFromBottom > containerHeight
                Group {
                    if shouldShow {
                        Icon("arrow-up")
                            .rotationEffect(.degrees(180))
                            .foregroundColor(Style.Color.primaryText)
                            .frame(width: 36, height: 36)
                            .glassEffect(
                                .regular.tint(Style.Color.composerBackground.opacity(0.5)),
                                in: Circle()
                            )
                            .contentShape(Circle())
                        .simultaneousGesture(TapGesture().onEnded {
                            Haptics.lightTap()
                            proxy.scrollTo("feed-bottom", anchor: .bottom)
                        })
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: shouldShow)
            }
        }
        .opacity(selectedTab == .feed ? 1 : 0)
        .allowsHitTesting(selectedTab == .feed)
    }

    /// Scrolls to the newest entry, then runs a settle pass. The first scroll
    /// lands on LazyVStack's *estimated* row heights; once real rows materialize
    /// the content is slightly taller and the newest entry ends up tucked under
    /// the composer. The follow-up scroll corrects the residual offset.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("feed-bottom", anchor: .bottom)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            proxy.scrollTo("feed-bottom", anchor: .bottom)
        }
    }
}


#Preview {
    MainAppView(
        supabase: SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "key"
        ),
        authViewModel: AuthViewModel(supabase: SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "key"
        ))
    )
}
