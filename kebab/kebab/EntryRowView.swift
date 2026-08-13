import SwiftUI

struct EntryRowView: View {

    let entry: Entry
    var feedViewModel: FeedViewModel?
    /// When false the resurface button is hidden (collection context).
    var showResurface: Bool = true
    /// When false the collection breadcrumb is hidden (collection context).
    var showBreadcrumb: Bool = true
    /// When false the bottom hairline is omitted — the newest (last) entry in a
    /// feed list sits flush above the composer with no stray line. Kept true for
    /// a sole entry, which rests at the top of the screen and needs closure.
    var showBottomSeparator: Bool = true
    var onResultActivated: (() -> Void)?
    var onMoreTapped: (() -> Void)?
    var onResurfaceTapped: (() -> Void)?
    var onPinTapped: (() -> Void)?
    var onFireTapped: (() -> Void)?
    /// Passed through to EntryDetailView when the entry is opened from collection context.
    var onRemoveFromCollection: (() async -> Void)? = nil

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

            if showBottomSeparator {
                bottomSeparator
            }
        }
    }

    private var hasLinkCard: Bool {
        entry.linkAttachment != nil && !entry.isContentHidden
    }

    private var entryContent: some View {
        ZStack(alignment: .leading) {
            if let feedViewModel = feedViewModel {
                NavigationLink(destination: EntryDetailView(
                    entry: entry,
                    feedViewModel: feedViewModel,
                    onRemoveFromCollection: onRemoveFromCollection,
                    showBreadcrumb: showBreadcrumb
                )) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .simultaneousGesture(TapGesture().onEnded { onResultActivated?() })
            }

            VStack(alignment: .leading, spacing: 0) {
                headerRow
                    // zIndex(1) ensures the header's extended tap area sits above the card
                    // in hit-testing order when a link-only entry has no text buffer below it.
                    .zIndex(1)

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
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Style.Timestamp.relative(for: entry.created_at, relativeTo: context.date))
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
            }

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

            if entry.fire_count > 0 {
                HStack(spacing: 0) {
                    Icon("fire-03", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.fire)

                    Text("\(entry.fire_count)")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.fire)
                }
                .padding(.leading, 2)
            }

            if showBreadcrumb {
                EntryBreadcrumbView(
                    collectionName: entry.collection_name,
                    collectionParentName: entry.collection_parent_name
                )
                .padding(.leading, 4)
            }

            Spacer(minLength: 0)

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                onMoreTapped?()
            } label: {
                Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.secondary)
            }
            // Expand the hit-test region by 10 pt in each direction without touching layout:
            // .padding(10) enlarges the frame that contentShape registers against, then
            // .padding(-10) shrinks the layout contribution back to the icon's natural size.
            .padding(10)
            .contentShape(Rectangle())
            .padding(-10)
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
        EntryRootActionRow(
            entry: entry,
            feedViewModel: feedViewModel,
            includeChat: true,
            showResurface: showResurface,
            onResultActivated: onResultActivated,
            onResurfaceTapped: onResurfaceTapped,
            onPinTapped: onPinTapped,
            onFireTapped: onFireTapped
        )
    }
}
