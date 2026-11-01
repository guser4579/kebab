//
//  SearchTileView.swift
//  kebab
//

import SwiftUI

/// One Explore tile: a muted colour block, its title top-leading, a large
/// decorative glyph tucked into the bottom-trailing corner and clipped by
/// the tile. Deliberately quiet — no count, border, shadow, or press motion.
struct SearchTileView: View {

    let tile: SearchTile
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    private let cornerRadius: CGFloat = 12
    private let glyphSize: CGFloat = 44

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Style.Color.Tile.fill(tile.color))
                .overlay(alignment: .topLeading) {
                    Text(tile.title)
                        .font(Style.Typography.face(16, .medium))
                        .foregroundColor(Style.Color.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    // About a quarter of the glyph bleeds past the edge.
                    Icon(tile.icon, glyphSize: glyphSize, gridSize: glyphSize)
                        .foregroundColor(Style.Color.Tile.mark(tile.color))
                        .rotationEffect(.degrees(15))
                        .offset(x: glyphSize / 4, y: glyphSize / 4)
                        .accessibilityHidden(true)
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityAddTraits(.isButton)
    }
}
