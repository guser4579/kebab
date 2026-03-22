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

    @State private var displayedComment: Entry
    @State private var composerText: String = ""
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false
    @State private var threadData: ThreadData?

    init(comment: Entry, rootId: UUID, feedViewModel: FeedViewModel) {
        self.comment = comment
        self.rootId = rootId
        self.feedViewModel = feedViewModel
        _displayedComment = State(initialValue: comment)
    }

    private var directChildren: [Entry] {
        threadData?.directChildren(of: displayedComment.id) ?? []
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy • h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private var formattedTimestamp: String {
        Self.timestampFormatter.string(from: displayedComment.created_at)
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
                    Task { await reloadThread() }
                }
                .background(Style.Color.background)
                .foregroundColor(Style.Color.primaryText)
            }
            .safeAreaInset(edge: .bottom) {
                ComposerView(
                    text: $composerText,
                    maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                    placeholder: "Add reply",
                    onSent: { content in
                        Task {
                            await feedViewModel.sendComment(
                                content: content,
                                parentId: displayedComment.id,
                                rootId: rootId,
                                depth: displayedComment.depth + 1
                            )
                            await reloadThread()
                        }
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
                                isComment: true,
                                onDelete: {
                                    Task {
                                        await feedViewModel.deleteEntry(id: sheetEntry.id)
                                        if sheetEntry.id == displayedComment.id {
                                            dismiss()
                                        } else {
                                            await reloadThread()
                                        }
                                    }
                                },
                                onToggleContentHidden: {
                                    Task {
                                        let succeeded = await feedViewModel.toggleEntryHidden(
                                            id: sheetEntry.id,
                                            currentValue: sheetEntry.isContentHidden
                                        )
                                        if succeeded && sheetEntry.id == displayedComment.id {
                                            displayedComment = displayedComment.withIsContentHidden(!sheetEntry.isContentHidden)
                                        }
                                        await reloadThread()
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
                            Task { await reloadThread() }
                        },
                        onSaveSuccess: { updated in
                            if updated.id == displayedComment.id {
                                displayedComment = updated
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
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private func reloadThread() async {
        let entries = await feedViewModel.loadComments(rootId: rootId)
        threadData = ThreadData(entries: entries)
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
            Text(count == 1 ? "1 reply" : "\(count) replies")
                .font(.custom("DMSans-Regular", size: 16))
                .foregroundColor(Style.Color.secondary)
                .frame(height: 24, alignment: .leading)
        }
    }

    private var headerRow: some View {
        HStack {
            Text(formattedTimestamp)
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
