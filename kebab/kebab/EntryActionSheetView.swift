//
//  EntryActionSheetView.swift
//  kebab
//

import SwiftUI

struct EntryActionSheetView: View {

    let entry: Entry
    let onDelete: () -> Void
    /// Hide / unhide entry or comment body (unchanged behavior).
    let onToggleContentHidden: () -> Void
    /// Presents full-screen text editor after the host dismisses this sheet.
    let onBeginTextEdit: () -> Void
    /// Presents the add-to-collection flow. Only shown for root entries (parent_id == nil).
    var onAddToCollection: (() -> Void)? = nil
    /// Removes the entry from its current collection. When non-nil, shown instead of onAddToCollection.
    var onRemoveFromGroup: (() -> Void)? = nil
    let onDismiss: () -> Void

    private let sheetTopCornerRadius: CGFloat = 32
    private let actionRowCornerRadius: CGFloat = 16
    private let actionRowSpacing: CGFloat = 8
    private let sheetPaddingTop: CGFloat = 32
    private let sheetPaddingBottom: CGFloat = 40
    private let sheetPaddingHorizontal: CGFloat = 16
    private let actionRowPaddingVertical: CGFloat = 12
    private let actionRowPaddingHorizontal: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: actionRowSpacing) {
                actionRow(
                    title: entry.parent_id == nil ? "Edit entry" : "Edit comment",
                    iconName: "pencil-edit-02",
                    color: Style.Color.primaryText,
                    action: {
                        onBeginTextEdit()
                    }
                )
                if entry.parent_id == nil {
                    if let onRemoveFromGroup {
                        actionRow(
                            title: "Remove from group",
                            iconName: "folder-minus",
                            color: Style.Color.primaryText,
                            action: {
                                onRemoveFromGroup()
                            }
                        )
                    } else {
                        actionRow(
                            title: "Add to collection",
                            iconName: "folder",
                            color: Style.Color.primaryText,
                            action: {
                                onAddToCollection?()
                            }
                        )
                    }
                }
                actionRow(
                    title: entry.parent_id == nil
                        ? (entry.isContentHidden ? "Unhide entry" : "Hide entry")
                        : (entry.isContentHidden ? "Unhide comment" : "Hide comment"),
                    iconName: entry.isContentHidden ? "eye" : "eye-closed",
                    color: Style.Color.primaryText,
                    action: {
                        onToggleContentHidden()
                        onDismiss()
                    }
                )
                actionRow(
                    title: "Delete",
                    iconName: "trash-2",
                    color: Style.Color.destructive,
                    action: {
                        onDelete()
                        onDismiss()
                    }
                )
            }
            .padding(.horizontal, sheetPaddingHorizontal)
            .padding(.top, sheetPaddingTop)
            .padding(.bottom, sheetPaddingBottom)
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
        )
    }

    private func actionRow(
        title: String,
        iconName: String,
        color: SwiftUI.Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(color)
                    .lineSpacing(24 - 16)
                Spacer(minLength: 0)
                Icon(iconName)
                    .foregroundColor(color)
            }
            .padding(.top, actionRowPaddingVertical)
            .padding(.bottom, actionRowPaddingVertical)
            .padding(.leading, actionRowPaddingHorizontal)
            .padding(.trailing, actionRowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.Color.composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: actionRowCornerRadius))
        }
        .buttonStyle(.plain)
    }
}
