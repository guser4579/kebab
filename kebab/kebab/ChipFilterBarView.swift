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

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)

            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Style.Spacing.x2) {
                        ChipButton(
                            label: "has link",
                            isActive: hasLinkActive,
                            onTap: onToggleHasLink
                        )

                        ForEach(parentCollections) { parent in
                            ChipButton(
                                label: chipLabel(for: parent),
                                isActive: isActive(parent),
                                showsChevron: !subCollections(parent.id).isEmpty,
                                onTap: { onParentTapped(parent) }
                            )
                        }
                    }
                    .padding(.horizontal, Style.Spacing.x4)
                    .padding(.vertical, Style.Spacing.x3)
                }

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Style.Color.background.opacity(0), location: 0),
                        .init(color: Style.Color.background.opacity(0.85), location: 0.6),
                        .init(color: Style.Color.background, location: 1.0)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 40)
                .allowsHitTesting(false)
            }
        }
        // A horizontal ScrollView claims all vertical height it's offered. Inside
        // the bottom safeAreaInset (which proposes the full screen height) that made
        // the bar balloon vertically, inflating the inset and pushing the composer
        // up with a large void below the chips. Pinning to the ideal vertical size
        // keeps the bar a single compact row.
        .fixedSize(horizontal: false, vertical: true)
        .background(Style.Color.background)
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
    let label: String
    let isActive: Bool
    var showsChevron: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: { Haptics.lightTap(); onTap() }) {
            HStack(spacing: 4) {
                Text(label)
                    .font(Style.Typography.meta())
                    .foregroundColor(isActive ? Style.Color.primaryText : Style.Color.secondary)

                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isActive ? Style.Color.primaryText : Style.Color.secondary)
                }
            }
            .padding(.horizontal, Style.Spacing.x3)
            .frame(height: 32)
            .background(
                Capsule()
                    .fill(isActive ? Style.Color.composerSend : Style.Color.composerBackground)
            )
        }
        .buttonStyle(.plain)
        .animation(Style.Animation.composerState, value: isActive)
    }
}
