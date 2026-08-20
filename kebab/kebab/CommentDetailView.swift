//
//  CommentDetailView.swift
//  kebab
//

import SwiftUI

struct CommentDetailView: View {

    let comment: Entry
    let rootId: UUID
    /// True when the screen was opened from the Search surface: the anchor
    /// gets a one-time orientation tint after the landing scroll, so the
    /// tapped result is immediately findable. Never set on in-thread
    /// navigation.
    let highlightAnchorOnArrival: Bool
    @ObservedObject var feedViewModel: FeedViewModel

    @Environment(\.dismiss) private var dismiss
    // Search infrastructure: deliberate opens and thread actions are resume
    // signals; thread mutations mark the search corpus stale.
    @EnvironmentObject private var recentActivityStore: RecentActivityStore
    @EnvironmentObject private var searchCorpusStore: SearchCorpusStore

    @State private var didRecordOpen = false
    @State private var displayedComment: Entry
    @State private var composerText: String = ""
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false
    /// Source of truth for the thread: optimistic mutations edit this array
    /// directly; `threadData` (and the spine derived with it) is always
    /// rebuilt from it in the same beat.
    @State private var threadEntries: [Entry] = []
    @State private var threadData: ThreadData?
    /// The comment chain above the anchor, root-ward first — derived in
    /// `setThread` (never during body evaluation) from `parent_id` truth.
    @State private var spineAncestors: [Entry] = []
    /// The root Entry rendered at the top of the spine. Resolved from warm
    /// feed truth (falling back to the corpus mirror) each time the thread
    /// is set; nil (unresolvable) simply omits the root section.
    @State private var spineRoot: Entry?
    /// The screen positions itself at the anchor exactly once, when the
    /// thread first materializes. After that the user owns scroll position —
    /// reappearances, refetches, and mutations never re-anchor.
    @State private var hasPerformedInitialScroll = false
    /// The thread revision this screen's local state reflects — reappearing
    /// with an unchanged revision skips the refetch (see EntryDetailView).
    @State private var loadedThreadRevision: Int?
    @State private var commentSendFailed = false
    /// Drives the arrival tint; nonzero only during the one-time animation
    /// (set → brief hold → single fade), keyed off the same initial-arrival
    /// guard as the landing scroll so it can never replay.
    @State private var anchorHighlightOpacity: Double = 0

    init(
        comment: Entry,
        rootId: UUID,
        feedViewModel: FeedViewModel,
        highlightAnchorOnArrival: Bool = false
    ) {
        self.comment = comment
        self.rootId = rootId
        self.feedViewModel = feedViewModel
        self.highlightAnchorOnArrival = highlightAnchorOnArrival
        _displayedComment = State(initialValue: comment)
        // The whole spine is derived here, before the first frame: ancestry,
        // root, children and every rail/node state settle together instead of
        // arriving across separate render passes. Source is purely local (warm
        // scopes + on-device corpus); the fetch below only reconciles.
        let local = feedViewModel.localThread(rootId: rootId)
        let seed = local.comments
        _threadEntries = State(initialValue: seed)
        if seed.isEmpty {
            _threadData = State(initialValue: nil)
            _spineAncestors = State(initialValue: [])
            _spineRoot = State(initialValue: nil)
        } else {
            let data = ThreadData(entries: seed)
            _threadData = State(initialValue: data)
            _spineAncestors = State(initialValue: data.ancestors(of: comment.id))
            _spineRoot = State(initialValue: local.root)
        }
    }

    private var directChildren: [Entry] {
        threadData?.directChildren(of: displayedComment.id) ?? []
    }

    private var rootCommentDisplayContent: String {
        if displayedComment.isContentHidden {
            return displayedComment.content.map { char in
                char.isWhitespace ? char : "*"
            }.map(String.init).joined()
        } else {
            return displayedComment.content
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                commentDetailHeader

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let root = spineRoot {
                                spineRootSection(root)
                            }

                            conversationLeadIn

                            commentContentSection
                                .id(displayedComment.id)

                            if !directChildren.isEmpty {
                                // Replies are subordinate to the focal comment:
                                // they sit inset in the same gutter column the
                                // context above uses, and own their own spine —
                                // opening on the first node, closing on the
                                // last — rather than continuing through the
                                // focal row. Sibling separators begin at the
                                // rail's right edge so they meet the spine with
                                // no gap; drawn as overlays so the rail stays
                                // unbroken.
                                VStack(spacing: 0) {
                                    ForEach(Array(directChildren.enumerated()), id: \.element.id) { index, child in
                                        CommentRowView(
                                            comment: child,
                                            feedViewModel: feedViewModel,
                                            rootId: rootId,
                                            subtreeCount: threadData?.subtreeCount(for: child.id) ?? 0,
                                            threadRail: .forChild(index: index, of: directChildren.count),
                                            onMoreTapped: {
                                                activeEntryMenuEntry = child
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
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        // Reappearing with a dead anchor (an ancestor's
                        // cascade delete happened above this screen in the
                        // stack): pop to the nearest surviving context —
                        // never render a ghost.
                        if feedViewModel.isEntryDeleted(displayedComment.id) {
                            dismiss()
                            return
                        }
                        // Seed the thread synchronously from the on-device
                        // mirror so the spine exists in the first rendered
                        // hierarchy — ancestors never hydrate in later, and
                        // the screen works offline. The network reload below
                        // reconciles behind it.
                        // No seeding here: init already built the spine from
                        // local state, so the first frame is the settled one.
                        performInitialScrollIfReady(proxy)
                        let revision = feedViewModel.threadRevision(rootId: rootId)
                        if loadedThreadRevision == nil || loadedThreadRevision != revision {
                            Task { await reloadThread() }
                        }
                    }
                    .onChange(of: threadData == nil) {
                        performInitialScrollIfReady(proxy)
                    }
                    .background(Style.Color.background)
                    .foregroundColor(Style.Color.primaryText)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ComposerView(
                    text: $composerText,
                    maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                    placeholder: "Add comment",
                    onSent: { content in
                        sendCommentOptimistically(content: content)
                    },
                    onFocus: { }
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

                        if isEntryActionSheetVisible, let sheetEntry = activeEntryMenuEntry {
                            EntryActionSheetView(
                                entry: sheetEntry,
                                onDelete: {
                                    // Deleting an ancestor cascades away the
                                    // anchor and everything below it — the
                                    // screen must not stay open rendering a
                                    // deleted object, so it pops exactly like
                                    // deleting the anchor itself.
                                    let removesAnchor = sheetEntry.id == displayedComment.id
                                        || spineAncestors.contains { $0.id == sheetEntry.id }
                                    deleteCommentOptimistically(
                                        sheetEntry,
                                        dismissAfter: removesAnchor
                                    )
                                },
                                onToggleContentHidden: {
                                    // Optimistic: this screen's copies update in
                                    // the same beat as the tap; rollback restores
                                    // them on a genuine failure.
                                    let wasHidden = sheetEntry.isContentHidden
                                    if sheetEntry.id == displayedComment.id {
                                        displayedComment = displayedComment.withIsContentHidden(!wasHidden)
                                    }
                                    setThread(threadEntries.map {
                                        $0.id == sheetEntry.id ? $0.withIsContentHidden(!wasHidden) : $0
                                    })
                                    feedViewModel.noteThreadChanged(rootId: rootId)
                                    markThreadCurrent()
                                    Task {
                                        let succeeded = await feedViewModel.toggleEntryHidden(
                                            id: sheetEntry.id,
                                            currentValue: wasHidden
                                        )
                                        if !succeeded {
                                            if sheetEntry.id == displayedComment.id {
                                                displayedComment = displayedComment.withIsContentHidden(wasHidden)
                                            }
                                            setThread(threadEntries.map {
                                                $0.id == sheetEntry.id ? $0.withIsContentHidden(wasHidden) : $0
                                            })
                                            feedViewModel.noteThreadChanged(rootId: rootId)
                                            markThreadCurrent()
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
                                rootId: rootId,
                                contextEntryId: editEntry.id,
                                kind: .edited
                            )
                        },
                        onSaveSuccess: { updated in
                            // Immediate local patch: this screen's copy and any
                            // thread row update in the same beat the editor closes.
                            if updated.id == displayedComment.id {
                                displayedComment = updated
                            }
                            setThread(threadEntries.map { $0.id == updated.id ? updated : $0 })
                            feedViewModel.noteThreadChanged(rootId: rootId)
                            markThreadCurrent()
                        },
                        onPersistFailure: {
                            // Restore this screen's copy and thread truth.
                            if editEntry.id == displayedComment.id {
                                displayedComment = editEntry
                            }
                            Task { await reloadThread() }
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
            // Deliberate open of a nested comment: the exact context Recent
            // Activity restores. Recorded once per visit.
            if !didRecordOpen {
                didRecordOpen = true
                recentActivityStore.record(
                    rootId: rootId,
                    contextEntryId: displayedComment.id,
                    kind: .viewed
                )
            }
        }
    }

    private func reloadThread() async {
        // Capture the revision at fetch start: a mutation landing mid-fetch
        // leaves us stale, so the next appearance refetches.
        let revision = feedViewModel.threadRevision(rootId: rootId)
        if let entries = await feedViewModel.loadComments(rootId: rootId) {
            // An identical thread is not re-applied: a normal open → refresh
            // must not reconstruct presentation state that is already correct.
            if !(threadData != nil && FeedViewModel.isSameThread(entries, threadEntries)) {
                setThread(entries)
            }
            // Server truth says the anchor is gone (deleted from another
            // device or a path the tombstones didn't see): pop rather than
            // render a ghost. Only a successful fetch may conclude this.
            if threadData?.entry(id: displayedComment.id) == nil {
                dismiss()
                return
            }
        } else {
            // Fetch failed (offline or server error): the corpus mirror is
            // the local truth for this thread. Whole-spine substitution, one
            // beat — ancestors never hydrate level by level. An empty mirror
            // keeps whatever is already on screen.
            let mirrored = searchCorpusStore.threadComments(rootId: rootId)
            if !mirrored.isEmpty || threadData == nil {
                setThread(mirrored)
            }
        }
        loadedThreadRevision = revision
    }

    /// Own optimistic mutations advance the recorded revision in the same
    /// beat they bump it — local state is already current, no self-refetch.
    private func markThreadCurrent() {
        loadedThreadRevision = feedViewModel.threadRevision(rootId: rootId)
    }

    private func setThread(_ entries: [Entry]) {
        threadEntries = entries
        let data = ThreadData(entries: entries)
        threadData = data
        // Spine derivation happens here, at the model boundary — one O(depth)
        // walk per thread mutation, never during body evaluation.
        spineAncestors = data.ancestors(of: displayedComment.id)
        // Root resolution: warm feed truth first, corpus mirror second. A
        // double miss keeps the last resolved copy rather than blanking the
        // section mid-session.
        spineRoot = feedViewModel.localThread(rootId: rootId).root ?? spineRoot
    }

    /// One-time landing: position the anchor near the top with a sliver of
    /// its parent visible above — the upward affordance. Runs when the thread
    /// first materializes; guarded so later state changes, reappearances, and
    /// keyboard/composer churn can never re-anchor the user.
    private func performInitialScrollIfReady(_ proxy: ScrollViewProxy) {
        guard !hasPerformedInitialScroll, threadData != nil else { return }
        hasPerformedInitialScroll = true
        // Nothing rendered above the anchor → the natural top is the anchor.
        let needsScroll = spineRoot != nil || !spineAncestors.isEmpty
        // One deterministic hop: the scroll target exists in the hierarchy
        // committed by this beat's state; the async lets that layout land.
        let anchorId = displayedComment.id
        DispatchQueue.main.async {
            if needsScroll {
                proxy.scrollTo(anchorId, anchor: UnitPoint(x: 0, y: 0.09))
            }
            // Orientation tint for Search arrivals: appears with the landed
            // frame, holds briefly, fades once. Bound to this one-shot, so
            // body recomputation, refreshes, keyboard/composer changes, and
            // reappearances can never replay it.
            if highlightAnchorOnArrival {
                anchorHighlightOpacity = 0.55
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.easeOut(duration: 0.7)) {
                        anchorHighlightOpacity = 0
                    }
                }
            }
        }
    }

    /// Local-first reply creation: the reply and every counter it affects
    /// (this screen's reply count, the root's total across all feed scopes)
    /// are true immediately; persistence reconciles behind by shared id.
    private func sendCommentOptimistically(content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optimistic = Entry(
            id: UUID(),
            user_id: displayedComment.user_id,
            parent_id: displayedComment.id,
            root_id: rootId,
            depth: displayedComment.depth + 1,
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
        feedViewModel.applyCommentCountDelta(rootId: rootId, delta: 1)
        markThreadCurrent()

        Task {
            let ok = await feedViewModel.sendComment(
                id: optimistic.id,
                content: trimmed,
                parentId: displayedComment.id,
                rootId: rootId,
                depth: displayedComment.depth + 1
            )
            if ok {
                // One successful comment → one activity event. Recorded on
                // the success path (not at optimistic insert) so a rolled-
                // back failure never leaves a phantom event.
                recentActivityStore.record(
                    rootId: rootId,
                    contextEntryId: displayedComment.id,
                    kind: .commented
                )
                // No thread refetch: the optimistic row shares the server
                // row's id, so local state already IS the merged truth.
                searchCorpusStore.markStale()
            } else {
                setThread(threadEntries.filter { $0.id != optimistic.id })
                feedViewModel.applyCommentCountDelta(rootId: rootId, delta: -1)
                markThreadCurrent()
                commentSendFailed = true
            }
        }
    }

    /// Local-first deletion of a comment (possibly this screen's own):
    /// subtree and counters update immediately — and when deleting this
    /// screen's own comment, the pop happens in the same beat, not after the
    /// server answers. Failure restores from truth; the revision bump makes
    /// the parent screen refetch on reappearance either way.
    private func deleteCommentOptimistically(_ comment: Entry, dismissAfter: Bool) {
        let doomed = subtreeIds(of: comment.id)
        let removedCount = (threadData?.subtreeCount(for: comment.id) ?? 0) + 1
        setThread(threadEntries.filter { !doomed.contains($0.id) })
        // Tombstone the whole cascade in the same beat: any screen deeper in
        // the nav stack anchored inside it pops on reappearance instead of
        // rendering a ghost. Retracted below if the server says no.
        feedViewModel.noteEntriesDeleted(doomed)
        feedViewModel.applyCommentCountDelta(rootId: rootId, delta: -removedCount)
        markThreadCurrent()
        if dismissAfter {
            dismiss()
        }

        Task {
            let ok = await feedViewModel.deleteEntry(id: comment.id)
            if !ok {
                feedViewModel.retractEntriesDeleted(doomed)
                feedViewModel.applyCommentCountDelta(rootId: rootId, delta: removedCount)
                if !dismissAfter {
                    await reloadThread()
                }
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

    // MARK: - Header

    private var commentDetailHeader: some View {
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
            // No depth number: the thread above the anchor communicates depth
            // structurally. Search keeps the numeric mark, where a result is
            // shown outside its conversational context.
            Text("Comment")
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

    // MARK: - Thread spine (root Entry + ancestors above the anchor)

    /// The root Entry heading the thread. It always continues (the anchor
    /// is beneath it), so it carries the origin node and the spine flows
    /// from there — no divider, no closing spacer; the first child's own
    /// top inset is the whole transition. Display variant: no ellipsis, no
    /// action row; checklist toggles stay live.
    private func spineRootSection(_ root: Entry) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 16)

            EntryContentView(
                entry: root,
                commentCount: threadData?.totalCount ?? root.comment_count ?? 0,
                isThreaded: true,
                showsEllipsis: false,
                showsActionRow: false,
                onToggleChecklistItem: { snapshot, lineIndex in
                    spineRoot = snapshot.withContent(
                        Checklist.toggling(snapshot.content, lineIndex: lineIndex)
                    )
                    Task {
                        if await feedViewModel.toggleChecklistItem(entry: snapshot, lineIndex: lineIndex) == false {
                            spineRoot = snapshot
                        }
                    }
                }
            )

            Color.clear
                .frame(height: 16)
        }
        .overlay(alignment: .topLeading) {
            ThreadRailOverlay(rail: .origin)
        }
    }

    /// Ancestors between the root and the anchor. Every one continues into
    /// the row beneath it, so each is a node on the spine — no separators
    /// between directly connected ancestry; the rail is the relationship.
    /// Context rows: no reply affordance or navigation, full ellipsis menu.
    @ViewBuilder
    private var conversationLeadIn: some View {
        ForEach(Array(spineAncestors.enumerated()), id: \.element.id) { index, ancestor in
            CommentRowView(
                comment: ancestor,
                showsReplyAffordance: false,
                threadRail: (index == 0 && spineRoot == nil) ? .origin : .link,
                onMoreTapped: {
                    activeEntryMenuEntry = ancestor
                    withAnimation(.easeOut(duration: 0.25)) {
                        isEntryActionSheetVisible = true
                    }
                }
            )
        }
    }

    // MARK: - Content

    private var anchorHasSpineAbove: Bool {
        spineRoot != nil || !spineAncestors.isEmpty
    }

    /// The anchored comment — the focal object of this screen, and therefore
    /// always the full-width plane. It carries no node and no rail through it:
    /// the incoming spine from the context above terminates as a short lead-in
    /// that stops before the content, and any replies below open their own
    /// spine in the gutter column. Replies never demote it, so its geometry is
    /// identical whether it has none, one, or twenty — nothing here moves when
    /// the thread resolves.
    /// The Search-arrival tint wraps it: same token and weight as the
    /// result-row reacquisition tint, zero except during the one-time arrival
    /// animation.
    private var commentContentSection: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 16)

                commentContent

                Color.clear
                    .frame(height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.Color.composerBackground.opacity(anchorHighlightOpacity))

            bottomSeparator
        }
        .overlay(alignment: .topLeading) {
            if anchorHasSpineAbove {
                ThreadRailOverlay(rail: .stub)
            }
        }
    }

    private var bottomSeparator: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var commentContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Color.clear
                .frame(height: 4)

            if !displayedComment.content.isEmpty {
                contentText

                Color.clear
                    .frame(height: 12)
            }

            if displayedComment.content.isEmpty {
                Color.clear
                    .frame(height: 12)
            }

            commentReplyCounter
        }
        .padding(.leading, Style.Layout.entryContentPadding)
        .padding(.trailing, Style.Layout.entryContentPadding)
    }

    @ViewBuilder
    private var commentReplyCounter: some View {
        let count = threadData?.subtreeCount(for: displayedComment.id) ?? 0
        if count > 0 {
            Text(count == 1 ? "1 comment" : "\(count) comments")
                .font(.custom("DMSans-Regular", size: 16))
                .foregroundColor(Style.Color.secondary)
                .frame(height: 24, alignment: .leading)
        }
    }

    private var headerRow: some View {
        HStack {
            Text(Style.Timestamp.absolute(for: displayedComment.created_at))
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)

            Spacer(minLength: 0)

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                activeEntryMenuEntry = displayedComment
                withAnimation(.easeOut(duration: 0.25)) {
                    isEntryActionSheetVisible = true
                }
            } label: {
                Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.secondary)
            }
        }
    }

    private var contentText: some View {
        CommentLinkText(text: rootCommentDisplayContent)
    }
}
