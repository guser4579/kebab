import SwiftUI

struct EntryRowView: View {

    let entry: Entry
    var feedViewModel: FeedViewModel?
    var onMoreTapped: (() -> Void)?
    var onPinTapped: (() -> Void)?

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
        VStack(spacing: 0) {
            topSeparator

            Color.clear
                .frame(height: 16)

            entryContent

            Color.clear
                .frame(height: 16)

            bottomSeparator
        }
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
                LinkCardView(urlString: link.url, title: link.title)

                Color.clear
                    .frame(height: 12)
            }

            if entry.content.isEmpty && !hasLinkCard {
                Color.clear
                    .frame(height: 12)
            }

            actionRow

            Color.clear
                .frame(height: 8)

            commentCounter
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
    }

    private var topSeparator: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var bottomSeparator: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
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
        Text(displayContent)
            .font(Style.Typography.body())
            .foregroundColor(Style.Color.primaryText)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var commentCounter: some View {
        if let count = entry.comment_count, count > 0 {
            Text(count == 1 ? "1 comment" : "\(count) comments")
                .font(.custom("DMSans-Regular", size: 16))
                .foregroundColor(Style.Color.secondary)
                .frame(height: 24, alignment: .leading)
        }
    }

    private var actionRow: some View {
        HStack(spacing: Style.Spacing.replyBelowBody) {
            Group {
                if let feedViewModel = feedViewModel {
                    NavigationLink(destination: EntryDetailView(entry: entry, feedViewModel: feedViewModel)) {
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

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                onPinTapped?()
            } label: {
                Icon(entry.pinned_at != nil ? "pin-filled" : "pin")
                    .foregroundColor(Style.Color.secondary)
            }
        }
        .frame(minHeight: 24, alignment: .leading)
    }
}
