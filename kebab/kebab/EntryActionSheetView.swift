import SwiftUI

/// Entry/comment action sheet in the app's standard contextual-sheet
/// language (matching the Collections sheet): centered title, flat
/// hairline-separated rows with leading icons, and the destructive action
/// as a small centered pill rather than another row.
struct EntryActionSheetView: View {

    let entry: Entry
    let onDelete: () -> Void
    /// Hide / unhide entry or comment body.
    let onToggleContentHidden: () -> Void
    /// Presents full-screen text editor after the host dismisses this sheet.
    let onBeginTextEdit: () -> Void
    /// Opens the reminder sheet (entry's existing reminder, or a new one).
    /// Root entries only — reminders belong to entries, not comments.
    var onRemindMe: (() -> Void)? = nil
    /// Presents the add-to-collection flow. Only shown for root entries not currently in a collection.
    var onAddToCollection: (() -> Void)? = nil
    /// Opens the move-entry destination picker. Shown for root entries already in a collection/sub-collection.
    var onMoveEntry: (() -> Void)? = nil
    let onDismiss: () -> Void

    private let sheetTopCornerRadius: CGFloat = 32

    private var isComment: Bool {
        entry.parent_id != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
                .padding(.top, 12)
                .frame(maxWidth: .infinity)

            header
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 0) {
                actionRow(
                    title: isComment ? "Edit comment" : "Edit entry",
                    iconName: "pencil-edit-02",
                    action: { onBeginTextEdit() }
                )

                if !isComment {
                    if let onRemindMe {
                        hairline
                        actionRow(
                            title: "Remind me",
                            iconName: "clock-01",
                            action: { onRemindMe() }
                        )
                    }

                    if let onMoveEntry {
                        hairline
                        actionRow(
                            title: "Move entry",
                            iconName: "doub-arrows",
                            action: { onMoveEntry() }
                        )
                    }

                    if let onAddToCollection {
                        hairline
                        actionRow(
                            title: "Add to collection",
                            iconName: "folder",
                            action: { onAddToCollection() }
                        )
                    }
                }

                hairline

                actionRow(
                    title: isComment
                        ? (entry.isContentHidden ? "Unhide comment" : "Hide comment")
                        : (entry.isContentHidden ? "Unhide entry" : "Hide entry"),
                    iconName: entry.isContentHidden ? "eye" : "eye-closed",
                    action: {
                        onToggleContentHidden()
                        onDismiss()
                    }
                )

                deleteSection
                    .padding(.top, Style.Spacing.x4 + Style.Spacing.x2)
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.background)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: sheetTopCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: sheetTopCornerRadius
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: sheetTopCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: sheetTopCornerRadius
            )
            .stroke(Style.Color.separator, lineWidth: 1)
            // Extend the stroked shape far below the visible sheet so its
            // bottom edge can never appear when the sheet is stretched
            // upward; only the top corners and sides render.
            .padding(.bottom, -400)
        )
        .draggableSheet(onDismiss: onDismiss)
    }

    // MARK: - Header

    private var header: some View {
        Text(isComment ? "Comment actions" : "Entry actions")
            .font(.custom("DMSans-Medium", size: 16))
            .foregroundColor(Style.Color.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 56)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    private func actionRow(
        title: String,
        iconName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { action() }) {
            HStack(spacing: Style.Spacing.x3) {
                Icon(iconName)
                    .foregroundColor(Style.Color.primaryText)

                Text(title)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Style.Layout.entryContentPadding)
            .padding(.vertical, Style.Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Symmetric 16pt insets: separators between rows never touch the screen
    // edges (feed-post dividers stay full-bleed — they separate blocks,
    // not rows).
    private var hairline: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Style.Layout.entryContentPadding)
    }

    // MARK: - Destructive section

    private var deleteSection: some View {
        Button(action: {
            onDelete()
            onDismiss()
        }) {
            Text(isComment ? "Delete comment" : "Delete entry")
                .font(.custom("DMSans-Medium", size: 14))
                .foregroundColor(Style.Color.destructive)
                .lineLimit(1)
                .padding(.horizontal, Style.Spacing.x4 + Style.Spacing.x2)
                .frame(height: 36)
                .background(Capsule().fill(Style.Color.destructive.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}
