import SwiftUI
import Supabase

struct CollectionDetailView: View {

    let collection: Collection
    @ObservedObject var collectionsViewModel: CollectionsViewModel
    private let supabase: SupabaseClient

    @StateObject private var collectionFeedVM: CollectionFeedViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var displayedName: String

    // Sub-collection strip (parent context only)
    /// Total fixed height reserved in layout for the strip (content + 1pt separator).
    /// This must NEVER change at runtime — layout stability is what prevents scroll feedback.
    private let stripTotalHeight: CGFloat = 100
    /// Width of the "New sub-collection" action slot. Referenced by both the tile
    /// and the empty-state geometry calculation so both stay in sync.
    private let newSubTileWidth: CGFloat = 110
    @State private var stripVisible = true
    /// The content offset observed during the previous `onScrollGeometryChange` event.
    /// Subtracted from the current offset to get the per-event delta, which drives
    /// hide (delta > threshold, scrolling toward top of feed) and reveal
    /// (delta < -threshold, scrolling back down). Always updated on every event so the
    /// baseline is never anchored at a stale position after a programmatic scroll.
    @State private var stripLastOffset: CGFloat = 0
    /// True while a programmatic scroll-to-bottom is in flight.
    /// Prevents the large initial content-offset jump from being treated as a user
    /// scroll and hiding the strip before any real interaction has occurred.
    @State private var scrollingProgrammatically = false
    @State private var isNewSubVisible = false
    @State private var scrollToSubId: UUID? = nil

    // Collection-level action sheet (rename / delete)
    @State private var isCollectionActionSheetPresented = false
    @State private var isCollectionActionSheetVisible = false
    @State private var isRenameVisible = false
    @State private var deleteErrorMessage: String?

    // Entry-level action sheet
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false

    // Full-screen edit overlay
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false

    // Move-entry overlay (collection/sub-collection context only)
    @State private var moveEntryEntry: Entry?
    @State private var isMoveEntryVisible = false

    // Composer state
    @State private var composerText: String = ""
    @State private var scrollToBottomOnSend = false

    // Scroll-to-bottom control
    @State private var hasScrolledToBottom = false

    // MARK: - Derived

    /// True when this screen is displaying a sub-collection.
    private var isSubCollection: Bool { collection.parentId != nil }

    /// Child sub-collections of this parent, sorted alphabetically.
    private var currentSubCollections: [Collection] {
        collectionsViewModel.subCollections(for: collection.id)
    }

    /// Sibling sub-collection names (excluding self) for rename duplicate validation.
    private var siblingSubNames: [String] {
        collectionsViewModel.collections
            .filter { $0.parentId == collection.parentId && $0.id != collection.id }
            .map { $0.name }
    }

    // MARK: - Init

    init(
        collection: Collection,
        collectionsViewModel: CollectionsViewModel,
        feedViewModel: FeedViewModel,
        supabase: SupabaseClient
    ) {
        self.collection = collection
        self.collectionsViewModel = collectionsViewModel
        self.supabase = supabase
        _displayedName = State(initialValue: collection.name)
        _collectionFeedVM = StateObject(wrappedValue: CollectionFeedViewModel(
            collection: collection,
            supabase: supabase,
            feedViewModel: feedViewModel,
            collectionsViewModel: collectionsViewModel
        ))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                detailHeader

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Fixed spacer reserves the strip overlay's footprint at the
                            // top of scroll content. Its height never changes — no layout
                            // shift when the strip shows or hides.
                            if !isSubCollection {
                                Color.clear.frame(height: stripTotalHeight)
                            }
                            if collectionFeedVM.hasCompletedInitialLoad
                                && collectionFeedVM.entries.isEmpty
                            {
                                if isSubCollection {
                                    EmptyStateView(
                                        iconName: "folder",
                                        title: "No entries yet",
                                        primaryBody: "New entries typed below are added to this sub-collection.",
                                        secondaryBody: "You can also move entries here using the ••• menu on any entry."
                                    )
                                    .padding(Style.Spacing.emptyStateMargin)
                                } else {
                                    EmptyStateView(
                                        iconName: "folder",
                                        title: "No entries yet",
                                        primaryBody: "New entries typed below are added to this collection.",
                                        secondaryBody: "You can also move entries here using the ••• menu on any entry."
                                    )
                                    .padding(Style.Spacing.emptyStateMargin)
                                }
                            }

                            ForEach(collectionFeedVM.entries) { entry in
                                EntryRowView(
                                    entry: entry,
                                    feedViewModel: collectionFeedVM.feedViewModel,
                                    showResurface: false,
                                    showBreadcrumb: false,
                                    onMoreTapped: {
                                        activeEntryMenuEntry = entry
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isEntryActionSheetVisible = true
                                        }
                                    },
                                    onFireTapped: {
                                        Task { await collectionFeedVM.fireEntry(entry: entry) }
                                    },
                                    onRemoveFromCollection: {
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
                    .onScrollGeometryChange(for: CGFloat.self) { g in
                        g.contentOffset.y
                    } action: { _, new in
                        guard !isSubCollection else { return }
                        // During a programmatic scroll, just track the offset so the
                        // per-event baseline is correct once the user takes over.
                        defer { stripLastOffset = new }
                        guard !scrollingProgrammatically else { return }

                        // Entries are ordered oldest-at-top / newest-at-bottom.
                        // After load the view is scrolled to the bottom (high offset).
                        //   Swipe DOWN (browse older) → contentOffset.y DECREASES → delta < 0 → hide
                        //   Swipe UP  (back to newer) → contentOffset.y INCREASES → delta > 0 → reveal
                        let delta = new - stripLastOffset

                        // Guard new > stripTotalHeight so the strip only hides after the
                        // fixed content spacer has scrolled fully past — no gap is left.
                        if delta < -5 && new > stripTotalHeight && stripVisible {
                            withAnimation(.easeOut(duration: 0.2)) { stripVisible = false }
                        } else if delta > 5 && !stripVisible {
                            withAnimation(.easeOut(duration: 0.2)) { stripVisible = true }
                        }
                    }
                    .onChange(of: collectionFeedVM.entries.count) {
                        if !hasScrolledToBottom && !collectionFeedVM.entries.isEmpty {
                            hasScrolledToBottom = true
                            scrollingProgrammatically = true
                            proxy.scrollTo("collection-feed-bottom", anchor: .bottom)
                            // Give the scroll animation time to settle before re-enabling
                            // strip hide/show decisions from real user interactions.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                scrollingProgrammatically = false
                            }
                        } else if scrollToBottomOnSend {
                            scrollToBottomOnSend = false
                            proxy.scrollTo("collection-feed-bottom", anchor: .bottom)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Style.Color.background)
                .foregroundColor(Style.Color.primaryText)
                .overlay(alignment: .top) {
                    if !isSubCollection {
                        // Strip overlays the top of the scroll area. Its explicit background
                        // covers scroll content when visible. When hidden, it offsets upward;
                        // .clipped() below prevents it bleeding into the header above.
                        // .allowsHitTesting guards against the offset hit-test frame
                        // (which moves with the visual offset) intercepting taps in the
                        // header region while the strip is tucked away.
                        subCollectionStripSection
                            .background(Style.Color.background)
                            .frame(height: stripTotalHeight)
                            .offset(y: stripVisible ? 0 : -stripTotalHeight)
                            .animation(.easeOut(duration: 0.2), value: stripVisible)
                            .allowsHitTesting(stripVisible)
                    }
                }
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Style.Color.background)
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .bottom) {
                ComposerView(
                    text: $composerText,
                    maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                    placeholder: "Add entry",
                    onSent: { content in
                        scrollToBottomOnSend = true
                        Task {
                            let sent = await collectionFeedVM.sendEntry(content: content)
                            if !sent {
                                // Restore the draft so a failed send never destroys typed
                                // text — only into an empty composer.
                                if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    composerText = content
                                }
                                Haptics.destructiveTap()
                            }
                        }
                    },
                    onFocus: { }
                )
            }
        }
        .background(Style.Color.background.ignoresSafeArea())
        // Entry-level action sheet
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
                                Task { await collectionFeedVM.deleteEntry(id: sheetEntry.id) }
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
                            onMoveEntry: {
                                let toMove = sheetEntry
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    activeEntryMenuEntry = nil
                                    moveEntryEntry = toMove
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isMoveEntryVisible = true
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
        // Collection-level action sheet (rename / delete)
        .overlay(alignment: .bottom) {
            if isCollectionActionSheetPresented {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .transaction { $0.animation = nil }
                        .onTapGesture { dismissCollectionActionSheet() }

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
                            onDismiss: { dismissCollectionActionSheet() }
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
                        parentId: collection.parentId,
                        updatedAt: collection.updatedAt,
                        itemCount: collection.itemCount
                    ),
                    collectionsViewModel: collectionsViewModel,
                    existingSiblingNames: isSubCollection ? siblingSubNames : [],
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
        // New sub-collection overlay
        .overlay {
            if isNewSubVisible {
                NewCollectionFullScreenView(
                    collectionsViewModel: collectionsViewModel,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isNewSubVisible = false
                        }
                    },
                    title: "New sub-collection",
                    parentId: collection.id,
                    existingSiblingNames: currentSubCollections.map { $0.name },
                    onSuccess: { created in
                        // Scroll to the newly created tile after collections reload.
                        scrollToSubId = created.id
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
        // Move-entry overlay
        .overlay {
            if isMoveEntryVisible, let entry = moveEntryEntry {
                AddToCollectionFullScreenView(
                    entry: entry,
                    title: "Move entry",
                    supabase: supabase,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isMoveEntryVisible = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            moveEntryEntry = nil
                        }
                    },
                    onSuccess: {
                        Task {
                            await collectionFeedVM.loadEntries()
                            await collectionsViewModel.loadCollections()
                        }
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
        .onAppear {
            // Reload entries whenever this screen comes back into focus (e.g. after sub-collection
            // delete, which moves entries to the parent, or after navigating back from entry detail).
            if collectionFeedVM.hasCompletedInitialLoad {
                Task {
                    await collectionFeedVM.loadEntries()
                    await collectionsViewModel.loadCollections()
                }
            }
        }
        // Detect sub-collection renames by watching for name changes in the list.
        .onChange(of: currentSubCollections) { old, new in
            guard !old.isEmpty || !new.isEmpty else { return }
            let renamed = new.first { newSub in
                guard let oldSub = old.first(where: { $0.id == newSub.id }) else { return false }
                return oldSub.name != newSub.name
            }
            if let renamed {
                // Scroll to renamed tile after alphabetical reorder settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    scrollToSubId = renamed.id
                }
            }
        }
    }

    // MARK: - Sub-Collection Strip

    private var subCollectionStripSection: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollViewReader { hProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        newSubTile

                        if currentSubCollections.isEmpty {
                            // Separator before helper text
                            Rectangle()
                                .fill(Style.Color.separator)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                            // Width = viewport − HStack trailing padding (16pt) − slot (newSubTileWidth) − separator (1pt)
                                // This gives exact centering in the remaining area on any device.
                            Text("Get more specific with sub-collections.")
                                .font(Style.Typography.meta())
                                .foregroundColor(Style.Color.secondary)
                                .multilineTextAlignment(.center)
                                .frame(
                                    width: max(0, geo.size.width - 16 - newSubTileWidth - 1),
                                    alignment: .center
                                )
                                .allowsHitTesting(false)
                        }

                        ForEach(currentSubCollections) { sub in
                            // Leading 1pt separator + tile content as one slot unit.
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Style.Color.separator)
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                                NavigationLink(
                                    destination: CollectionDetailView(
                                        collection: sub,
                                        collectionsViewModel: collectionsViewModel,
                                        feedViewModel: collectionFeedVM.feedViewModel,
                                        supabase: supabase
                                    )
                                ) {
                                    subTileContent(sub)
                                }
                                .buttonStyle(.plain)
                            }
                            .id(sub.id)
                        }
                        // Trailing 1pt separator closes the rightmost tile visually.
                        if !currentSubCollections.isEmpty {
                            Rectangle()
                                .fill(Style.Color.separator)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .padding(.trailing, 16)
                    .frame(height: stripTotalHeight - 1)
                }
                .onChange(of: scrollToSubId) { _, id in
                    guard let id else { return }
                    // Small delay lets SwiftUI render the new/reordered tile before scroll.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            hProxy.scrollTo(id, anchor: .center)
                        }
                        scrollToSubId = nil
                    }
                }
                } // ScrollViewReader
            } // GeometryReader

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Strip Tiles

    private var newSubTile: some View {
        Button {
            isNewSubVisible = true
        } label: {
            VStack(alignment: .center, spacing: 6) {
                Icon("add-circle", glyphSize: Style.Icon.glyph)
                    .foregroundColor(Style.Color.primaryText)
                Text("Sub-collection")
                    .font(.custom("DMSans-Medium", size: 14))
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        // Fixed width at the button level so the HStack sees a rigid 110pt view and
        // the button itself offers that exact space to the label, guaranteeing that
        // VStack(alignment: .center) truly centers within the tile.
        .frame(width: newSubTileWidth)
    }

    private func subTileContent(_ sub: Collection) -> some View {
        let countLabel = sub.itemCount == 1 ? "1 item" : "\(sub.itemCount) items"
        return VStack(spacing: 4) {
            Icon("folder", glyphSize: Style.Icon.glyph)
                .foregroundColor(Style.Color.secondary)
            Text(sub.name)
                .font(.custom("DMSans-Medium", size: 14))
                .foregroundColor(Style.Color.primaryText)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Text(countLabel)
                .font(.custom("DMSans-Regular", size: 11))
                .foregroundColor(Style.Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: 150)
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

// CollectionActionSheetView (rename/delete) now lives in its own file so it
// can be presented from both CollectionDetailView and the chip sheet flow.
