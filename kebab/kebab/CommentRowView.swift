//
//  CommentRowView.swift
//  kebab
//

import SwiftUI

struct CommentRowView: View {

    let comment: Entry
    var feedViewModel: FeedViewModel?
    var rootId: UUID?
    var subtreeCount: Int = 0
    /// False for ancestor rows in the thread spine: their conversation is
    /// already on screen, so the row carries no reply affordance, no
    /// counter, and no navigation — content and the ellipsis menu only.
    var showsReplyAffordance: Bool = true
    /// Present when the row sits in the thread gutter system: draws the
    /// node/rail overlay and shifts content to the shared thread column.
    /// nil renders the row's legacy standalone geometry.
    var threadRail: ThreadRail? = nil
    var onMoreTapped: (() -> Void)?

    private var displayContent: String {
        if comment.isContentHidden {
            return comment.content.map { char in
                char.isWhitespace ? char : "*"
            }.map(String.init).joined()
        } else {
            return comment.content
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 16)

            ZStack(alignment: .leading) {
                if let feedViewModel = feedViewModel, let rootId = rootId {
                    NavigationLink(destination: CommentDetailView(
                        comment: comment,
                        rootId: rootId,
                        feedViewModel: feedViewModel
                    )) {
                        Color.clear
                            .contentShape(Rectangle())
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    headerRow

                    Color.clear
                        .frame(height: 4)

                    contentText

                    if showsReplyAffordance {
                        Color.clear
                            .frame(height: 12)

                        actionRow

                        if subtreeCount > 0 {
                            Color.clear
                                .frame(height: 8)

                            replyCounter
                        }
                    }
                }
            }
            .padding(.leading, threadRail == nil ? 33 : ThreadRailOverlay.contentLeading)
            .padding(.trailing, 16)

            Color.clear
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if let threadRail {
                ThreadRailOverlay(rail: threadRail)
            }
        }
    }

    private var headerRow: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Style.Timestamp.relative(for: comment.created_at, relativeTo: context.date))
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
            }

            Spacer(minLength: 0)

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                onMoreTapped?()
            } label: {
                Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.secondary)
            }
        }
    }

    private var contentText: some View {
        CommentLinkText(text: displayContent)
    }

    private var actionRow: some View {
        HStack(spacing: Style.Spacing.replyBelowBody) {
            if let feedViewModel = feedViewModel, let rootId = rootId {
                NavigationLink(destination: CommentDetailView(
                    comment: comment,
                    rootId: rootId,
                    feedViewModel: feedViewModel
                )) {
                    Icon("message-circle")
                        .foregroundColor(Style.Color.secondary)
                }
            } else {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Icon("message-circle")
                        .foregroundColor(Style.Color.secondary)
                }
            }
        }
        .frame(minHeight: 24, alignment: .leading)
    }

    @ViewBuilder
    private var replyCounter: some View {
        Text(subtreeCount == 1 ? "1 comment" : "\(subtreeCount) comments")
            .font(.custom("DMSans-Regular", size: 16))
            .foregroundColor(Style.Color.secondary)
            .frame(height: 24, alignment: .leading)
    }
}
