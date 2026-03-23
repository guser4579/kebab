//
//  EntryDetailView.swift
//  kebab
//

import SwiftUI

struct EntryDetailView: View {

    let entry: Entry
    @ObservedObject var feedViewModel: FeedViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var displayedRootEntry: Entry
    @State private var composerText: String = ""
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false
    @State private var threadData: ThreadData?

    init(entry: Entry, feedViewModel: FeedViewModel) {
        self.entry = entry
        self.feedViewModel = feedViewModel
        _displayedRootEntry = State(initialValue: entry)
    }

    private var directChildren: [Entry] {
        threadData?.directChildren(of: displayedRootEntry.id) ?? []
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy • h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private var formattedTimestamp: String {
        Self.timestampFormatter.string(from: displayedRootEntry.created_at)
    }

    private var rootDisplayContent: String {
        if displayedRootEntry.isContentHidden {
            return displayedRootEntry.content.map { char in
                char.isWhitespace ? char : "*"
            }.map(String.init).joined()
        } else {
            return displayedRootEntry.content
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                entryDetailHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        entryContentSection

                        if !directChildren.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(directChildren.enumerated()), id: \.element.id) { index, comment in
                                    VStack(spacing: 0) {
                                        if index > 0 {
                                            Rectangle()
                                                .fill(Style.Color.separator)
                                                .frame(height: 1)
                                                .padding(.leading, 17)
                                        }
                                        CommentRowView(
                                            comment: comment,
                                            feedViewModel: feedViewModel,
                                            rootId: displayedRootEntry.id,
                                            subtreeCount: threadData?.subtreeCount(for: comment.id) ?? 0,
                                            onMoreTapped: {
                                                activeEntryMenuEntry = comment
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
                    placeholder: "Add comment",
                    onSent: { content in
                        Task {
                            await feedViewModel.sendComment(
                                content: content,
                                parentId: displayedRootEntry.id,
                                rootId: displayedRootEntry.id,
                                depth: 1
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
                                onDelete: {
                                    Task {
                                        await feedViewModel.deleteEntry(id: sheetEntry.id)
                                        if sheetEntry.parent_id != nil {
                                            await reloadThread()
                                        } else {
                                            dismiss()
                                        }
                                    }
                                },
                                onToggleContentHidden: {
                                    Task {
                                        let succeeded = await feedViewModel.toggleEntryHidden(
                                            id: sheetEntry.id,
                                            currentValue: sheetEntry.isContentHidden
                                        )
                                        if sheetEntry.parent_id != nil {
                                            await reloadThread()
                                        } else if succeeded {
                                            displayedRootEntry = displayedRootEntry.withIsContentHidden(!sheetEntry.isContentHidden)
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
                            Task { await reloadThread() }
                        },
                        onSaveSuccess: { updated in
                            if updated.id == displayedRootEntry.id {
                                displayedRootEntry = updated
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
        let entries = await feedViewModel.loadComments(rootId: displayedRootEntry.id)
        threadData = ThreadData(entries: entries)
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

    private var entryContentSection: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 16)

            entryContent

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

    private var hasLinkCard: Bool {
        displayedRootEntry.linkAttachment != nil && !displayedRootEntry.isContentHidden
    }

    private var entryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Color.clear
                .frame(height: 4)

            if !displayedRootEntry.content.isEmpty {
                contentText

                Color.clear
                    .frame(height: hasLinkCard ? 8 : 12)
            }

            if let link = displayedRootEntry.linkAttachment, !displayedRootEntry.isContentHidden {
                RichLinkCardView(urlString: link.url, title: link.title, imageURL: link.image_url)

                Color.clear
                    .frame(height: 12)
            }

            if displayedRootEntry.content.isEmpty && !hasLinkCard {
                Color.clear
                    .frame(height: 12)
            }

            entryCommentCounter
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
    }

    @ViewBuilder
    private var entryCommentCounter: some View {
        let count = threadData.map(\.totalCount) ?? displayedRootEntry.comment_count ?? 0
        if count > 0 {
            Text(count == 1 ? "1 comment" : "\(count) comments")
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

            if displayedRootEntry.resurface_count > 0 {
                HStack(spacing: 0) {
                    Icon("refresh-04", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.resurface)

                    Text("\(displayedRootEntry.resurface_count)")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.resurface)
                }
                .padding(.leading, 2)
            }

            if displayedRootEntry.fire_count > 0 {
                HStack(spacing: 0) {
                    Icon("fire-03", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.fire)

                    Text("\(displayedRootEntry.fire_count)")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.fire)
                }
                .padding(.leading, 2)
            }

            Spacer(minLength: 0)

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                activeEntryMenuEntry = displayedRootEntry
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
        Text(rootDisplayContent)
            .font(.custom("DMSans-SemiBold", size: 16))
            .foregroundColor(Style.Color.primaryText)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
