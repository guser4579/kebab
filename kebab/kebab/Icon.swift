//
//  Icon.swift
//  kebab
//

import SwiftUI

struct Icon: View {

    let name: String
    let glyphSize: CGFloat
    /// Box the glyph is centered in. Defaults to the app's icon grid; pass a
    /// smaller one where the icon sits inline with text rather than in a row's
    /// icon column.
    let gridSize: CGFloat

    init(
        _ name: String,
        glyphSize: CGFloat = Style.Icon.glyph,
        gridSize: CGFloat = Style.Icon.grid
    ) {
        self.name = name
        self.glyphSize = glyphSize
        self.gridSize = gridSize
    }

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: glyphSize, height: glyphSize)
            .frame(width: gridSize, height: gridSize)
    }
}
