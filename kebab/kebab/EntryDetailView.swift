//
//  EntryDetailView.swift
//  kebab
//

import SwiftUI

struct EntryDetailView: View {

    let entry: Entry
    @ObservedObject var feedViewModel: FeedViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var composerText: String = ""
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var comments: [Entry] = []

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy • h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private var formattedTimestamp: String {
        Self.timestampFormatter.string(from: entry.created_at)
    }

    private var displayContent: String {
        if entry.isContentHidden {
            return entry.content.map { char in
                char.isWhitespace ? char : "*"
            }.map(String.init).joined()
        } else {
            return entry.content
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                entryDetailHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        entryContentSection

                        ForEach(comments) { comment in
                            CommentRowView(comment: comment, onMoreTapped: {
                                activeEntryMenuEntry = comment
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = true
                                }
                            })
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxWidth: .infinity)
                .task {
                    comments = await feedViewModel.loadComments(rootId: entry.id)
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
                            await feedViewModel.sendComment(content: content, rootEntry: entry)
                            comments = await feedViewModel.loadComments(rootId: entry.id)
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
                                isComment: sheetEntry.parent_id != nil,
                                onDelete: {
                                    Task {
                                        await feedViewModel.deleteEntry(id: sheetEntry.id)
                                        if sheetEntry.parent_id != nil {
                                            comments = await feedViewModel.loadComments(rootId: entry.id)
                                        }
                                    }
                                },
                                onEdit: {
                                    Task {
                                        await feedViewModel.toggleEntryHidden(
                                            id: sheetEntry.id,
                                            currentValue: sheetEntry.isContentHidden
                                        )
                                        if sheetEntry.parent_id != nil {
                                            comments = await feedViewModel.loadComments(rootId: entry.id)
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
            .background(Style.Color.background)
            .ignoresSafeArea(edges: .top)
        }
        .background(Style.Color.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }

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
                .font(.custom("DMMono-Medium", size: 16))
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
        entry.linkAttachment != nil && !entry.isContentHidden
    }

    private var entryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Color.clear
                .frame(height: 4)

            if !entry.content.isEmpty {
                contentText

                Color.clear
                    .frame(height: hasLinkCard ? 8 : 12)
            }

            if let link = entry.linkAttachment, !entry.isContentHidden {
                LinkCardView(urlString: link.url)

                Color.clear
                    .frame(height: 12)
            }

            if entry.content.isEmpty && !hasLinkCard {
                Color.clear
                    .frame(height: 12)
            }

            entryCommentCounter
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
    }

    @ViewBuilder
    private var entryCommentCounter: some View {
        let count = entry.comment_count ?? comments.count
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

            Spacer(minLength: 0)

            Button {
                activeEntryMenuEntry = entry
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
        Text(displayContent)
            .font(Style.Typography.body())
            .foregroundColor(Style.Color.primaryText)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
