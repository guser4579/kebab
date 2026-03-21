import SwiftUI

struct EntryRowView: View {

    let entry: Entry
    var feedViewModel: FeedViewModel?
    var onResultActivated: (() -> Void)?
    var onMoreTapped: (() -> Void)?
    var onResurfaceTapped: (() -> Void)?
    var onPinTapped: (() -> Void)?

    @State private var isResurfacing = false

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
            Color.clear
                .frame(height: 16)

            entryContent

            Color.clear
                .frame(height: 16)

            bottomSeparator
        }
        .onChange(of: entry.resurface_count) {
            isResurfacing = false
        }
    }

    private var hasLinkCard: Bool {
        entry.linkAttachment != nil && !entry.isContentHidden
    }

    private var entryContent: some View {
        ZStack(alignment: .leading) {
            if let feedViewModel = feedViewModel {
                NavigationLink(destination: EntryDetailView(entry: entry, feedViewModel: feedViewModel)) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .simultaneousGesture(TapGesture().onEnded { onResultActivated?() })
            }

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
                    RichLinkCardView(urlString: link.url, title: link.title, imageURL: link.image_url)

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
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
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

            if entry.resurface_count > 0 {
                HStack(spacing: 0) {
                    Icon("refresh-04", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.resurface)

                    Text("\(entry.resurface_count)")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.resurface)
                }
                .padding(.leading, 2)
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
        Text(displayContent)
            .font(Style.Typography.body())
            .foregroundColor(Style.Color.primaryText)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
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
        HStack(spacing: Style.Spacing.x4) {
            Group {
                if let feedViewModel = feedViewModel {
                    NavigationLink(destination: EntryDetailView(entry: entry, feedViewModel: feedViewModel)) {
                        Icon("message-circle")
                            .foregroundColor(Style.Color.secondary)
                    }
                    .simultaneousGesture(TapGesture().onEnded { onResultActivated?() })
                } else {
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Icon("message-circle")
                            .foregroundColor(Style.Color.secondary)
                    }
                }
            }

            if entry.pinned_at == nil {
                Button {
                    guard !isResurfacing else { return }
                    isResurfacing = true
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    onResurfaceTapped?()
                } label: {
                    Icon("refresh-04")
                        .foregroundColor(Style.Color.secondary)
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
