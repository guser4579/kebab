import SwiftUI

/// Search-specific result row. Handles both root entry results and comment results
/// from `search_entries_v2`. Intentionally does not reuse `EntryRowView` so that
/// feed/thread presentation can evolve independently from search presentation.
struct SearchResultRowView: View {

    let result: SearchResult
    let feedViewModel: FeedViewModel
    var onResultActivated: (() -> Void)?

    @State private var isPreviewExpanded: Bool = false

    /// Masks content behind `*` characters when the entry is marked hidden,
    /// preserving whitespace. Mirrors the treatment in `EntryRowView`.
    private var displayContent: String {
        guard result.isContentHidden else { return result.content }
        return result.content.map { $0.isWhitespace ? $0 : "*" }.map(String.init).joined()
    }

    private var hasLinkCard: Bool {
        result.linkAttachment != nil && !result.isContentHidden
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 16)

            if result.isComment {
                commentRowContent
            } else {
                rootRowContent
            }

            Color.clear
                .frame(height: 16)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Root Result

    /// Root entry presentation stripped of the action row, 3-dot menu, and comment
    /// counter. Fire/resurface indicators and link cards are preserved to match the
    /// visual feel of the feed row as closely as possible.
    private var rootRowContent: some View {
        ZStack(alignment: .leading) {
            NavigationLink(
                destination: EntryDetailView(entry: result.toEntry(), feedViewModel: feedViewModel)
            ) {
                Color.clear
                    .contentShape(Rectangle())
            }
            .simultaneousGesture(TapGesture().onEnded { onResultActivated?() })

            VStack(alignment: .leading, spacing: 0) {
                rootHeaderRow
                    // Keep the header above the link card in hit-testing order,
                    // matching the same zIndex comment in EntryRowView.
                    .zIndex(1)

                Color.clear
                    .frame(height: 4)

                if !result.content.isEmpty {
                    contentText

                    Color.clear
                        .frame(height: hasLinkCard ? 8 : 12)
                }

                if let link = result.linkAttachment, !result.isContentHidden {
                    RichLinkCardView(urlString: link.url, title: link.title, imageURL: link.image_url)

                    Color.clear
                        .frame(height: 12)
                }

                if result.content.isEmpty && !hasLinkCard {
                    Color.clear
                        .frame(height: 12)
                }
            }
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
    }

    private var rootHeaderRow: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Style.Timestamp.relative(for: result.created_at, relativeTo: context.date))
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
            }

            if result.resurface_count > 0 {
                HStack(spacing: 0) {
                    Icon("refresh-04", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.resurface)

                    Text("\(result.resurface_count)")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.resurface)
                }
                .padding(.leading, 2)
            }

            if result.fire_count > 0 {
                HStack(spacing: 0) {
                    Icon("fire-03", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.fire)

                    Text("\(result.fire_count)")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.fire)
                }
                .padding(.leading, 2)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Comment Result

    /// Comment result layout: timestamp + C indicator → "Replying to: …" overline →
    /// comment body. No actions, no counters, no link card.
    @ViewBuilder
    private var commentRowContent: some View {
        ZStack(alignment: .leading) {
            if let rootId = result.root_id {
                NavigationLink(
                    destination: CommentDetailView(
                        comment: result.toEntry(),
                        rootId: rootId,
                        feedViewModel: feedViewModel
                    )
                ) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .simultaneousGesture(TapGesture().onEnded { onResultActivated?() })
            }

            VStack(alignment: .leading, spacing: 0) {
                commentHeaderRow

                Color.clear
                    .frame(height: 8)

                if let preview = result.parent_preview {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isPreviewExpanded.toggle()
                        }
                    } label: {
                        Text("RE: \(preview)")
                            .font(.custom("DMSans-Medium", size: 14))
                            .foregroundColor(Style.Color.secondary)
                            .lineLimit(isPreviewExpanded ? nil : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(hex: "282828"))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Color.clear
                        .frame(height: 8)
                }

                commentContentText
            }
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
    }

    private var commentHeaderRow: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Style.Timestamp.relative(for: result.created_at, relativeTo: context.date))
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Shared

    /// Comment body text with detected URLs rendered as link cards below the text,
    /// matching the lightweight LinkCardView style used for root-entry URL attachments.
    private var commentContentText: some View {
        CommentLinkText(text: displayContent)
    }

    /// Plain body text used for root entry results (no inline link detection).
    private var contentText: some View {
        Text(displayContent)
            .font(Style.Typography.body())
            .foregroundColor(Style.Color.primaryText)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
    }
}
