//
//  Icon.swift
//  kebab
//

import SwiftUI

struct Icon: View {

    let name: String
    let glyphSize: CGFloat

    init(_ name: String, glyphSize: CGFloat = Style.Icon.glyph) {
        self.name = name
        self.glyphSize = glyphSize
    }

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: glyphSize, height: glyphSize)
            .frame(width: Style.Icon.grid, height: Style.Icon.grid)
    }
}
