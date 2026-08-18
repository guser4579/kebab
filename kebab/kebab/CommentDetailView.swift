//
//  CommentDetailView.swift
//  kebab
//

import SwiftUI

struct CommentDetailView: View {

    let comment: Entry
    let rootId: UUID
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
    /// directly; `threadData` is always derived from it in the same beat.
    @State private var threadEntries: [Entry] = []
    @State private var threadData: ThreadData?
    /// The thread revision this screen's local state reflects — reappearing
    /// with an unchanged revision skips the refetch (see EntryDetailView).
    @State private var loadedThreadRevision: Int?
    @State private var commentSendFailed = false

    init(comment: Entry, rootId: UUID, feedViewModel: FeedViewModel) {
        self.comment = comment
        self.rootId = rootId
        self.feedViewModel = feedViewModel
        _displayedComment = State(initialValue: comment)
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

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        commentContentSection

                        if !directChildren.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(directChildren.enumerated()), id: \.element.id) { index, child in
                                    VStack(spacing: 0) {
                                        if index > 0 {
                                            Rectangle()
                                                .fill(Style.Color.separator)
                                                .frame(height: 1)
                                                .padding(.leading, 17)
                                        }
                                        CommentRowView(
                                            comment: child,
                                            feedViewModel: feedViewModel,
                                            rootId: rootId,
                                            subtreeCount: threadData?.subtreeCount(for: child.id) ?? 0,
                                            onMoreTapped: {
                                                activeEntryMenuEntry = child
                                                withAnimation(.easeOut(duration: 0.25)) {
                                                    isEntryActionSheetVisible = true
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Style.Color.separator)
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxWidth: .infinity)
                .onAppear {
                    let revision = feedViewModel.threadRevision(rootId: rootId)
                    if threadData == nil || loadedThreadRevision != revision {
                        Task { await reloadThread() }
                    }
                }
                .background(Style.Color.background)
                .foregroundColor(Style.Color.primaryText)
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
                                    deleteCommentOptimistically(
                                        sheetEntry,
                                        dismissAfter: sheetEntry.id == displayedComment.id
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
        let entries = await feedViewModel.loadComments(rootId: rootId)
        setThread(entries)
        loadedThreadRevision = revision
    }

    /// Own optimistic mutations advance the recorded revision in the same
    /// beat they bump it — local state is already current, no self-refetch.
    private func markThreadCurrent() {
        loadedThreadRevision = feedViewModel.threadRevision(rootId: rootId)
    }

    private func setThread(_ entries: [Entry]) {
        threadEntries = entries
        threadData = ThreadData(entries: entries)
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
        let removedCount = (threadData?.subtreeCount(for: comment.id) ?? 0) + 1
        setThread(threadEntries.filter { !subtreeIds(of: comment.id).contains($0.id) })
        feedViewModel.applyCommentCountDelta(rootId: rootId, delta: -removedCount)
        markThreadCurrent()
        if dismissAfter {
            dismiss()
        }

        Task {
            let ok = await feedViewModel.deleteEntry(id: comment.id)
            if !ok {
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
            Text("Comment [\(displayedComment.depth)]")
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

    private var commentContentSection: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 16)

            commentContent

            Color.clear
                .frame(height: 16)

            bottomSeparator
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
        .padding(.horizontal, Style.Layout.entryContentPadding)
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
