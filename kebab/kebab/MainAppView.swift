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
    @State private var isSettingsOpen: Bool = false
    @State private var isSearchActive: Bool = false
    @State private var addToCollectionEntry: Entry?
    @State private var isAddToCollectionVisible: Bool = false
    // Collections sheet behind the pinned + in the nav bar. Same two-phase
    // pattern as activeEntryMenuEntry / isEntryActionSheetVisible: `presented`
    // mounts the overlay, `visible` animates it.
    @State private var isCollectionsSheetPresented = false
    @State private var isCollectionsSheetVisible = false
    /// Full-screen New Collection creation, entered directly from + while All
    /// is selected (the only relevant action in that state).
    @State private var isNewCollectionVisible = false
    /// Full-screen New Sub-collection, launched from the contextual sheet.
    @State private var newSubParent: Collection?
    @State private var isNewSubVisible = false
    /// Full-screen Rename, launched from the contextual sheet.
    @State private var renameTarget: Collection?
    @State private var isRenameVisible = false
    /// Collection awaiting the descriptive delete confirmation alert.
    @State private var deleteCandidate: Collection?
    // Toggled to true by onSent; the FeedScrollContent child reads and clears it
    // to scroll the feed to the bottom after a new entry appears. Keeping this
    // flag here (not inside FeedScrollContent) lets the onSent closure write it
    // without needing a captured proxy reference.
    @State private var scrollToBottomOnSend = false
    /// Pending entry whose sync permanently failed; drives the Retry/Discard alert.
    @State private var pendingWarningId: UUID?
    @Environment(\.scenePhase) private var scenePhase

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

    /// Where the feed currently is — decides what the Collections sheet offers.
    private var collectionsSheetContext: CollectionsSheetContext {
        switch feedViewModel.activeCollectionFilter {
        case nil:
            return .all
        case .all(let parentId):
            if let parent = collectionsViewModel.collections.first(where: { $0.id == parentId }) {
                return .parent(parent)
            }
            return .all
        case .single(let id):
            if let sub = collectionsViewModel.collections.first(where: { $0.id == id }),
               let parentId = sub.parentId,
               let parent = collectionsViewModel.collections.first(where: { $0.id == parentId }) {
                return .sub(parent: parent, sub: sub)
            }
            return .all
        }
    }

    /// Name of the collection scope the feed is filtered to; nil while on All.
    /// Drives the contextual empty state.
    private var activeScopeName: String? {
        guard let filter = feedViewModel.activeCollectionFilter else { return nil }
        return collectionsViewModel.collections
            .first { $0.id == filter.targetCollectionId }?
            .name
    }

    private func dismissCollectionsSheet() {
        withAnimation(.easeOut(duration: 0.25)) {
            isCollectionsSheetVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isCollectionsSheetPresented = false
        }
    }

    /// Descriptive delete confirmation: says what happens to the entries,
    /// never just "Are you sure?".
    private func deleteMessage(for collection: Collection) -> String {
        if let parentId = collection.parentId,
           let parent = collectionsViewModel.collections.first(where: { $0.id == parentId }) {
            return "Entries in \u{201C}\(collection.name)\u{201D} will move to \u{201C}\(parent.name)\u{201D}."
        }
        let hasSubs = !collectionsViewModel.subCollections(for: collection.id).isEmpty
        return hasSubs
            ? "Its sub-collections will also be deleted. Entries will move to All entries."
            : "Entries will move to All entries."
    }

    private func performDelete(_ collection: Collection) {
        Task {
            let parentId = collection.parentId
            let ok = await collectionsViewModel.deleteCollection(id: collection.id)
            if ok {
                withAnimation(Style.Animation.composerState) {
                    // Deleted sub → land on the parent's aggregate view;
                    // deleted parent → back to All.
                    if let parentId {
                        feedViewModel.activeCollectionFilter = .all(parentId: parentId)
                    } else {
                        feedViewModel.activeCollectionFilter = nil
                    }
                }
                await feedViewModel.loadEntries()
            }
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
                        onSettingsTapped: {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                isSettingsOpen = true
                            }
                        },
                        onSearchTapped: {
                            isSearchActive = true
                        },
                        showsBottomSeparator: false
                    )

                    CollectionNavBarView(
                        parentCollections: collectionsViewModel.parentCollections,
                        subCollections: { collectionsViewModel.subCollections(for: $0) },
                        activeFilter: feedViewModel.activeCollectionFilter,
                        parentIdForCollection: { id in
                            collectionsViewModel.collections.first { $0.id == id }?.parentId
                        },
                        onSelectAll: {
                            withAnimation(Style.Animation.composerState) {
                                feedViewModel.activeCollectionFilter = nil
                            }
                        },
                        onSelectParent: { parent in
                            // Tabs don't toggle: re-tapping the selected parent
                            // stays put (already its aggregate view).
                            withAnimation(Style.Animation.composerState) {
                                feedViewModel.activeCollectionFilter = .all(parentId: parent.id)
                            }
                        },
                        onSelectSub: { sub in
                            // Chips are optional refinements that toggle:
                            // re-tapping the active one returns to the parent
                            // aggregate (no explicit "All" control).
                            withAnimation(Style.Animation.composerState) {
                                if feedViewModel.activeCollectionFilter == .single(id: sub.id),
                                   let parentId = sub.parentId {
                                    feedViewModel.activeCollectionFilter = .all(parentId: parentId)
                                } else {
                                    feedViewModel.activeCollectionFilter = .single(id: sub.id)
                                }
                            }
                        },
                        onPlusTapped: {
                            // From All the only relevant action is creating a
                            // collection — go straight to the full-screen flow.
                            if case .all = collectionsSheetContext {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isNewCollectionVisible = true
                                }
                            } else {
                                isCollectionsSheetPresented = true
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isCollectionsSheetVisible = true
                                }
                            }
                        }
                    )

                    // Feed — isolated into its own child so that
                    // onScrollGeometryChange state updates don't re-render
                    // MainAppView (and therefore don't churn the composer).
                    FeedScrollContent(
                        feedViewModel: feedViewModel,
                        containerHeight: geometry.size.height,
                        emptyScopeName: activeScopeName,
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
                        },
                        onPendingWarningTapped: { entry in
                            pendingWarningId = entry.id
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .background(Style.Color.background)
                    .foregroundColor(Style.Color.primaryText)
                    .task {
                        Haptics.prepare()
                        // Pending (outbox) entries filed into a sub-collection
                        // must match the parent's aggregate filter too.
                        feedViewModel.collectionParentResolver = { [weak collectionsViewModel] id in
                            collectionsViewModel?.collections.first { $0.id == id }?.parentId
                        }
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
                // Left-edge swipe opens settings ("swipe between screens"),
                // via a window-level UIScreenEdgePanGestureRecognizer so feed
                // scrolling stays fully native — see EdgeSwipeRecognizer.
                .background(
                    EdgeSwipeRecognizer(
                        canBegin: {
                            !isSettingsOpen
                                && activeEntryMenuEntry == nil
                                && !isCollectionsSheetPresented
                                && !isNewCollectionVisible
                                && !isNewSubVisible
                                && !isRenameVisible
                                && deleteCandidate == nil
                                && !isFullScreenEditVisible
                                && !isAddToCollectionVisible
                                // On pushed screens the left edge means "back".
                                && (PopGestureDelegate.shared.navigationController?.viewControllers.count ?? 1) <= 1
                        },
                        onSwipe: {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                isSettingsOpen = true
                            }
                        }
                    )
                )
                .safeAreaInset(edge: .bottom) {
                    if !isSettingsOpen {
                        // Collection navigation moved to the top nav bar; the
                        // area above the composer stays free for the Tier III
                        // post-capture actions.
                        VStack(spacing: 0) {
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
                                    // Queue-then-flush: the entry appears immediately with a
                                    // pending mark and syncs whenever connectivity allows.
                                    let queued = feedViewModel.queueEntry(
                                        content: content,
                                        images: images.map(\.image),
                                        collectionId: targetId
                                    )
                                    if !queued {
                                        // Outbox write failed (disk full) — restore the draft.
                                        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            composerText = content
                                        }
                                        if composerImages.isEmpty {
                                            composerImages = images
                                        }
                                        Haptics.destructiveTap()
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
                // Leftward swipe anywhere on settings slides back to the feed.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            guard isSettingsOpen else { return }
                            let t = value.translation
                            if t.width < -60, abs(t.width) > abs(t.height) {
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    isSettingsOpen = false
                                }
                            }
                        }
                )
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
            // Collections sheet behind the nav bar's pinned +: creation is
            // relative to the current parent scope, management applies to the
            // deepest selected location.
            .overlay(alignment: .bottom) {
                if isCollectionsSheetPresented {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .transaction { $0.animation = nil }
                            .onTapGesture { dismissCollectionsSheet() }

                        if isCollectionsSheetVisible {
                            let context = collectionsSheetContext
                            CollectionsSheetView(
                                context: context,
                                onNewSubCollection: {
                                    // The sheet only launches actions —
                                    // naming happens on the shared
                                    // full-screen surface.
                                    guard let parent = context.parent else { return }
                                    dismissCollectionsSheet()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        newSubParent = parent
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isNewSubVisible = true
                                        }
                                    }
                                },
                                onRename: {
                                    guard let managed = context.managed else { return }
                                    dismissCollectionsSheet()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        renameTarget = managed
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isRenameVisible = true
                                        }
                                    }
                                },
                                onRequestDelete: {
                                    guard let managed = context.managed else { return }
                                    dismissCollectionsSheet()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        deleteCandidate = managed
                                    }
                                },
                                onDismiss: { dismissCollectionsSheet() }
                            )
                            .transition(.move(edge: .bottom))
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            // Full-screen New Collection creation, entered directly from +
            // while All is selected — same presentation as full-screen entry
            // editing, a deliberate creation surface rather than a sheet.
            .overlay {
                if isNewCollectionVisible {
                    NewCollectionFullScreenView(
                        collectionsViewModel: collectionsViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isNewCollectionVisible = false
                            }
                        },
                        onSuccess: { created in
                            // A new collection is a real place: navigate
                            // straight into its (empty) view.
                            withAnimation(Style.Animation.composerState) {
                                feedViewModel.activeCollectionFilter = .all(parentId: created.id)
                            }
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            // Full-screen New Sub-collection launched from the contextual sheet.
            .overlay {
                if isNewSubVisible, let parent = newSubParent {
                    NewCollectionFullScreenView(
                        collectionsViewModel: collectionsViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isNewSubVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                newSubParent = nil
                            }
                        },
                        title: "New sub-collection",
                        parentId: parent.id,
                        existingSiblingNames: collectionsViewModel.subCollections(for: parent.id).map { $0.name },
                        onSuccess: { created in
                            withAnimation(Style.Animation.composerState) {
                                feedViewModel.activeCollectionFilter = .single(id: created.id)
                            }
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            // Full-screen Rename launched from the contextual sheet, with the
            // existing name prefilled.
            .overlay {
                if isRenameVisible, let target = renameTarget {
                    NewCollectionFullScreenView(
                        collectionsViewModel: collectionsViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isRenameVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                renameTarget = nil
                            }
                        },
                        title: target.parentId == nil ? "Rename collection" : "Rename sub-collection",
                        existingSiblingNames: target.parentId == nil ? [] :
                            collectionsViewModel.collections
                                .filter { $0.parentId == target.parentId && $0.id != target.id }
                                .map { $0.name },
                        renameTarget: target,
                        onSuccess: { _ in
                            // Refresh breadcrumb names in the feed.
                            Task { await feedViewModel.loadEntries() }
                        }
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
            // Returning to the foreground is a natural moment to drain the outbox.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    feedViewModel.kickFlush()
                }
            }
            .alert("Entry couldn\u{2019}t sync", isPresented: Binding(
                get: { pendingWarningId != nil },
                set: { if !$0 { pendingWarningId = nil } }
            )) {
                Button("Try again") {
                    if let id = pendingWarningId {
                        feedViewModel.retryPending(id: id)
                    }
                    pendingWarningId = nil
                }
                Button("Discard entry", role: .destructive) {
                    if let id = pendingWarningId {
                        feedViewModel.discardPending(id: id)
                    }
                    pendingWarningId = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingWarningId = nil
                }
            } message: {
                Text("This entry is saved on your phone, but the server rejected it. You can retry or discard it.")
            }
            // Destructive confirmation describes what happens to the entries —
            // structure is disposable, entries never are.
            .alert(
                "Delete \u{201C}\(deleteCandidate?.name ?? "")\u{201D}?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let candidate = deleteCandidate {
                        performDelete(candidate)
                    }
                    deleteCandidate = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteCandidate = nil
                }
            } message: {
                if let candidate = deleteCandidate {
                    Text(deleteMessage(for: candidate))
                }
            }
        }
        }
        // Shared collections model for every screen in this stack (including
        // pushed destinations and overlays) — the Add-to-collection picker
        // renders instantly from it instead of refetching on every open.
        .environmentObject(collectionsViewModel)
    }
}

// MARK: - FeedScrollContent

// Owns scrollDistanceFromBottom and hasScrolledToBottom so that the high-frequency
// onScrollGeometryChange updates re-render only this view — not MainAppView and not
// the ComposerView subtree in MainAppView's safeAreaInset.
private struct FeedScrollContent: View {

    @ObservedObject var feedViewModel: FeedViewModel
    let containerHeight: CGFloat
    /// Name of the filtered collection scope (nil while on All). An empty
    /// scoped feed gets a restrained one-liner; an empty All feed gets the
    /// first-use state.
    let emptyScopeName: String?
    @Binding var scrollToBottomOnSend: Bool
    let onMoreTapped: (Entry) -> Void
    let onResurfaceTapped: (Entry) -> Void
    let onPinTapped: (Entry) -> Void
    let onFireTapped: (Entry) -> Void
    let onPendingWarningTapped: (Entry) -> Void

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
                    if let scopeName = emptyScopeName {
                        // An empty collection is a valid destination, not an
                        // error — one quiet line, composer stays the action.
                        Text("Nothing in \(scopeName) yet.")
                            .font(Style.Typography.meta())
                            .foregroundColor(Style.Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Style.Spacing.emptyStateMargin)
                    } else {
                        EmptyStateView(
                            iconName: "bookmark-02",
                            title: "Save it here",
                            primaryBody: "Kebab is a micro journal for thoughts, links, and things you don't want to lose.\n\nLike a sticky note you'll come back to.",
                            secondaryBody: "Recipes, quotes, ideas, movies to watch, random thoughts that come to you at 3am."
                        )
                        .padding(Style.Spacing.emptyStateMargin)
                    }
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
                            }, onPendingWarningTapped: {
                                onPendingWarningTapped(entry)
                            })
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .id("feed-bottom")
            }
            .scrollDismissesKeyboard(.interactively)
            // Cached feed is present before the first layout — anchor at the
            // newest entry on appear (onChange won't fire without a count change).
            .onAppear {
                if !hasScrolledToBottom && feedViewModel.totalDisplayCount > 0 {
                    hasScrolledToBottom = true
                    scrollToBottom(proxy)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        fabEnabled = true
                    }
                }
            }
            .onChange(of: feedViewModel.totalDisplayCount) {
                if !hasScrolledToBottom && feedViewModel.totalDisplayCount > 0 {
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
