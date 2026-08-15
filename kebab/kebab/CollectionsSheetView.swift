//
//  CollectionsSheetView.swift
//  kebab
//

import SwiftUI

/// Where the feed currently is, which decides what the Collections sheet
/// offers. Creation is always relative to the parent scope; management
/// (rename/delete) applies to the deepest selected location.
enum CollectionsSheetContext {
    case all
    case parent(Collection)
    case sub(parent: Collection, sub: Collection)

    var parent: Collection? {
        switch self {
        case .all: return nil
        case .parent(let parent): return parent
        case .sub(let parent, _): return parent
        }
    }

    /// The collection rename/delete act on: the sub when one is selected,
    /// else the parent. Nil from All (nothing to manage).
    var managed: Collection? {
        switch self {
        case .all: return nil
        case .parent(let parent): return parent
        case .sub(_, let sub): return sub
        }
    }
}

/// Contextual action launcher behind the pinned + while a collection or
/// sub-collection is selected (from All the + goes straight to full-screen
/// collection creation instead). Titled with the managed collection's name;
/// flat hairline rows route to the shared full-screen naming surface — the
/// sheet itself never becomes an editing surface. Deletion is a separated,
/// restrained destructive section: a small pill plus one line saying what
/// happens to the entries.
struct CollectionsSheetView: View {

    let context: CollectionsSheetContext
    /// Routes to the full-screen New Sub-collection surface (parent context only).
    let onNewSubCollection: () -> Void
    /// Routes to the full-screen Rename surface for the managed collection.
    let onRename: () -> Void
    /// Owner dismisses the sheet and raises the descriptive confirmation.
    let onRequestDelete: () -> Void
    let onDismiss: () -> Void

    private let sheetTopCornerRadius: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
                .padding(.top, 12)
                .frame(maxWidth: .infinity)

            header
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 0) {
                if case .parent = context {
                    newSubRow
                    hairline
                }

                renameRow

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
        Text(context.managed?.name ?? "")
            .font(.custom("DMSans-Medium", size: 16))
            .foregroundColor(Style.Color.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 56)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Action rows

    /// The object's name lives in the title (and is prefilled on the editing
    /// surface) — row labels stay generic.
    private var renameLabel: String {
        if case .sub = context {
            return "Rename sub-collection"
        }
        return "Rename collection"
    }

    private var newSubRow: some View {
        actionRow(title: "New sub-collection", iconName: "add-circle", action: onNewSubCollection)
    }

    private var renameRow: some View {
        actionRow(title: renameLabel, iconName: "pencil-edit-02", action: onRename)
    }

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

    /// What deletion means for the entries — repeated in the confirmation
    /// alert before anything is destroyed.
    private var deleteCaption: String {
        switch context {
        case .sub(let parent, _):
            return "Entries will move to \(parent.name)."
        default:
            return "Entries will move to All entries."
        }
    }

    /// Generic like the rename label — the object's name lives in the title.
    private var deleteLabel: String {
        if case .sub = context {
            return "Delete sub-collection"
        }
        return "Delete collection"
    }

    private var deleteSection: some View {
        VStack(spacing: Style.Spacing.x2) {
            Button(action: onRequestDelete) {
                Text(deleteLabel)
                    .font(.custom("DMSans-Medium", size: 14))
                    .foregroundColor(Style.Color.destructive)
                    .lineLimit(1)
                    .padding(.horizontal, Style.Spacing.x4 + Style.Spacing.x2)
                    .frame(height: 36)
                    .background(Capsule().fill(Style.Color.destructive.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Text(deleteCaption)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
