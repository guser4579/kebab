//
//  EntryDetailView.swift
//  kebab
//

import SwiftUI
import Supabase

struct EntryDetailView: View {

    let entry: Entry
    @ObservedObject var feedViewModel: FeedViewModel
    /// When non-nil, the view is in collection context: resurface is hidden,
    /// the action sheet shows "Move entry" instead of "Add to collection".
    var onRemoveFromCollection: (() async -> Void)? = nil
    /// Focuses the comment composer on arrival (post-capture Comment quick
    /// action): keyboard up, zero extra taps between jot and think.
    var autoFocusComposer: Bool = false
    /// True when opened from the Search surface: the entry gets the same
    /// one-time orientation tint a comment result gets, so the tapped result
    /// is immediately findable. Never set on in-app navigation.
    var highlightOnArrival: Bool = false

    @Environment(\.dismiss) private var dismiss
    // Search infrastructure: deliberate opens and thread actions are resume
    // signals; thread mutations mark the search corpus stale.
    @EnvironmentObject private var recentActivityStore: RecentActivityStore
    @EnvironmentObject private var searchCorpusStore: SearchCorpusStore
    // Warm scope stores + transient notices: deletes from this screen use the
    // same optimistic remove/restore path as the feed, and surface a failure
    // from a place that still exists after this screen dismisses.
    @EnvironmentObject private var scopeCoordinator: FeedScopeCoordinator
    @EnvironmentObject private var noticeCenter: TransientNoticeCenter
    @EnvironmentObject private var collectionsViewModel: CollectionsViewModel

    @State private var didRecordOpen = false
    @State private var displayedRootEntry: Entry
    @State private var composerText: String = ""
    @State private var composerFocusRequest = false
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false
    @State private var isAddToCollectionVisible = false
    /// Source of truth for the thread: optimistic mutations edit this array
    /// directly; `threadData` is always derived from it in the same beat.
    @State private var threadEntries: [Entry] = []
    @State private var threadData: ThreadData?
    /// The thread revision this screen's local state reflects. Reappearing
    /// with an unchanged revision does no refetch at all; own optimistic
    /// mutations advance it in the same beat they bump it.
    @State private var loadedThreadRevision: Int?
    /// Viewport and entry-content heights, measured so the comment empty
    /// state can center itself in the space the comments would occupy.
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var entryContentHeight: CGFloat = 0
    @State private var commentSendFailed = false
    /// Drives the arrival tint; nonzero only during the one-time animation.
    @State private var arrivalHighlightOpacity: Double = 0
    @State private var hasRunArrivalHighlight = false

    init(
        entry: Entry,
        feedViewModel: FeedViewModel,
        onRemoveFromCollection: (() async -> Void)? = nil,
        autoFocusComposer: Bool = false,
        highlightOnArrival: Bool = false
    ) {
        self.entry = entry
        self.feedViewModel = feedViewModel
        self.onRemoveFromCollection = onRemoveFromCollection
        self.autoFocusComposer = autoFocusComposer
        self.highlightOnArrival = highlightOnArrival
        _displayedRootEntry = State(initialValue: entry)
        // Thread geometry is decided before the first frame, not after the
        // fetch: the comments are already on-device, so seed from them here.
        // A cold miss yields the normal zero-comment layout and the fetch
        // fills it in.
        let seed = feedViewModel.localThread(rootId: entry.id).comments
        _threadEntries = State(initialValue: seed)
        _threadData = State(initialValue: seed.isEmpty ? nil : ThreadData(entries: seed))
    }

    private var directChildren: [Entry] {
        threadData?.directChildren(of: displayedRootEntry.id) ?? []
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                entryDetailHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        entryContentSection
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                entryContentHeight = $0
                            }

                        if !directChildren.isEmpty {
                            // Comments hang from the entry's origin node:
                            // the rail passes alongside each sibling and
                            // closes on the last one's node. Sibling
                            // separators begin at the rail's right edge so
                            // they meet the spine with no gap — drawn as
                            // overlays so the rail stays unbroken.
                            VStack(spacing: 0) {
                                ForEach(Array(directChildren.enumerated()), id: \.element.id) { index, comment in
                                    CommentRowView(
                                        comment: comment,
                                        feedViewModel: feedViewModel,
                                        rootId: displayedRootEntry.id,
                                        subtreeCount: threadData?.subtreeCount(for: comment.id) ?? 0,
                                        threadRail: index == directChildren.count - 1 ? .terminus : .link,
                                        onMoreTapped: {
                                            activeEntryMenuEntry = comment
                                            withAnimation(.easeOut(duration: 0.25)) {
                                                isEntryActionSheetVisible = true
                                            }
                                        }
                                    )
                                    .overlay(alignment: .top) {
                                        if index > 0 {
                                            Rectangle()
                                                .fill(Style.Color.separator)
                                                .frame(height: 1)
                                                .padding(.leading, ThreadRailOverlay.dividerLeading)
                                        }
                                    }
                                }
                            }
                        } else if threadData != nil {
                            // Gated on a resolved thread so the line never
                            // flashes while comments are still loading.
                            commentsEmptyState
                                .frame(maxWidth: .infinity)
                                .frame(height: max(
                                    180,
                                    scrollViewportHeight - entryContentHeight
                                        - Style.Layout.feedBottomReserve
                                ))
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    scrollViewportHeight = $0
                }
                .onAppear {
                    // Refetch only when the thread genuinely changed (or was
                    // never loaded) — popping back from a deeper screen with
                    // nothing new does zero work.
                    // Orientation tint for Search arrivals: appears with the
                    // first frame, holds, fades once. Guarded so reappearing
                    // from a deeper screen never replays it.
                    if highlightOnArrival, !hasRunArrivalHighlight {
                        hasRunArrivalHighlight = true
                        arrivalHighlightOpacity = 0.55
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation(.easeOut(duration: 0.7)) {
                                arrivalHighlightOpacity = 0
                            }
                        }
                    }
                    let revision = feedViewModel.threadRevision(rootId: displayedRootEntry.id)
                    if threadData == nil || loadedThreadRevision != revision {
                        Task { await reloadThread() }
                    }
                    syncDisplayedRootFromWarmScopes()
                }
                .background(Style.Color.background)
                .foregroundColor(Style.Color.primaryText)
            }
            .safeAreaInset(edge: .bottom) {
                ComposerView(
                    text: $composerText,
                    maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                    placeholder: "Add comment",
                    requestFocus: $composerFocusRequest,
                    onSent: { content in
                        sendCommentOptimistically(
                            content: content,
                            parentId: displayedRootEntry.id,
                            depth: 1
                        )
                    },
                    onFocus: { }
                )
            }
            .onAppear {
                // Wait out the push transition so the focus lands after the
                // screen has settled.
                if autoFocusComposer {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        composerFocusRequest = true
                    }
                }
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

                        if isEntryActionSheetVisible, let sheetEntry = activeEntryMenuEntry {
                            EntryActionSheetView(
                                entry: sheetEntry,
                                onDelete: {
                                    if sheetEntry.parent_id != nil {
                                        deleteCommentOptimistically(sheetEntry)
                                    } else {
                                        performRootDelete(sheetEntry)
                                    }
                                },
                                onToggleContentHidden: {
                                    // Optimistic: this screen's copy updates in
                                    // the same beat as the tap; the shared model
                                    // patch fans out to warm scopes underneath.
                                    let wasHidden = sheetEntry.isContentHidden
                                    if sheetEntry.parent_id != nil {
                                        setThread(threadEntries.map {
                                            $0.id == sheetEntry.id ? $0.withIsContentHidden(!wasHidden) : $0
                                        })
                                        feedViewModel.noteThreadChanged(rootId: displayedRootEntry.id)
                                        markThreadCurrent()
                                    } else {
                                        displayedRootEntry = displayedRootEntry.withIsContentHidden(!wasHidden)
                                    }
                                    Task {
                                        let succeeded = await feedViewModel.toggleEntryHidden(
                                            id: sheetEntry.id,
                                            currentValue: wasHidden
                                        )
                                        if !succeeded {
                                            if sheetEntry.parent_id != nil {
                                                setThread(threadEntries.map {
                                                    $0.id == sheetEntry.id ? $0.withIsContentHidden(wasHidden) : $0
                                                })
                                                feedViewModel.noteThreadChanged(rootId: displayedRootEntry.id)
                                                markThreadCurrent()
                                            } else {
                                                displayedRootEntry = displayedRootEntry.withIsContentHidden(wasHidden)
                                            }
                                        }
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
                                onAddToCollection: onRemoveFromCollection != nil ? nil : {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isEntryActionSheetVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        activeEntryMenuEntry = nil
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isAddToCollectionVisible = true
                                        }
                                    }
                                },
                                onMoveEntry: onRemoveFromCollection != nil ? {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isEntryActionSheetVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        activeEntryMenuEntry = nil
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isAddToCollectionVisible = true
                                        }
                                    }
                                } : nil,
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
                            }
                        },
                        onPersistSuccess: {
                            recentActivityStore.record(
                                rootId: editEntry.parent_id == nil ? editEntry.id : displayedRootEntry.id,
                                contextEntryId: editEntry.id,
                                kind: .edited
                            )
                        },
                        onSaveSuccess: { updated in
                            // Immediate local patch: root copy and any thread
                            // row update in the same beat the editor closes.
                            if updated.id == displayedRootEntry.id {
                                displayedRootEntry = updated
                            }
                            if updated.parent_id != nil {
                                setThread(threadEntries.map { $0.id == updated.id ? updated : $0 })
                                feedViewModel.noteThreadChanged(rootId: displayedRootEntry.id)
                                markThreadCurrent()
                            }
                        },
                        onPersistFailure: {
                            // Restore this screen's copies from the pre-edit
                            // entry; the shared fan-out already rolled back
                            // every warm scope.
                            if editEntry.id == displayedRootEntry.id {
                                displayedRootEntry = editEntry
                            }
                            if editEntry.parent_id != nil {
                                Task { await reloadThread() }
                            }
                            noticeCenter.show("Couldn\u{2019}t save edit")
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .overlay {
                if isAddToCollectionVisible {
                    AddToCollectionFullScreenView(
                        entry: displayedRootEntry,
                        title: onRemoveFromCollection != nil ? "Move entry" : "Add to collection",
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isAddToCollectionVisible = false
                            }
                        },
                        onConfirm: { oldId, newId in
                            // Local-first move; the fan-out patches this
                            // screen's root via the shared model sync.
                            searchCorpusStore.markStale()
                            Task {
                                let ok = await feedViewModel.moveEntry(
                                    id: displayedRootEntry.id,
                                    from: oldId,
                                    to: newId
                                )
                                collectionsViewModel.refreshQuietly()
                                if !ok {
                                    noticeCenter.show("Couldn\u{2019}t move entry")
                                }
                            }
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .background(Style.Color.background)
            .ignoresSafeArea(edges: .top)
        }
        .background(Style.Color.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .enablesSwipeBack()
        .alert("Couldn\u{2019}t send comment", isPresented: $commentSendFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your comment wasn\u{2019}t saved. Check your connection and try again.")
        }
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            // Deliberate open — a valid (weaker) resume signal, recorded once
            // per visit so returning from deeper pushes doesn't overwrite a
            // stronger action taken inside.
            if !didRecordOpen {
                didRecordOpen = true
                recentActivityStore.record(
                    rootId: displayedRootEntry.id,
                    contextEntryId: displayedRootEntry.id,
                    kind: .viewed
                )
            }
        }
    }

    private func reloadThread() async {
        // Capture the revision at fetch start: a mutation landing mid-fetch
        // leaves us stale, so the next appearance refetches.
        let revision = feedViewModel.threadRevision(rootId: displayedRootEntry.id)
        // A failed fetch (nil) leaves the locally seeded thread standing —
        // offline keeps the geometry it opened with. An identical thread is
        // not re-applied, so a normal open → refresh rebuilds nothing.
        if let entries = await feedViewModel.loadComments(rootId: displayedRootEntry.id),
           !(threadData != nil && FeedViewModel.isSameThread(entries, threadEntries)) {
            setThread(entries)
        }
        loadedThreadRevision = revision
    }

    /// Own optimistic mutations advance the recorded revision in the same
    /// beat they bump it — local state is already current, no self-refetch.
    private func markThreadCurrent() {
        loadedThreadRevision = feedViewModel.threadRevision(rootId: displayedRootEntry.id)
    }

    private func setThread(_ entries: [Entry]) {
        threadEntries = entries
        threadData = ThreadData(entries: entries)
    }

    /// Local-first comment creation: the comment and the counter exist
    /// everywhere immediately — the thread list, this screen's counter, and
    /// (through the count patch) every warm feed scope — while persistence
    /// runs behind. The client-generated id makes the later authoritative
    /// reload a clean merge, never a duplicate.
    private func sendCommentOptimistically(content: String, parentId: UUID, depth: Int) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optimistic = Entry(
            id: UUID(),
            user_id: displayedRootEntry.user_id,
            parent_id: parentId,
            root_id: displayedRootEntry.id,
            depth: depth,
            content: trimmed,
            created_at: Date(),
            pinned_at: nil,
            isContentHidden: false,
            comment_count: nil,
            resurface_count: 0,
            fire_count: 0,
            attachments: nil,
            collection_id: nil,
            collection_name: nil,
            collection_parent_id: nil,
            collection_parent_name: nil
        )
        setThread(threadEntries + [optimistic])
        feedViewModel.applyCommentCountDelta(rootId: displayedRootEntry.id, delta: 1)
        markThreadCurrent()

        Task {
            let ok = await feedViewModel.sendComment(
                id: optimistic.id,
                content: trimmed,
                parentId: parentId,
                rootId: displayedRootEntry.id,
                depth: depth
            )
            if ok {
                // One successful comment → one activity event. Recorded on
                // the success path (not at optimistic insert) so a rolled-
                // back failure never leaves a phantom event.
                recentActivityStore.record(
                    rootId: displayedRootEntry.id,
                    contextEntryId: displayedRootEntry.id,
                    kind: .commented
                )
                // No thread refetch: the optimistic row shares the server
                // row's id, so local state already IS the merged truth.
                searchCorpusStore.markStale()
            } else {
                setThread(threadEntries.filter { $0.id != optimistic.id })
                feedViewModel.applyCommentCountDelta(rootId: displayedRootEntry.id, delta: -1)
                markThreadCurrent()
                commentSendFailed = true
            }
        }
    }

    /// Optimistic root deletion, matching the feed's behavior: the entry
    /// leaves every warm scope and this screen dismisses in the same beat;
    /// the backend delete (with its own transport retries) runs invisibly.
    /// A genuine failure restores the entry everywhere and surfaces a
    /// transient notice from the feed, which is what's on screen by then.
    private func performRootDelete(_ entry: Entry) {
        let removals = scopeCoordinator.removeForDelete(id: entry.id)
        dismiss()
        Task {
            let deleted = await feedViewModel.deleteEntry(id: entry.id)
            if !deleted {
                scopeCoordinator.restoreAfterFailedDelete(removals)
                noticeCenter.show("Failed to delete")
            }
        }
    }

    /// Local-first comment deletion: the subtree and the counter update
    /// immediately; a genuine backend failure restores both from truth.
    private func deleteCommentOptimistically(_ comment: Entry) {
        let removedCount = (threadData?.subtreeCount(for: comment.id) ?? 0) + 1
        setThread(threadEntries.filter { !subtreeIds(of: comment.id).contains($0.id) })
        feedViewModel.applyCommentCountDelta(rootId: displayedRootEntry.id, delta: -removedCount)
        markThreadCurrent()

        Task {
            let ok = await feedViewModel.deleteEntry(id: comment.id)
            if !ok {
                feedViewModel.applyCommentCountDelta(rootId: displayedRootEntry.id, delta: removedCount)
                await reloadThread()
            }
        }
    }

    /// The comment plus all its descendants, resolved from the local thread.
    private func subtreeIds(of id: UUID) -> Set<UUID> {
        var doomed: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for entry in threadEntries {
                if let parent = entry.parent_id,
                   doomed.contains(parent), !doomed.contains(entry.id) {
                    doomed.insert(entry.id)
                    changed = true
                }
            }
        }
        return doomed
    }

    /// Realigns local root state with the warm scope stores on appearance —
    /// mutations made elsewhere (feed row actions while this screen was
    /// deeper in the stack) land here without any whole-corpus mirror.
    private func syncDisplayedRootFromWarmScopes() {
        if let updated = scopeCoordinator.entry(id: displayedRootEntry.id), !updated.isPending {
            displayedRootEntry = updated
        }
    }

    // MARK: - Header

    private var entryDetailHeader: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            headerTopBar

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

    private var headerTopBar: some View {
        ZStack {
            Text("Entry")
                .font(.custom("DMSans-Medium", size: 16))
                .foregroundColor(Style.Color.primaryText)

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Style.Color.secondary)
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Style.Spacing.x4)
            .frame(height: 24, alignment: .center)
        }
        .frame(height: 24)
    }

    // MARK: - Content

    private var entryContentSection: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 16)

                entryContent

                Color.clear
                    .frame(height: 16)
            }
            // Search-arrival orientation tint: same token, weight and timing
            // as the comment anchor's. Zero except during the one-time run.
            .background(Style.Color.composerBackground.opacity(arrivalHighlightOpacity))

            // With comments present the entry is the thread's origin node and
            // the spine carries the transition; the trailing hairline only
            // belongs to the standalone entry.
            if directChildren.isEmpty {
                bottomSeparator
            }
        }
        .overlay(alignment: .topLeading) {
            if !directChildren.isEmpty {
                ThreadRailOverlay(rail: .origin)
            }
        }
    }

    private var bottomSeparator: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // Shared presentation with the thread spine in CommentDetailView; this
    // host wires the fully interactive variant.
    private var entryContent: some View {
        EntryContentView(
            entry: displayedRootEntry,
            commentCount: threadData.map(\.totalCount) ?? displayedRootEntry.comment_count ?? 0,
            isThreaded: !directChildren.isEmpty,
            showResurface: onRemoveFromCollection == nil,
            onMoreTapped: {
                activeEntryMenuEntry = displayedRootEntry
                withAnimation(.easeOut(duration: 0.25)) {
                    isEntryActionSheetVisible = true
                }
            },
            onResurfaceTapped: {
                // Optimistic on this screen's copy in the same beat; the
                // shared fan-out handles every warm scope. Rollback
                // restores the pre-tap count on genuine failure.
                let current = displayedRootEntry
                displayedRootEntry = current.withResurfaceCount(current.resurface_count + 1)
                recentActivityStore.record(
                    rootId: current.id,
                    contextEntryId: current.id,
                    kind: .resurfaced
                )
                Task {
                    if await feedViewModel.resurfaceEntry(entry: current) == false {
                        displayedRootEntry = displayedRootEntry.withResurfaceCount(current.resurface_count)
                    }
                }
            },
            onFireTapped: {
                let current = displayedRootEntry
                displayedRootEntry = current.withFireCount(current.fire_count + 1)
                Task {
                    if await feedViewModel.fireEntry(entry: current) == false {
                        displayedRootEntry = displayedRootEntry.withFireCount(current.fire_count)
                    }
                }
            },
            onToggleChecklistItem: { entry, lineIndex in
                displayedRootEntry = entry.withContent(
                    Checklist.toggling(entry.content, lineIndex: lineIndex)
                )
                Task {
                    if await feedViewModel.toggleChecklistItem(entry: entry, lineIndex: lineIndex) == false {
                        displayedRootEntry = entry
                    }
                }
            }
        )
    }

    /// Quiet functional empty state for the thread: one line in the same
    /// voice as the collection empty state, plus two whisper glyphs from the
    /// All field's language — atmosphere at trace level, nothing that reads
    /// as content or control. The composer below remains the action.
    private var commentsEmptyState: some View {
        Text("Add comments here.")
            .font(Style.Typography.meta())
            .foregroundColor(Style.Color.secondary)
            .overlay {
                Text("·")
                    .font(Style.Typography.mono(size: 12))
                    .foregroundColor(Style.Color.secondary)
                    .opacity(0.35)
                    .offset(x: -84, y: -20)
                Text("+")
                    .font(Style.Typography.mono(size: 11))
                    .foregroundColor(Style.Color.secondary)
                    .opacity(0.3)
                    .offset(x: 80, y: 18)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Add comments here.")
    }
}
