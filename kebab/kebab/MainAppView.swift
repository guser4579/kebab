import SwiftUI
import Supabase

struct MainAppView: View {

    /// UserDefaults key backing the feed composer draft, so an in-progress
    /// message survives app termination and failed sends.
    private static let feedDraftKey = "composer.draft.feed"
    /// Staged link survives alongside the text draft (images stay in-memory,
    /// matching existing draft-persistence parity).
    private static let feedLinkDraftKey = "composer.draft.feed.link"

    private let supabase: SupabaseClient
    @StateObject private var feedViewModel: FeedViewModel
    @StateObject private var collectionsViewModel: CollectionsViewModel
    /// Session-lived registry of per-scope feed stores: every visited scope
    /// stays warm with its own pages, position, and unseen state.
    @StateObject private var scopeCoordinator: FeedScopeCoordinator
    @State private var composerText: String =
        UserDefaults.standard.string(forKey: MainAppView.feedDraftKey) ?? ""
    /// Images staged in the feed composer (in-memory only; restored on failed send).
    @State private var composerImages: [PendingImage] = []
    /// Link staged in the feed composer as a compact chip (pasted URL).
    @State private var composerLink: URL? =
        UserDefaults.standard.string(forKey: MainAppView.feedLinkDraftKey).flatMap(URL.init(string:))
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false
    @State private var isSettingsOpen: Bool = false
    /// Live finger translation while dragging the settings panel closed.
    @State private var settingsDragOffset: CGFloat = 0
    @State private var isSearchActive: Bool = false
    @State private var addToCollectionEntry: Entry?
    @State private var isAddToCollectionVisible: Bool = false
    /// True when the Add-to-collection surface should appear in place (quick
    /// action, keyboard may be mid-dismissal behind it) instead of sliding up.
    @State private var addToCollectionAppearsInPlace = false
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
    /// Pending entry whose sync permanently failed; drives the Retry/Discard alert.
    @State private var pendingWarningId: UUID?
    /// Full-screen composer — the same draft (composerText/composerImages) at
    /// maximum accommodation, entered from the constrained state's expand control.
    @State private var isComposerFullScreenVisible = false
    /// One-shot signal asking the inline composer to retake keyboard focus
    /// (set when collapsing back from the full-screen composer).
    @State private var composerFocusRequest = false
    // Post-capture state: the just-captured entry gets a transient action
    // strip (Comment / Add to collection / Edit) and a brief settling
    // emphasis. Action-dismissed first, timer-dismissed second (~10s).
    @State private var postCaptureEntryId: UUID?
    /// Shorter-lived (~650ms) surface emphasis on the new row — a receipt.
    @State private var settlingEntryId: UUID?
    /// Invalidates stale timers when a newer capture supersedes the strip.
    @State private var postCaptureGeneration = 0
    // Comment quick action: programmatic push into the entry's detail view
    // with the comment composer pre-focused.
    @State private var commentTargetEntry: Entry?
    @State private var isCommentTargetActive = false
    /// Lightweight transient message (e.g. "Failed to delete") — a floating
    /// capsule above the composer, never a modal.
    @State private var transientNotice: String?
    /// Invalidates a stale auto-clear when a newer notice replaces the text.
    @State private var transientNoticeGeneration = 0
    @Environment(\.scenePhase) private var scenePhase

    let authViewModel: AuthViewModel

    init(supabase: SupabaseClient, authViewModel: AuthViewModel) {
        self.supabase = supabase
        _feedViewModel = StateObject(wrappedValue: FeedViewModel(supabase: supabase))
        _collectionsViewModel = StateObject(wrappedValue: CollectionsViewModel(supabase: supabase))
        _scopeCoordinator = StateObject(wrappedValue: FeedScopeCoordinator(supabase: supabase))
        self.authViewModel = authViewModel
    }

    /// Settings panel open/close: a no-bounce spring matched to the feel of a
    /// native navigation transition.
    private static let settingsTransition: Animation = .spring(response: 0.36, dampingFraction: 1.0)

    private func openSettings() {
        dismissPostCapture()
        // The keyboard is an independent surface: drop it decisively so it
        // isn't left hovering over the settings panel.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        withAnimation(Self.settingsTransition) {
            isSettingsOpen = true
        }
    }

    private func closeSettings() {
        withAnimation(Self.settingsTransition) {
            isSettingsOpen = false
            settingsDragOffset = 0
        }
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

    /// Collection name for a scope's empty state; nil for All.
    private func scopeDisplayName(for scope: FeedScope) -> String? {
        guard let id = scope.collectionId else { return nil }
        return collectionsViewModel.collections.first { $0.id == id }?.name
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

    /// One submission path for every composer state (inline and full-screen):
    /// queue-then-flush, with draft restoration if the outbox write fails.
    private func sendDraft(_ content: String) {
        // Every scope obeys the live-edge rule: at the edge the entry flows
        // in naturally; away from it the viewport is preserved and the entry
        // becomes an unseen arrival in the active scope.
        let activeStore = scopeCoordinator.store(for: FeedScope(filter: feedViewModel.activeCollectionFilter))
        // Active collection filter targets the composer: the new
        // entry lands in the filtered collection.
        let targetId = feedViewModel.activeCollectionFilter?.targetCollectionId
        let images = composerImages
        let link = composerLink
        composerImages = []
        composerLink = nil
        // Queue-then-flush: the entry appears immediately with a
        // pending mark and syncs whenever connectivity allows.
        let queuedId = feedViewModel.queueEntry(
            content: content,
            images: images.map(\.image),
            linkURL: link,
            collectionId: targetId
        )
        if let queuedId {
            if !activeStore.isAtLiveEdge {
                // Preserve the reading position: hold the new entry out of
                // the rendered feed and surface it through the FAB count.
                activeStore.holdOwnEntry(id: queuedId)
            }
            // The quick actions belong to the creation event, not to the new
            // row's viewport position: they appear above the composer whether
            // or not the entry itself is on screen.
            beginPostCapture(for: queuedId)
        } else {
            // Outbox write failed (disk full) — restore the draft.
            if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composerText = content
            }
            if composerImages.isEmpty {
                composerImages = images
            }
            if composerLink == nil {
                composerLink = link
            }
        }
    }

    // MARK: - Post-capture state

    private func beginPostCapture(for entryId: UUID) {
        postCaptureGeneration += 1
        let generation = postCaptureGeneration

        withAnimation(.easeOut(duration: 0.25)) {
            postCaptureEntryId = entryId
        }
        // Settling is a ~650ms receipt; the row fades back on clear. It never
        // replays: promotion keeps the same id and this state is set only here.
        settlingEntryId = entryId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            if settlingEntryId == entryId {
                settlingEntryId = nil
            }
        }
        // Timer dismissal is the fallback, never the primary rule.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if postCaptureGeneration == generation {
                dismissPostCapture()
            }
        }
    }

    /// Any meaningful user action dismisses the post-capture state at once.
    private func dismissPostCapture() {
        postCaptureGeneration += 1
        settlingEntryId = nil
        guard postCaptureEntryId != nil else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            postCaptureEntryId = nil
        }
    }

    /// The just-captured entry once promoted. Quick actions need the server
    /// row (comments, filing, editing all live there); online promotion is
    /// sub-second, offline the strip stays inert until sync — matching the
    /// pending row's disabled actions.
    private func promotedPostCaptureEntry() -> Entry? {
        guard let id = postCaptureEntryId else { return nil }
        return feedViewModel.entries.first { $0.id == id }
    }

    private func openCommentQuickAction() {
        guard let entry = promotedPostCaptureEntry() else { return }
        dismissPostCapture()
        commentTargetEntry = entry
        isCommentTargetActive = true
    }

    private func openAddToCollectionQuickAction() {
        guard let entry = promotedPostCaptureEntry() else { return }
        dismissPostCapture()
        // Discrete sequence, no choreography: resign the keyboard, then put
        // the opaque full-screen surface up in its final position immediately.
        // The keyboard finishes its exit invisibly BEHIND the surface, and the
        // feed (keyboard-independent) never moves — one visible plane change.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        addToCollectionEntry = entry
        addToCollectionAppearsInPlace = true
        withAnimation(.easeOut(duration: 0.15)) {
            isAddToCollectionVisible = true
        }
    }

    private func openEditQuickAction() {
        guard let entry = promotedPostCaptureEntry() else { return }
        dismissPostCapture()
        fullScreenEditEntry = entry
        withAnimation(.easeOut(duration: 0.25)) {
            isFullScreenEditVisible = true
        }
    }

    /// Transient strip in the reclaimed area above the composer, targeting
    /// the entry that was just created. Flat capsules, feed language.
    private var postCaptureStrip: some View {
        // Scrolls rather than compressing labels if the three don't fit at a
        // given width; they fit comfortably at common device widths.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Style.Spacing.x2) {
                postCaptureAction(
                    "Comment",
                    iconName: "message-circle",
                    action: openCommentQuickAction
                )
                postCaptureAction(
                    "Add to collection",
                    iconName: "folder",
                    action: openAddToCollectionQuickAction
                )
                postCaptureAction(
                    "Edit",
                    iconName: "pencil-edit-02",
                    action: openEditQuickAction
                )
            }
            .padding(.horizontal, Style.Spacing.x4)
            .frame(maxWidth: .infinity)
        }
        // Horizontal ScrollViews claim all offered height; pin to content.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func postCaptureAction(
        _ title: String,
        iconName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Icon(iconName, glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.primaryText)

                Text(title)
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Style.Spacing.x3)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(Style.Color.composerBackground)
                    .overlay(Capsule().stroke(Style.Color.separator, lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Optimistic entry deletion: the entry leaves every warm scope the
    /// moment the user confirms, with a fast restrained collapse; the backend
    /// delete runs invisibly (with its own transport retries). Only a genuine
    /// failure restores the entry and surfaces a transient notice.
    private func performEntryDelete(_ entry: Entry) {
        let removals = withAnimation(.easeInOut(duration: 0.18)) {
            scopeCoordinator.removeForDelete(id: entry.id)
        }
        Task {
            let deleted = await feedViewModel.deleteEntry(id: entry.id)
            if !deleted {
                withAnimation(.easeInOut(duration: 0.18)) {
                    scopeCoordinator.restoreAfterFailedDelete(removals)
                }
                showTransientNotice("Failed to delete")
            }
        }
    }

    private func showTransientNotice(_ message: String) {
        transientNoticeGeneration += 1
        let generation = transientNoticeGeneration
        withAnimation(.easeOut(duration: 0.2)) {
            transientNotice = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if transientNoticeGeneration == generation {
                withAnimation(.easeOut(duration: 0.25)) {
                    transientNotice = nil
                }
            }
        }
    }

    private func performDelete(_ collection: Collection) {
        Task {
            let parentId = collection.parentId
            let ok = await collectionsViewModel.deleteCollection(id: collection.id)
            if ok {
                // Deleted sub → land on the parent's aggregate view;
                // deleted parent → back to All.
                if let parentId {
                    scopeCoordinator.activate(.parent(parentId))
                    feedViewModel.activeCollectionFilter = .all(parentId: parentId)
                } else {
                    scopeCoordinator.activate(.all)
                    feedViewModel.activeCollectionFilter = nil
                }
                // Collection structure changed: warm scopes re-derive their
                // membership on their own revalidation.
                scopeCoordinator.revalidateAllWarm()
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
                            openSettings()
                        },
                        onSearchTapped: {
                            dismissPostCapture()
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
                            dismissPostCapture()
                            scopeCoordinator.activate(.all)
                            feedViewModel.activeCollectionFilter = nil
                        },
                        onSelectParent: { parent in
                            dismissPostCapture()
                            scopeCoordinator.activate(.parent(parent.id))
                            // A parent becoming active makes its subs likely
                            // next stops: warm their newest pages.
                            scopeCoordinator.prefetch(
                                collectionsViewModel.subCollections(for: parent.id).map { .sub($0.id) }
                            )
                            // Tabs don't toggle: re-tapping the selected parent
                            // stays put (already its aggregate view).
                            feedViewModel.activeCollectionFilter = .all(parentId: parent.id)
                        },
                        onSelectSub: { sub in
                            dismissPostCapture()
                            // Chips are optional refinements that toggle:
                            // re-tapping the active one returns to the parent
                            // aggregate (no explicit "All" control).
                            if feedViewModel.activeCollectionFilter == .single(id: sub.id),
                               let parentId = sub.parentId {
                                scopeCoordinator.activate(.parent(parentId))
                                feedViewModel.activeCollectionFilter = .all(parentId: parentId)
                            } else {
                                scopeCoordinator.activate(.sub(sub.id))
                                feedViewModel.activeCollectionFilter = .single(id: sub.id)
                            }
                        },
                        onPlusTapped: {
                            // Drop the keyboard first so the sheet (or the
                            // full-screen flow) never presents underneath it.
                            // Synchronous resign, same pattern as the entry
                            // ellipsis — no delay needed.
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                            dismissPostCapture()
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

                    // Feed — one warm ScopeFeedView per visited scope, kept
                    // alive in a ZStack so each scope preserves its own scroll
                    // position, pages, and FAB state. Switching scopes just
                    // toggles which surface is visible.
                    ZStack {
                        let activeScope = FeedScope(filter: feedViewModel.activeCollectionFilter)
                        ForEach(scopeCoordinator.visitedScopes) { scope in
                            ScopeFeedView(
                                store: scopeCoordinator.store(for: scope),
                                scopeName: scopeDisplayName(for: scope),
                                feedViewModel: feedViewModel,
                                containerHeight: geometry.size.height,
                                settlingEntryId: settlingEntryId,
                                // Quick actions take temporary priority over
                                // the FAB; it returns via its own transition
                                // once they dismiss.
                                suppressesFAB: postCaptureEntryId != nil,
                                onUserScroll: { dismissPostCapture() },
                                onEntryOpened: { dismissPostCapture() },
                                onMoreTapped: { entry in
                                    dismissPostCapture()
                                    activeEntryMenuEntry = entry
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isEntryActionSheetVisible = true
                                    }
                                },
                                onResurfaceTapped: { entry in
                                    Task {
                                        await feedViewModel.resurfaceEntry(entry: entry)
                                        // The move-to-live-edge lands as an
                                        // arrival in every warm scope it
                                        // belongs to (unseen while away).
                                        scopeCoordinator.revalidateScopes(containing: entry)
                                    }
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
                            .opacity(scope == activeScope ? 1 : 0)
                            .allowsHitTesting(scope == activeScope)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background(Style.Color.background)
                    .foregroundColor(Style.Color.primaryText)
                    // Constant reserve for the floating composer. This is the
                    // feed's ONLY bottom inset: it never changes with composer
                    // state, the quick-action strip, or the keyboard, so the
                    // feed's scroll geometry is a stable physical surface.
                    .safeAreaPadding(.bottom, Style.Layout.feedBottomReserve)
                    .task {
                        // Pending and freshly promoted entries render their
                        // collection breadcrumb (and match aggregate filters)
                        // from the local collections model.
                        feedViewModel.collectionInfoResolver = { [weak collectionsViewModel] id in
                            guard let vm = collectionsViewModel,
                                  let collection = vm.collections.first(where: { $0.id == id })
                            else { return nil }
                            let parent = collection.parentId.flatMap { pid in
                                vm.collections.first { $0.id == pid }
                            }
                            return CollectionDisplayInfo(
                                name: collection.name,
                                parentId: collection.parentId,
                                parentName: parent?.name
                            )
                        }
                        // Cross-scope hooks: promoted outbox rows and in-place
                        // patches reconcile into every warm scope by ID.
                        feedViewModel.onEntryPromoted = { [weak scopeCoordinator] promoted in
                            scopeCoordinator?.fanOutPromoted(promoted)
                        }
                        feedViewModel.onEntryPatched = { [weak feedViewModel, weak scopeCoordinator] id in
                            if let fresh = feedViewModel?.entries.first(where: { $0.id == id }) {
                                scopeCoordinator?.reconcile(fresh)
                            }
                        }
                        // Deletes confirmed from any screen (detail included)
                        // drop and tombstone the row in every warm scope.
                        // For the feed's own optimistic path this is a no-op
                        // second removal.
                        feedViewModel.onEntryDeleted = { [weak scopeCoordinator] id in
                            scopeCoordinator?.noteDeletedEverywhere(id: id)
                        }
                        // SWR: cached page already rendered; revalidate quietly.
                        scopeCoordinator.activate(.all)
                        // Legacy full-array load: still feeds post-capture entry
                        // lookup and onEntryPatched snapshots. Flagged for removal.
                        await feedViewModel.loadEntries()
                        await collectionsViewModel.loadCollections()
                        // All is stable: warm the newest page of visible parents.
                        scopeCoordinator.prefetch(
                            collectionsViewModel.parentCollections.map { .parent($0.id) }
                        )
                    }
                }
                .ignoresSafeArea(edges: .top)
                // The feed layer is keyboard-independent, always: the keyboard
                // is an input surface that covers the feed, never one that
                // resizes it. The composer floats in its own keyboard-avoiding
                // layer below; full-screen surfaces handle their own keyboards.
                .ignoresSafeArea(.keyboard)
                // Left-edge swipe opens settings (same push as the gear tap),
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
                                && !isComposerFullScreenVisible
                                && !isAddToCollectionVisible
                                // On pushed screens the left edge means "back".
                                && (PopGestureDelegate.shared.navigationController?.viewControllers.count ?? 1) <= 1
                        },
                        onSwipe: {
                            openSettings()
                        }
                    )
                )
                // Composer layer: a keyboard-avoiding ZStack sibling, NOT a
                // safeAreaInset. The strip and every composer state change
                // (focus, growth, clearing on send) float over the feed
                // without touching its scroll insets; only this layer rides
                // the keyboard.
                VStack(spacing: 0) {
                    // The area above the composer hosts the transient
                    // post-capture actions — overlaid, never layout.
                    if postCaptureEntryId != nil {
                        postCaptureStrip
                            .padding(.bottom, Style.Spacing.x2)
                            .transition(.opacity)
                    }

                    ComposerView(
                            text: $composerText,
                            maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                            placeholder: composerPlaceholder,
                            allowsAttachments: true,
                            attachedImages: $composerImages,
                            attachedLink: $composerLink,
                            requestFocus: $composerFocusRequest,
                            onSent: { content in
                                sendDraft(content)
                            },
                            onFocus: {
                                dismissPostCapture()
                            },
                            onExpandTapped: {
                                dismissPostCapture()
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isComposerFullScreenVisible = true
                                }
                            },
                            onStartList: {
                                // List: a purpose-built accelerator — seed
                                // the first checkbox and open the
                                // full-screen accommodation state, focused.
                                dismissPostCapture()
                                if composerText.isEmpty {
                                    composerText = Checklist.uncheckedMarker
                                } else {
                                    composerText += "\n" + Checklist.uncheckedMarker
                                }
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isComposerFullScreenVisible = true
                                }
                            }
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
                    .ignoresSafeArea(.container, edges: .bottom)
                )
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .bottom)

                // Settings layer: lives conceptually on the left side of the
                // app. An always-mounted panel (stable node identity) that
                // slides over the frozen feed — the feed's scroll state is
                // never touched. Finger-tracked leftward drag dismisses it
                // interactively; commit uses threshold or projected velocity.
                SettingsView(
                    onClose: { closeSettings() },
                    authViewModel: authViewModel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Flatten before shadowing so the shadow traces the panel's
                // silhouette (its trailing edge during the slide), not every
                // subview inside it.
                .compositingGroup()
                .shadow(color: .black.opacity(isSettingsOpen ? 0.18 : 0), radius: 24, x: 8, y: 0)
                .offset(x: (isSettingsOpen ? 0 : -geometry.size.width) + settingsDragOffset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            guard isSettingsOpen else { return }
                            // Track the finger directly; only leftward
                            // movement pulls the panel out.
                            settingsDragOffset = min(0, value.translation.width)
                        }
                        .onEnded { value in
                            guard isSettingsOpen else { return }
                            let projected = value.predictedEndTranslation.width
                            if value.translation.width < -80 || projected < -200 {
                                withAnimation(Self.settingsTransition) {
                                    isSettingsOpen = false
                                    settingsDragOffset = 0
                                }
                            } else {
                                withAnimation(Self.settingsTransition) {
                                    settingsDragOffset = 0
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
                                    performEntryDelete(entry)
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
                                        addToCollectionAppearsInPlace = false
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
                                addToCollectionAppearsInPlace = false
                            }
                        },
                        onSuccess: {
                            let movedId = entry.id
                            Task {
                                await collectionsViewModel.loadCollections()
                                await feedViewModel.loadEntries()
                                if let fresh = feedViewModel.entries.first(where: { $0.id == movedId }) {
                                    scopeCoordinator.reconcile(fresh)
                                }
                            }
                        }
                    )
                    // Quick-action path appears in place (a quiet fade in its
                    // final position); the ellipsis path keeps its slide.
                    .transition(addToCollectionAppearsInPlace ? .opacity : .move(edge: .bottom))
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
                            scopeCoordinator.activate(.parent(created.id))
                            feedViewModel.activeCollectionFilter = .all(parentId: created.id)
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            // Full-screen composer: the same draft at maximum accommodation.
            // Entering saves nothing; X collapses the draft back to the inline
            // composer and returns keyboard focus there.
            .overlay {
                if isComposerFullScreenVisible {
                    ComposerFullScreenView(
                        text: $composerText,
                        attachedImages: $composerImages,
                        attachedLink: $composerLink,
                        onSend: {
                            let content = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                            sendDraft(content)
                            composerText = ""
                            withAnimation(.easeOut(duration: 0.25)) {
                                isComposerFullScreenVisible = false
                            }
                        },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isComposerFullScreenVisible = false
                            }
                            // Hand the keyboard back to the inline composer once
                            // the overlay has finished leaving.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                composerFocusRequest = true
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
                            scopeCoordinator.activate(.sub(created.id))
                            feedViewModel.activeCollectionFilter = .single(id: created.id)
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            // Lightweight transient notice (delete failures): a floating
            // capsule above the composer that fades in and out on its own.
            .overlay(alignment: .bottom) {
                if let notice = transientNotice {
                    Text(notice)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.primaryText)
                        .padding(.horizontal, Style.Spacing.x4)
                        .frame(height: 36)
                        .background(
                            Capsule()
                                .fill(Style.Color.composerBackground)
                                .overlay(Capsule().stroke(Style.Color.separator, lineWidth: 1))
                        )
                        .padding(.bottom, 96)
                        .transition(.opacity)
                        .allowsHitTesting(false)
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
                            scopeCoordinator.revalidateAllWarm()
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
            // Comment quick action: straight into the new entry's thread with
            // the comment composer focused — jot → think with zero extra taps.
            .navigationDestination(isPresented: $isCommentTargetActive) {
                if let entry = commentTargetEntry {
                    EntryDetailView(
                        entry: entry,
                        feedViewModel: feedViewModel,
                        autoFocusComposer: true
                    )
                }
            }
            .onChange(of: composerText) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: Self.feedDraftKey)
                // Typing a new draft is a meaningful action — the previous
                // capture's strip yields. (Clearing on send leaves "" and
                // never triggers this.)
                if !newValue.isEmpty {
                    dismissPostCapture()
                }
            }
            .onChange(of: composerLink) { _, newValue in
                UserDefaults.standard.set(newValue?.absoluteString, forKey: Self.feedLinkDraftKey)
            }
            // Returning to the foreground is a natural moment to drain the outbox.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    feedViewModel.kickFlush()
                    // Foreground revalidation: silent; every warm scope keeps
                    // its position and applies its own arrival rule.
                    scopeCoordinator.revalidateAllWarm()
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
