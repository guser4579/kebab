//
//  ChipFilterBarView.swift
//  kebab
//

import SwiftUI

// MARK: - ChipFilterBarView

struct ChipFilterBarView: View {

    let collectionChips: [FeedFilter]
    let activeFilters: Set<FeedFilter>
    let onToggle: (FeedFilter) -> Void

    private let staticChips: [FeedFilter] = [
        .hasLink, .mostFlames, .mostComments, .mostResurfaced, .random
    ]

    private var allChips: [FeedFilter] {
        staticChips + collectionChips
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)

            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Style.Spacing.x2) {
                        ForEach(allChips, id: \.self) { chip in
                            ChipButton(
                                label: chip.displayName,
                                isActive: activeFilters.contains(chip),
                                onTap: { onToggle(chip) }
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
}

// MARK: - ChipButton

private struct ChipButton: View {
    let label: String
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: { Haptics.lightTap(); onTap() }) {
            Text(label)
                .font(Style.Typography.meta())
                .foregroundColor(isActive ? Style.Color.primaryText : Style.Color.secondary)
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

