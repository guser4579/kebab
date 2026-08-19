//
//  EntryContentView.swift
//  kebab
//

import SwiftUI

/// The root Entry's content block — meta row (absolute timestamp, resurface/
/// fire counters, optional ellipsis), checklist-aware body, image strip, link
/// card, optional root action row, and the thread comment counter.
///
/// One presentation, two hosts: `EntryDetailView` (fully interactive) and the
/// thread spine in `CommentDetailView` (contextual display — no ellipsis, no
/// action row, checklist toggles still live). Purely presentational: every
/// mutation is a closure the host owns.
struct EntryContentView: View {

    let entry: Entry
    /// Total thread comment count; hidden when zero.
    let commentCount: Int
    /// True when the entry heads a thread: content sits in the shared
    /// thread column beside the gutter. False renders the normal full-width
    /// entry, byte-for-byte as before threads existed.
    var isThreaded: Bool = false
    var showsEllipsis: Bool = true
    var showsActionRow: Bool = true
    var showResurface: Bool = true
    /// The entry's reminder, when it has a scheduled one. Rendered as quiet
    /// meta beside the timestamp; nil renders exactly as before.
    var reminder: EntryReminder? = nil
    var remindersCanDeliver: Bool = true
    var onReminderTapped: (() -> Void)? = nil
    var onMoreTapped: (() -> Void)? = nil
    var onResurfaceTapped: (() -> Void)? = nil
    var onFireTapped: (() -> Void)? = nil
    /// Called with the pre-toggle entry snapshot and the tapped checklist
    /// line index; the host owns the optimistic patch and rollback.
    var onToggleChecklistItem: ((Entry, Int) -> Void)? = nil

    private var displayContent: String {
        if entry.isContentHidden {
            return entry.content.map { char in
                char.isWhitespace ? char : "*"
            }.map(String.init).joined()
        } else {
            return entry.content
        }
    }

    private var hasLinkCard: Bool {
        entry.linkAttachment != nil && !entry.isContentHidden
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Color.clear
                .frame(height: 4)

            let hasImages = !entry.imageAttachments.isEmpty
                && !entry.isContentHidden

            if !entry.content.isEmpty {
                contentText

                Color.clear
                    .frame(height: (hasLinkCard || hasImages) ? 8 : 12)
            }

            if hasImages {
                EntryImageStripView(attachments: entry.imageAttachments)

                Color.clear
                    .frame(height: 12)
            }

            if let link = entry.linkAttachment, !entry.isContentHidden {
                RichLinkCardView(urlString: link.url, title: link.title, imageURL: link.image_url)

                Color.clear
                    .frame(height: 12)
            }

            if entry.content.isEmpty && !hasLinkCard && !hasImages {
                Color.clear
                    .frame(height: 12)
            }

            if showsActionRow {
                EntryRootActionRow(
                    entry: entry,
                    feedViewModel: nil,
                    includeChat: false,
                    showResurface: showResurface,
                    onResurfaceTapped: onResurfaceTapped,
                    onFireTapped: onFireTapped
                )

                Color.clear
                    .frame(height: 8)
            }

            commentCounter
        }
        .padding(.leading, isThreaded ? ThreadRailOverlay.contentLeading : Style.Layout.entryContentPadding)
        .padding(.trailing, Style.Layout.entryContentPadding)
    }

    @ViewBuilder
    private var commentCounter: some View {
        if commentCount > 0 {
            Text(commentCount == 1 ? "1 comment" : "\(commentCount) comments")
                .font(.custom("DMSans-Regular", size: 16))
                .foregroundColor(Style.Color.secondary)
                .frame(height: 24, alignment: .leading)
        }
    }

    private var headerRow: some View {
        HStack {
            Text(Style.Timestamp.absolute(for: entry.created_at))
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

            if let reminder, reminder.lifecycle() == .scheduled {
                ReminderAffordanceView(
                    reminder: reminder,
                    canDeliver: remindersCanDeliver,
                    onTap: onReminderTapped
                )
                .padding(.leading, 2)
                .layoutPriority(1)
            }

            Spacer(minLength: 0)

            if showsEllipsis {
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    onMoreTapped?()
                } label: {
                    Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.secondary)
                }
            }
        }
        // The meta line is a constant 24pt tall whether or not the ellipsis
        // (a 24pt icon grid) is present, so the thread node — placed at a
        // fixed 28pt centerline — stays optically locked to the timestamp.
        // No-op wherever the ellipsis already sets the height.
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private var contentText: some View {
        if !entry.isContentHidden, Checklist.hasChecklist(entry.content) {
            checklistContent
        } else {
            Text(displayContent)
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Checklist rendering mirrors the feed row: tappable items, strikethrough
    // completion. The host's closure owns the optimistic patch.
    private var checklistContent: some View {
        VStack(alignment: .leading, spacing: Style.Spacing.x2) {
            ForEach(Checklist.segments(of: entry.content)) { segment in
                switch segment {
                case .text(_, let block):
                    Text(block)
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.primaryText)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .item(_, let lineIndex, let text, let checked):
                    Button {
                        onToggleChecklistItem?(entry, lineIndex)
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

                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
