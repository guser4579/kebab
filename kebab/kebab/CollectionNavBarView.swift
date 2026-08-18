//
//  CollectionNavBarView.swift
//  kebab
//

import SwiftUI

/// Primary feed navigation between the sticky header and the feed:
/// `All → Parent collection → optional Sub-collection refinement`.
///
/// Two deliberately different layers: parent collections are structural text
/// tabs (underline marks the selection); sub-collections are a subordinate,
/// contextual chip row that only exists while the selected parent has subs.
/// A selected parent is always its aggregate view — the chips are optional
/// refinements that toggle on and off. The + pinned at the trailing edge is a
/// navigation-level action (collection creation and management), never
/// another collection — tabs scroll beneath its stationary opaque mask.
struct CollectionNavBarView: View {

    let parentCollections: [Collection]
    /// Sub-collections for a parent id; empty ⇒ no second row for that parent.
    let subCollections: (UUID) -> [Collection]
    let activeFilter: CollectionFilter?
    /// Resolves a sub-collection's parent id (used to keep the parent tab
    /// selected while a sub-collection refines the feed).
    let parentIdForCollection: (UUID) -> UUID?
    let onSelectAll: () -> Void
    let onSelectParent: (Collection) -> Void
    /// Toggle semantics live with the owner: selecting the active
    /// sub-collection again returns to the parent aggregate.
    let onSelectSub: (Collection) -> Void
    let onPlusTapped: () -> Void

    private let rowHeight: CGFloat = 44
    /// Width of the stationary background under the pinned +. Sized so the
    /// icon's center lines up with the search control above (24pt glyph frame
    /// + 16pt trailing margin) with breathing room for tabs to vanish under.
    private let plusMaskWidth: CGFloat = 56

    /// The parent tab that should render as selected: the filtered parent
    /// itself, or the parent of the filtered sub-collection.
    private var selectedParentId: UUID? {
        switch activeFilter {
        case .all(let parentId):
            return parentId
        case .single(let id):
            return parentIdForCollection(id)
        case nil:
            return nil
        }
    }

    private var selectedParent: Collection? {
        guard let id = selectedParentId else { return nil }
        return parentCollections.first { $0.id == id }
    }

    /// Second row exists only when the selected parent actually has subs
    /// (and never while All is selected).
    private var visibleSubCollections: [Collection] {
        guard let parent = selectedParent else { return [] }
        return subCollections(parent.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            parentRow

            if !visibleSubCollections.isEmpty {
                subRow(subs: visibleSubCollections)
                    .transition(.opacity)
            }
        }
        .background(Style.Color.background)
        .animation(Style.Animation.composerState, value: selectedParentId)
    }

    // MARK: - Parent tabs

    private var parentRow: some View {
        ZStack(alignment: .trailing) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Style.Spacing.x4 + Style.Spacing.x2) {
                        parentTab(
                            label: "All",
                            isSelected: selectedParentId == nil,
                            action: onSelectAll
                        )
                        .id("all")

                        ForEach(parentCollections) { parent in
                            parentTab(
                                label: parent.name.collectionCompactDisplayName,
                                isSelected: selectedParentId == parent.id,
                                action: { onSelectParent(parent) }
                            )
                            .id(parent.id)
                        }
                    }
                    .padding(.leading, Style.Spacing.x4)
                    // Room to scroll the last tab fully out from beneath the
                    // pinned + mask.
                    .padding(.trailing, plusMaskWidth + Style.Spacing.x2)
                }
                .onChange(of: selectedParentId) { _, newValue in
                    // Center the selected tab: minimal scrolling would leave
                    // it half-hidden beneath the pinned +'s opaque mask.
                    withAnimation(Style.Animation.composerState) {
                        proxy.scrollTo(
                            newValue.map(AnyHashable.init) ?? AnyHashable("all"),
                            anchor: .center
                        )
                    }
                }
            }

            // Stationary opaque mask in the page background color: scrolling
            // tab text simply disappears beneath it — no blur, glass, shadow,
            // or transparency. The + reads as part of the navigation row.
            ZStack(alignment: .trailing) {
                Style.Color.background

                plusButton
                    .padding(.trailing, Style.Spacing.x4)
                    // Center the glyph on the tab *text*, not the full
                    // row-plus-underline box (text zone excludes the 8pt of
                    // underline + inset at the bottom, so its center sits
                    // 4pt above the row's).
                    .offset(y: -4)
            }
            .frame(width: plusMaskWidth, height: rowHeight)
        }
        .frame(height: rowHeight)
    }

    private func parentTab(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { action() }) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Text(label)
                    .font(isSelected
                        ? .custom("DMSans-Medium", size: 16)
                        : Style.Typography.body())
                    .foregroundColor(isSelected ? Style.Color.primaryText : Style.Color.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Underline is the selected treatment; a clear placeholder
                // keeps unselected labels on the same baseline.
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? Style.Color.primaryText : SwiftUI.Color.clear)
                    .frame(height: 2)
                    .padding(.bottom, 6)
            }
            .frame(height: rowHeight)
            // Comfortable touch target without visually widening the tab.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var plusButton: some View {
        Button(action: { onPlusTapped() }) {
            // All → +; any collection/sub-collection context → gear. Cosmetic
            // only: the same contextual action sits behind both glyphs.
            Group {
                if activeFilter == nil {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        // Same 24pt glyph frame as the header icons so the +
                        // centers under the search control.
                        .frame(width: Style.Icon.grid, height: Style.Icon.grid)
                } else {
                    Icon("settings", glyphSize: 20)
                }
            }
            .foregroundColor(Style.Color.primaryText)
        }
        .buttonStyle(.plain)
        // The container animates on scope change; the glyph swap must not —
        // it lands instantly.
        .transaction { $0.animation = nil }
        // Enlarge hit area without affecting layout (EntryRowView pattern).
        .padding(10)
        .contentShape(Rectangle())
        .padding(-10)
    }

    // MARK: - Sub-collection chips

    private func subRow(subs: [Collection]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Style.Spacing.x2) {
                ForEach(subs) { sub in
                    subChip(
                        label: sub.name.collectionCompactDisplayName,
                        isSelected: activeFilter == .single(id: sub.id),
                        action: { onSelectSub(sub) }
                    )
                }
            }
            .padding(.horizontal, Style.Spacing.x4)
            .padding(.bottom, Style.Spacing.x3)
            // Optically centers the pills between the parent-tab underline
            // and the bottom edge of the sticky region (the underline's own
            // 6pt inset contributes to the perceived gap above).
            .padding(.top, Style.Spacing.x2)
        }
        // Horizontal ScrollViews claim all offered height; pin to content.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func subChip(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { action() }) {
            Text(label)
                .font(Style.Typography.pill(selected: isSelected))
                .foregroundColor(
                    isSelected ? Style.Color.composerSendForeground : Style.Color.secondary
                )
                .lineLimit(1)
                .padding(.horizontal, Style.Spacing.x3)
                .frame(height: 32)
                // Flat fills only — the chips are quiet refinements, not
                // elevated controls.
                .background(
                    Capsule().fill(
                        isSelected ? Style.Color.composerSend : Style.Color.composerBackground
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Style.Animation.composerState, value: isSelected)
    }
}
