import SwiftUI

struct EntryRowView: View {

    let entry: Entry
    var feedViewModel: FeedViewModel?
    /// When false the resurface button is hidden (collection context).
    var showResurface: Bool = true
    /// When false the bottom hairline is omitted — the newest (last) entry in a
    /// feed list sits flush above the composer with no stray line. Kept true for
    /// a sole entry, which rests at the top of the screen and needs closure.
    var showBottomSeparator: Bool = true
    var onResultActivated: (() -> Void)?
    var onMoreTapped: (() -> Void)?
    var onResurfaceTapped: (() -> Void)?
    var onPinTapped: (() -> Void)?
    var onFireTapped: (() -> Void)?
    /// Tapping the warning glyph on a pending entry that permanently failed
    /// to sync (Retry / Discard alert lives in the host).
    var onPendingWarningTapped: (() -> Void)? = nil
    /// Passed through to EntryDetailView when the entry is opened from collection context.
    var onRemoveFromCollection: (() async -> Void)? = nil
    /// Post-capture settling: a brief surface emphasis so the eye lands on
    /// the thing just saved. A receipt, not a celebration.
    var isSettling: Bool = false
    /// True only in the All scope: the entry's most specific collection home
    /// renders quietly in the bottom-right metadata area. Collection scopes
    /// already carry that context and pass false.
    var showsCollectionProvenance: Bool = false

    // Feed-only long-body collapsing (~8 rendered lines). Expansion is
    // ephemeral by design: @State dies with the row, so a genuine feed
    // reconstruction returns to collapsed. Attachments never count toward
    // the threshold — only the body content collapses.
    private static let collapseLineLimit = 8
    @State private var isBodyExpanded = false
    /// Measured natural heights of the body at full length and at the
    /// collapse cap — a rendered-size decision, not a character count.
    @State private var fullBodyHeight: CGFloat = 0
    @State private var cappedBodyHeight: CGFloat = 0

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
        .background(isSettling ? Style.Color.composerBackground : SwiftUI.Color.clear)
        .animation(.easeOut(duration: 0.45), value: isSettling)
    }

    private var hasLinkCard: Bool {
        entry.linkAttachment != nil && !entry.isContentHidden
    }

    private var entryContent: some View {
        ZStack(alignment: .leading) {
            // Pending entries have no server thread yet — no detail navigation.
            if let feedViewModel = feedViewModel, !entry.isPending {
                NavigationLink(destination: EntryDetailView(
                    entry: entry,
                    feedViewModel: feedViewModel,
                    onRemoveFromCollection: onRemoveFromCollection
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

                let hasImages = !entry.imageAttachments.isEmpty && !entry.isContentHidden

                if !entry.content.isEmpty {
                    contentText

                    bodyToggle

                    Color.clear
                        .frame(height: (hasLinkCard || hasImages) ? 8 : 12)
                }

                if hasImages {
                    EntryImageStripView(attachments: entry.imageAttachments)

                    Color.clear
                        .frame(height: 12)
                }

                if let link = entry.linkAttachment, !entry.isContentHidden {
                    RichLinkCardView(urlString: link.url, title: link.title, imageURL: link.image_url, footerOnlyOpensLink: true)

                    Color.clear
                        .frame(height: 12)
                }

                if entry.content.isEmpty && !hasLinkCard && !hasImages {
                    Color.clear
                        .frame(height: 12)
                }

                // Rendered identically from the moment of posting so promotion
                // never changes the row's height (the post-submit jiggle).
                // Only interactivity waits for the server row to exist.
                actionRow
                    .allowsHitTesting(!entry.isPending)

                Color.clear
                    .frame(height: 8)

                bottomMetaRow
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

            // Pending mark: clock while waiting to sync; tappable warning if
            // the server permanently rejected it. "Indicate the exception,
            // never the mode" — synced entries show nothing.
            if entry.isPending {
                if entry.pendingFailed {
                    Button {
                        onPendingWarningTapped?()
                    } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Style.Color.destructive)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .contentShape(Rectangle())
                    .padding(-8)
                } else {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Style.Color.secondary)
                        .padding(.leading, 2)
                }
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

            Spacer(minLength: 0)

            // Rendered identically while pending so promotion causes no
            // pop-in; interactivity waits for the server row (its menu's
            // actions all need it to exist).
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
            .allowsHitTesting(!entry.isPending)
        }
    }

    private var isChecklistBody: Bool {
        !entry.isContentHidden && Checklist.hasChecklist(entry.content)
    }

    @ViewBuilder
    private var contentText: some View {
        if isChecklistBody {
            checklistContent
        } else {
            Text(displayContent)
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .lineSpacing(4)
                .lineLimit(isCollapseCandidate && !isBodyExpanded ? Self.collapseLineLimit : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .background {
                    // Measurement only for bodies that could plausibly exceed
                    // the cap — every other row pays nothing.
                    if isCollapseCandidate {
                        bodyMeasurementTwins
                    }
                }
        }
    }

    // MARK: - Long-body collapsing

    /// Cheap gate ahead of measurement: at 16pt DM Sans on common widths a
    /// body needs well over 200 characters (or more hard lines than the cap)
    /// before it can reach ~8 rendered lines.
    private var isCollapseCandidate: Bool {
        displayContent.count > 200
            || displayContent.components(separatedBy: "\n").count > Self.collapseLineLimit
    }

    /// Invisible twins of the body at full length and at the collapse cap,
    /// laid out at the same width as the visible text. Their height delta is
    /// the truncation decision — rendered size, not character count.
    private var bodyMeasurementTwins: some View {
        ZStack(alignment: .topLeading) {
            measurementText(lineLimit: nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    fullBodyHeight = $0
                }
            measurementText(lineLimit: Self.collapseLineLimit)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    cappedBodyHeight = $0
                }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func measurementText(lineLimit: Int?) -> some View {
        Text(displayContent)
            .font(Style.Typography.body())
            .lineSpacing(4)
            .lineLimit(lineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Whether the body genuinely overflows the collapsed presentation.
    /// Checklists decide by line budget; plain text by measured height.
    private var bodyOverflowsCollapse: Bool {
        if isChecklistBody {
            return checklistLineCount > Self.collapseLineLimit
        }
        return isCollapseCandidate && fullBodyHeight > cappedBodyHeight + 1
    }

    /// Quiet inline toggle below the body. Expansion and collapse are
    /// deliberately instant — no height, opacity, or row-movement animation.
    @ViewBuilder
    private var bodyToggle: some View {
        if bodyOverflowsCollapse || isBodyExpanded {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isBodyExpanded.toggle()
                }
            } label: {
                Text(isBodyExpanded ? "Show less" : "Show more")
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    /// Visual line count of a checklist body: items are one line each; text
    /// blocks count their hard lines.
    private var checklistLineCount: Int {
        Checklist.segments(of: entry.content).reduce(0) { total, segment in
            switch segment {
            case .text(_, let block):
                return total + block.components(separatedBy: "\n").count
            case .item:
                return total + 1
            }
        }
    }

    /// Segments actually rendered: the full list, or — collapsed — a prefix
    /// capped at the line budget. Truncating by whole segments/lines keeps
    /// checkbox structure, paragraphs, and line breaks fully intact.
    private var visibleChecklistSegments: [Checklist.Segment] {
        let segments = Checklist.segments(of: entry.content)
        guard !isBodyExpanded, checklistLineCount > Self.collapseLineLimit else {
            return segments
        }
        var budget = Self.collapseLineLimit
        var shown: [Checklist.Segment] = []
        for segment in segments {
            guard budget > 0 else { break }
            switch segment {
            case .item:
                shown.append(segment)
                budget -= 1
            case .text(let id, let block):
                let lines = block.components(separatedBy: "\n")
                if lines.count <= budget {
                    shown.append(segment)
                    budget -= lines.count
                } else {
                    shown.append(.text(id: id, lines.prefix(budget).joined(separator: "\n")))
                    budget = 0
                }
            }
        }
        return shown
    }

    // Checklist entries render their marker lines as tappable checkbox rows
    // directly in the feed — no detail-screen round trip to check an item.
    // Text segments stay hit-transparent so entry navigation still works;
    // only the checkbox buttons intercept taps.
    private var checklistContent: some View {
        VStack(alignment: .leading, spacing: Style.Spacing.x2) {
            ForEach(visibleChecklistSegments) { segment in
                switch segment {
                case .text(_, let block):
                    Text(block)
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.primaryText)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                case .item(_, let lineIndex, let text, let checked):
                    // The Spacer sits OUTSIDE the button: only the checkbox
                    // and its label toggle. The rest of the row's width falls
                    // through to the entry's normal open-detail behavior.
                    HStack(spacing: 0) {
                        Button {
                            guard let feedViewModel else { return }
                            Task {
                                await feedViewModel.toggleChecklistItem(entry: entry, lineIndex: lineIndex)
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Style.Spacing.x3) {
                                Image(systemName: checked ? "checkmark.square" : "square")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(checked ? Style.Color.secondary : Style.Color.primaryText)

                                Text(text)
                                    .font(Style.Typography.body())
                                    .foregroundColor(checked ? Style.Color.secondary : Style.Color.primaryText)
                                    .strikethrough(checked, color: Style.Color.secondary)
                                    .lineSpacing(4)
                                    .multilineTextAlignment(.leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Toggling needs the server row; pending lists sync in
                        // under a second online.
                        .allowsHitTesting(!entry.isPending && feedViewModel != nil)

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bottom metadata line: comment count leading (unchanged), and — in the
    /// All scope only — the entry's direct collection home trailing, in the
    /// same quiet language Search uses for collection metadata.
    @ViewBuilder
    private var bottomMetaRow: some View {
        let count = entry.comment_count ?? 0
        let provenance = showsCollectionProvenance ? entry.collection_name : nil
        if count > 0 || provenance != nil {
            HStack(alignment: .center, spacing: Style.Spacing.x2) {
                if count > 0 {
                    Text(count == 1 ? "1 comment" : "\(count) comments")
                        .font(.custom("DMSans-Regular", size: 16))
                        .foregroundColor(Style.Color.secondary)
                }

                Spacer(minLength: 0)

                if let provenance {
                    Text(provenance)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 24)
            // Metadata is never a tap target — the row's open behavior owns
            // this area.
            .allowsHitTesting(false)
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
