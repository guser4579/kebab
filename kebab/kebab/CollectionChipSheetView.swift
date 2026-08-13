//
//  CollectionChipSheetView.swift
//  kebab
//

import SwiftUI

/// Bottom sheet opened by tapping a parent-collection chip that has
/// sub-collections. Mirrors the EntryActionSheetView presentation chrome.
///
/// Top group — filter targets: "View all" (parent + subs) and one row per
/// sub-collection, with a tick on the active target. Tapping the active row
/// clears the filter (single-select toggle semantics live in the owner).
/// Bottom group — collection management: new sub-collection, rename, delete.
struct CollectionChipSheetView: View {

    let parent: Collection
    let subCollections: [Collection]
    let activeFilter: CollectionFilter?
    let onSelectAll: () -> Void
    let onSelectSub: (Collection) -> Void
    let onNewSubCollection: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    private let sheetTopCornerRadius: CGFloat = 32
    private let actionRowCornerRadius: CGFloat = 16
    private let actionRowSpacing: CGFloat = 8
    private let sheetPaddingTop: CGFloat = 24
    private let sheetPaddingBottom: CGFloat = 40
    private let sheetPaddingHorizontal: CGFloat = 16
    private let actionRowPaddingVertical: CGFloat = 12
    private let actionRowPaddingHorizontal: CGFloat = 16

    private var isViewAllActive: Bool {
        activeFilter == .all(parentId: parent.id)
    }

    private func isSubActive(_ sub: Collection) -> Bool {
        activeFilter == .single(id: sub.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(parent.name)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .padding(.horizontal, sheetPaddingHorizontal + actionRowPaddingHorizontal)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: actionRowSpacing) {
                selectionRow(
                    title: "View all",
                    isSelected: isViewAllActive,
                    action: { onSelectAll() }
                )

                ForEach(subCollections) { sub in
                    selectionRow(
                        title: sub.name,
                        isSelected: isSubActive(sub),
                        action: { onSelectSub(sub) }
                    )
                }

                Rectangle()
                    .fill(Style.Color.separator)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                actionRow(
                    title: "New sub-collection",
                    iconName: "add-circle",
                    color: Style.Color.primaryText,
                    action: { onNewSubCollection() }
                )
                actionRow(
                    title: "Rename",
                    iconName: "pencil-edit-02",
                    color: Style.Color.primaryText,
                    action: { onRename() }
                )
                actionRow(
                    title: "Delete",
                    iconName: "trash-2",
                    color: Style.Color.destructive,
                    action: { onDelete() }
                )
            }
            .padding(.horizontal, sheetPaddingHorizontal)
            .padding(.bottom, sheetPaddingBottom)
        }
        .padding(.top, sheetPaddingTop)
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

    private func selectionRow(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Icon("tick-02")
                        .foregroundColor(Style.Color.composerSend)
                }
            }
            .padding(.vertical, actionRowPaddingVertical)
            .padding(.horizontal, actionRowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.Color.composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: actionRowCornerRadius))
        }
        .buttonStyle(.plain)
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
                Spacer(minLength: 0)
                Icon(iconName)
                    .foregroundColor(color)
            }
            .padding(.vertical, actionRowPaddingVertical)
            .padding(.horizontal, actionRowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.Color.composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: actionRowCornerRadius))
        }
        .buttonStyle(.plain)
    }
}
