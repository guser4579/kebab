import SwiftUI

// MARK: - Shared display helpers

enum SearchDisplay {

    /// Preview text for an entry with its line structure intact: masked when
    /// hidden, falling back to link title/domain for link-only entries.
    static func previewText(for entry: Entry) -> String {
        if entry.isContentHidden {
            return entry.content.map { $0.isWhitespace ? $0 : "*" }.map(String.init).joined()
        }
        if !entry.content.isEmpty {
            return entry.content
        }
        if let link = entry.linkAttachment {
            return link.title ?? URL(string: link.url)?.host ?? link.url
        }
        if !entry.imageAttachments.isEmpty {
            return "Image"
        }
        return ""
    }

    /// Snippet text with the actually-matched phrase in a subtly heavier
    /// weight — the only highlight treatment.
    static func attributedSnippet(_ snippet: SearchSnippet, size: CGFloat = 16) -> AttributedString {
        var attributed = AttributedString(snippet.text)
        let count = snippet.text.count
        for range in snippet.highlights {
            guard range.lowerBound >= 0, range.upperBound <= count, !range.isEmpty else { continue }
            let start = attributed.characters.index(attributed.startIndex, offsetBy: range.lowerBound)
            let end = attributed.characters.index(attributed.startIndex, offsetBy: range.upperBound)
            attributed[start..<end].font = .custom("DMSans-Medium", size: size)
        }
        return attributed
    }
}

// MARK: - Snippet rendering

/// Line-structured snippet renderer. Checklist marker lines ("- [ ] " /
/// "- [x] ") render as real Kebab checkboxes — read-only visual state, never
/// a competing tap target — while every other line stays highlighted text.
/// Non-checklist snippets take the exact single-Text path they always had.
struct SearchSnippetView: View {

    let snippet: SearchSnippet
    /// Cap on rendered source lines (structured) / wrapped lines (plain).
    var maxSourceLines: Int = 4
    /// Wrap allowance per structured line, to keep scanning density.
    var perLineLimit: Int = 2

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let highlights: [Range<Int>]
        /// nil = plain text line; true/false = checklist item state.
        let checked: Bool?

        var isBlank: Bool {
            checked == nil && text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        let lines = Self.parse(snippet)
        if lines.contains(where: { $0.checked != nil }) {
            structured(lines)
        } else {
            Text(SearchDisplay.attributedSnippet(snippet))
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .lineSpacing(3)
                .lineLimit(maxSourceLines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func structured(_ lines: [Line]) -> some View {
        let (shown, truncated) = Self.cap(lines, at: maxSourceLines)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { line in
                if line.isBlank {
                    Color.clear
                        .frame(height: 2)
                } else if let checked = line.checked {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: checked ? "checkmark.square" : "square")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(checked ? Style.Color.secondary : Style.Color.primaryText)

                        lineText(line, truncated: truncated && line.id == shown.last?.id)
                            .foregroundColor(checked ? Style.Color.secondary : Style.Color.primaryText)
                            .strikethrough(checked, color: Style.Color.secondary)
                            .lineSpacing(3)
                            .lineLimit(perLineLimit)
                    }
                } else {
                    lineText(line, truncated: truncated && line.id == shown.last?.id)
                        .foregroundColor(Style.Color.primaryText)
                        .lineSpacing(3)
                        .lineLimit(perLineLimit)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineText(_ line: Line, truncated: Bool) -> Text {
        let text = truncated && !line.text.hasSuffix("…") ? line.text + " …" : line.text
        return Text(SearchDisplay.attributedSnippet(
            SearchSnippet(text: text, highlights: line.highlights)
        ))
        .font(Style.Typography.body())
    }

    /// Splits the snippet into lines, mapping global highlight offsets into
    /// per-line local ranges and stripping checklist markers (highlights that
    /// fell inside a marker are dropped, never misdrawn).
    private static func parse(_ snippet: SearchSnippet) -> [Line] {
        var lines: [Line] = []
        var offset = 0
        var id = 0
        for raw in snippet.text.components(separatedBy: "\n") {
            let lineStart = offset
            let lineEnd = offset + raw.count
            offset = lineEnd + 1

            var text = raw
            var local = snippet.highlights.compactMap { range -> Range<Int>? in
                let lower = max(range.lowerBound, lineStart) - lineStart
                let upper = min(range.upperBound, lineEnd) - lineStart
                return lower < upper ? lower..<upper : nil
            }

            // The engine's lead-in ellipsis can sit in front of the first
            // line's marker; look through it so the item still renders.
            var probe = text
            var prefixLength = 0
            if probe.hasPrefix("… "), Checklist.marker(of: String(probe.dropFirst(2))) != nil {
                probe = String(probe.dropFirst(2))
                prefixLength = 2
            }

            var checked: Bool?
            if let marker = Checklist.marker(of: probe) {
                checked = marker == Checklist.checkedMarker
                let drop = prefixLength + marker.count
                text = String(text.dropFirst(drop))
                local = local.compactMap { range -> Range<Int>? in
                    let lower = max(0, range.lowerBound - drop)
                    let upper = range.upperBound - drop
                    return lower < upper ? lower..<upper : nil
                }
            }

            lines.append(Line(id: id, text: text, highlights: local, checked: checked))
            id += 1
        }
        return lines
    }

    /// Caps content lines (blank lines render as spacing but don't count).
    private static func cap(_ lines: [Line], at limit: Int) -> ([Line], truncated: Bool) {
        var shown: [Line] = []
        var contentCount = 0
        for line in lines {
            if line.isBlank {
                if !shown.isEmpty && contentCount < limit {
                    shown.append(line)
                }
                continue
            }
            guard contentCount < limit else {
                // Trim any trailing blank spacer before reporting truncation.
                while shown.last?.isBlank == true { shown.removeLast() }
                return (shown, true)
            }
            shown.append(line)
            contentCount += 1
        }
        while shown.last?.isBlank == true { shown.removeLast() }
        return (shown, false)
    }
}

// MARK: - Depth mark

/// Static nested-context cue: three shortening bars plus the depth number.
/// A glyph, not a control — it says only "this lives inside a larger
/// thought"; orientation happens after the tap.
struct SearchDepthMark: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 3) {
            VStack(alignment: .leading, spacing: 2) {
                bar(width: 9)
                bar(width: 6.5)
                bar(width: 4)
            }
            Text("\(depth)")
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
        }
    }

    private func bar(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Style.Color.secondary)
            .frame(width: width, height: 1.5)
    }
}

// MARK: - Link teaser

/// Low-profile version of the composer's link language: favicon (falling
/// back to the link glyph) + root domain. A teaser, not a preview.
struct SearchLinkTeaser: View {
    let url: URL

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ZStack {
                Icon("link-02", glyphSize: 12)
                    .foregroundColor(Style.Color.secondary)
                CachedAsyncImage(url: url.faviconURL, contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(width: 14, height: 14)
            // Optical centering against the text: the meta font reserves
            // descender space below its glyphs, so the visual center of
            // "generalbread.co" sits a hair above the frame center — the
            // icon rides up ~1pt to meet it.
            .offset(y: -1)

            Text(url.rootDomainDisplay)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Result row

/// One flat search result: the matched object and one quiet meta line.
/// A user scans MATCH / quiet metadata, decides, and taps — the thought's
/// structure is never explained here.
struct SearchResultRowView: View {

    let item: SearchResultItem
    let reacquisitionEntryId: UUID?
    let feedViewModel: FeedViewModel
    let onOpen: (UUID) -> Void
    let onReacquisitionShown: () -> Void

    @State private var reacquireOpacity: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 16)

            ZStack(alignment: .topLeading) {
                NavigationLink(destination: destination) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .simultaneousGesture(TapGesture().onEnded { onOpen(item.entry.id) })

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: Style.Spacing.x3) {
                        SearchSnippetView(snippet: item.snippet)

                        if let thumbnail = thumbnailURL {
                            CachedAsyncImage(url: thumbnail)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    Color.clear
                        .frame(height: 8)

                    metaRow
                }
                .allowsHitTesting(false)
            }
            .padding(.horizontal, Style.Layout.entryContentPadding)

            Color.clear
                .frame(height: 16)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .background(Style.Color.composerBackground.opacity(reacquireOpacity))
        .onAppear { runReacquisitionIfTargeted() }
        .onChange(of: reacquisitionEntryId) { _, _ in runReacquisitionIfTargeted() }
    }

    /// The single meta line every result type shares: a leading cue (depth
    /// mark for comments, link teaser for linked roots, nothing otherwise)
    /// and a trailing "time · collection".
    private var metaRow: some View {
        HStack(spacing: Style.Spacing.x2) {
            if item.isComment {
                SearchDepthMark(depth: item.entry.depth)
            } else if let link = item.entry.linkAttachment,
                      let url = URL(string: link.url) {
                SearchLinkTeaser(url: url)
            }

            Spacer(minLength: Style.Spacing.x2)

            Text(trailingMeta)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .lineLimit(1)
        }
    }

    private var trailingMeta: String {
        let time = Style.Timestamp.relative(for: item.entry.created_at)
        if let name = item.collectionName {
            return "\(time) · \(name)"
        }
        return time
    }

    private var thumbnailURL: URL? {
        guard !item.entry.isContentHidden, !item.isComment else { return nil }
        if let image = item.entry.imageAttachments.first {
            return URL(string: image.url)
        }
        return nil
    }

    /// Exact-context navigation: a comment opens that comment; a root opens
    /// the thought.
    @ViewBuilder
    private var destination: some View {
        if item.entry.parent_id == nil {
            EntryDetailView(entry: item.entry, feedViewModel: feedViewModel)
        } else {
            CommentDetailView(comment: item.entry, rootId: item.rootId, feedViewModel: feedViewModel)
        }
    }

    // MARK: - Reacquisition

    /// Extremely subtle, non-flashy: a quiet surface tint that fades out on
    /// the result just visited. No motion, no scroll changes.
    private func runReacquisitionIfTargeted() {
        guard reacquisitionEntryId == item.entry.id, reacquireOpacity == 0 else { return }
        reacquireOpacity = 0.55
        withAnimation(.easeOut(duration: 1.0).delay(0.15)) {
            reacquireOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            onReacquisitionShown()
        }
    }
}
