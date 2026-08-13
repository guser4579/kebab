//
//  CollectionActionSheetView.swift
//  kebab
//

import SwiftUI

/// Collection-level management actions (rename / delete), presented as the
/// standard blocky action sheet. Used from CollectionDetailView's header
/// ellipsis and from the chip sheet's ellipsis.
struct CollectionActionSheetView: View {

    let onRename: () -> Void
    let onDelete: () -> Void
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
                    title: "Rename",
                    iconName: "pencil-edit-02",
                    color: Style.Color.primaryText,
                    action: {
                        onRename()
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
