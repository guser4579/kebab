//
//  CollectionChipSheetView.swift
//  kebab
//

import SwiftUI

/// Bottom sheet opened by tapping a parent-collection chip that has
/// sub-collections. Selection-first design: a real title (the collection
/// name), then flat hairline-separated rows — "View all", each sub-collection
/// (tick on the active scope), and a "New sub-collection" creation row.
/// Collection management (rename / delete) lives behind the header ellipsis,
/// which the owner routes to the standard CollectionActionSheetView — flat
/// list = choosing, blocky rows = acting.
struct CollectionChipSheetView: View {

    let parent: Collection
    let subCollections: [Collection]
    let activeFilter: CollectionFilter?
    let onSelectAll: () -> Void
    let onSelectSub: (Collection) -> Void
    let onNewSubCollection: () -> Void
    let onManage: () -> Void
    /// Same choreography as the dim-layer tap; drives drag-to-dismiss.
    let onDismiss: () -> Void

    private let sheetTopCornerRadius: CGFloat = 32

    private var isViewAllActive: Bool {
        activeFilter == .all(parentId: parent.id)
    }

    private func isSubActive(_ sub: Collection) -> Bool {
        activeFilter == .single(id: sub.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
                .padding(.top, 12)

            header
                .padding(.top, 20)

            VStack(spacing: 0) {
                selectionRow(title: "View all", isSelected: isViewAllActive, action: onSelectAll)

                ForEach(subCollections) { sub in
                    hairline
                    selectionRow(
                        title: sub.name,
                        isSelected: isSubActive(sub),
                        action: { onSelectSub(sub) }
                    )
                }

                hairline

                newSubCollectionRow
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
        )
        .draggableSheet(onDismiss: onDismiss)
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text(parent.name)
                .font(.custom("DMSans-Medium", size: 16))
                .foregroundColor(Style.Color.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 56)

            HStack {
                Spacer(minLength: 0)

                Button {
                    onManage()
                } label: {
                    Icon("ellipsis", glyphSize: Style.Icon.glyphSmall)
                        .foregroundColor(Style.Color.secondary)
                }
                .buttonStyle(.plain)
                // Enlarge hit area without affecting layout (EntryRowView pattern).
                .padding(10)
                .contentShape(Rectangle())
                .padding(-10)
            }
            .padding(.horizontal, Style.Spacing.x4)
        }
        .frame(height: 24)
    }

    // MARK: - Rows

    private func selectionRow(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)

                Spacer(minLength: Style.Spacing.x3)

                if isSelected {
                    Icon("tick-02")
                        .foregroundColor(Style.Color.composerSend)
                }
            }
            .padding(.horizontal, Style.Layout.entryContentPadding)
            .padding(.vertical, Style.Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newSubCollectionRow: some View {
        Button(action: onNewSubCollection) {
            HStack(spacing: Style.Spacing.x3) {
                Icon("add-circle")
                    .foregroundColor(Style.Color.primaryText)

                Text("New sub-collection")
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

    // Symmetric 16pt insets: separators between choose-rows never touch the
    // screen edges (feed-post dividers stay full-bleed — they separate blocks,
    // not rows).
    private var hairline: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Style.Layout.entryContentPadding)
    }
}
