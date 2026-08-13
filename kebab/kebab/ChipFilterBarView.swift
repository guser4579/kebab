//
//  ChipFilterBarView.swift
//  kebab
//

import SwiftUI

// MARK: - ChipFilterBarView

/// Horizontal filter bar above the composer: a static "has link" chip followed
/// by one chip per parent collection (sourced from the collections list, so
/// empty collections appear too). Parents with sub-collections get a chevron;
/// tapping them opens the collection sheet instead of toggling directly —
/// that routing is decided by the owner via `onParentTapped`.
struct ChipFilterBarView: View {

    let parentCollections: [Collection]
    /// Sub-collections for a parent id. Non-empty ⇒ the parent chip shows a chevron.
    let subCollections: (UUID) -> [Collection]
    let hasLinkActive: Bool
    let activeCollectionFilter: CollectionFilter?
    let onToggleHasLink: () -> Void
    let onParentTapped: (Collection) -> Void
    /// Clears the active collection filter (the × on an active chevron chip).
    let onClearCollectionFilter: () -> Void

    var body: some View {
        // GlassEffectContainer lets the chip capsules share one glass pass —
        // required when several glassEffect views sit close together.
        GlassEffectContainer {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Style.Spacing.x2) {
                    ChipButton(
                        label: "has link",
                        isActive: hasLinkActive,
                        onTap: onToggleHasLink
                    )

                    ForEach(parentCollections) { parent in
                        let active = isActive(parent)
                        let hasSubs = !subCollections(parent.id).isEmpty
                        ChipButton(
                            label: chipLabel(for: parent),
                            isActive: active,
                            // Chevron chips swap the glyph by state: chevron invites
                            // opening the sheet; × on an active chip clears the filter
                            // without relaunching the sheet. Label tap still reopens
                            // the sheet to switch scope.
                            trailing: hasSubs ? (active ? .clear : .chevron) : .none,
                            onTap: { onParentTapped(parent) },
                            onClearTap: onClearCollectionFilter
                        )
                    }
                }
                .padding(.horizontal, Style.Spacing.x4)
                .padding(.vertical, Style.Spacing.x3)
            }
        }
        // A horizontal ScrollView claims all vertical height it's offered. Inside
        // the bottom safeAreaInset (which proposes the full screen height) that made
        // the bar balloon vertically, inflating the inset and pushing the composer
        // up with a large void below the chips. Pinning to the ideal vertical size
        // keeps the bar a single compact row.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A parent chip is active when the filter targets the parent itself
    /// ("View all") or any of its sub-collections.
    private func isActive(_ parent: Collection) -> Bool {
        switch activeCollectionFilter {
        case .all(let parentId):
            return parentId == parent.id
        case .single(let id):
            return subCollections(parent.id).contains { $0.id == id }
        case nil:
            return false
        }
    }

    /// "Parent / Sub" while filtered to one of this parent's sub-collections;
    /// otherwise just the parent name.
    private func chipLabel(for parent: Collection) -> String {
        if case .single(let id) = activeCollectionFilter,
           let sub = subCollections(parent.id).first(where: { $0.id == id }) {
            return "\(parent.name) / \(sub.name)"
        }
        return parent.name
    }
}

// MARK: - ChipButton

private struct ChipButton: View {

    enum Trailing {
        case none
        /// Sheet affordance on an inactive chevron chip. Part of the main tap target.
        case chevron
        /// Visible clear (×) target on an active chevron chip — its own button,
        /// so clearing never requires reopening the sheet.
        case clear
    }

    let label: String
    let isActive: Bool
    var trailing: Trailing = .none
    let onTap: () -> Void
    var onClearTap: (() -> Void)? = nil

    private var contentColor: SwiftUI.Color {
        isActive ? Style.Color.primaryText : Style.Color.secondary
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { Haptics.lightTap(); onTap() }) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(Style.Typography.meta())
                        .foregroundColor(contentColor)

                    if trailing == .chevron {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(contentColor)
                    }
                }
                .padding(.leading, Style.Spacing.x3)
                .padding(.trailing, trailing == .clear ? 4 : Style.Spacing.x3)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if trailing == .clear {
                Button(action: { Haptics.lightTap(); onClearTap?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(contentColor)
                        .padding(.trailing, Style.Spacing.x3)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .glassEffect(
            isActive
                ? .regular.tint(Style.Color.composerSend)
                : .regular.tint(Style.Color.composerBackground.opacity(0.5)),
            in: Capsule()
        )
        .animation(Style.Animation.composerState, value: isActive)
    }
}
