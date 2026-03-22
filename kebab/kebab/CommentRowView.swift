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
    var onMoreTapped: (() -> Void)?

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy • h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private var formattedTimestamp: String {
        Self.timestampFormatter.string(from: comment.created_at)
    }

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
            .padding(.leading, 33)
            .padding(.trailing, 16)

            Color.clear
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerRow: some View {
        HStack {
            Text(formattedTimestamp)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)

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
        Text(subtreeCount == 1 ? "1 reply" : "\(subtreeCount) replies")
            .font(.custom("DMSans-Regular", size: 16))
            .foregroundColor(Style.Color.secondary)
            .frame(height: 24, alignment: .leading)
    }
}
