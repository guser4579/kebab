//
//  PartialSheetSurface.swift
//  kebab
//

import SwiftUI

/// The one presentation treatment for Kebab's partial bottom sheets.
///
/// A partial sheet is a floating object: it hugs its content and sits the same
/// small gutter from the left, right, and bottom edges of the screen —
/// physical edges, not safe-area boundaries — so the gap reads evenly on all
/// three sides. Everything a partial sheet needs to look and behave like a
/// sheet lives here — surface, corners, hairline, drag-to-dismiss, inset — so
/// the treatment is owned in one place rather than restated per screen.
///
/// The bottom corners are drawn *concentric* with the display's own corners
/// rather than at a radius of their own: `ConcentricRectangle` asks the
/// container shape — the screen, since nothing between here and the window
/// overrides it — what it curves at, and subtracts this sheet's inset from it.
/// That is what keeps the gutter from pinching or flaring as both curves turn
/// through the bottom corners, and it is why no display corner radius is
/// hard-coded or looked up per device: a phone with a different shell reports
/// a different container shape and the sheet follows it. The top corners sit
/// nowhere near a screen corner, so they keep their own fixed radius.
///
/// Full-screen flows (composer, editor, collection pickers, rename) are a
/// different presentation entirely and deliberately never route through here:
/// they own the whole screen edge to edge, with an X/✓ header instead of a
/// grabber. `SheetGrabber` + this modifier is what makes a surface a partial
/// sheet; `.ignoresSafeArea(edges: [.top, .bottom])` is what makes one
/// full-screen.
///
/// The home indicator is cleared from inside the surface rather than by
/// floating the sheet higher: the sheet's own 32pt terminal inset below its
/// last control, plus the gutter, puts content above the indicator without
/// spending anything on the outside — so the visible gap below the sheet is
/// the gutter and only the gutter.
///
/// Hosts present a partial sheet exactly the way they always have: a
/// bottom-aligned `ZStack` that ignores the container's bottom safe area, so
/// the sheet can reach down past it and `.move(edge: .bottom)` still carries
/// the sheet fully offscreen.
struct PartialSheetSurface: ViewModifier {

    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .background(Style.Color.background)
            .clipShape(shape)
            .overlay(shape.stroke(Style.Color.separator, lineWidth: 1))
            .draggableSheet(
                bottomInset: Style.Layout.partialSheetGutter,
                onDismiss: onDismiss
            )
            .padding(.horizontal, Style.Layout.partialSheetGutter)
            // The same gutter on the bottom as on the sides. Keyboard
            // avoidance still moves the sheet as it always did; the sheet then
            // floats this same distance above the keyboard.
            .padding(.bottom, Style.Layout.partialSheetGutter)
    }

    /// Fixed on top, concentric with the screen on the bottom. The `minimum`
    /// is the fallback for a display that curves less than the sheet does (or
    /// not at all): the corner never goes squarer than the top corners.
    private var shape: ConcentricRectangle {
        let fixed = Edge.Corner.Style.fixed(Style.Layout.partialSheetCornerRadius)
        return ConcentricRectangle(
            topLeadingCorner: fixed,
            topTrailingCorner: fixed,
            bottomLeadingCorner: .concentric(minimum: fixed),
            bottomTrailingCorner: .concentric(minimum: fixed)
        )
    }
}

extension View {
    /// Presents this content as a floating partial bottom sheet. `onDismiss`
    /// must be the same choreography the host's dim-layer tap uses.
    func partialSheetSurface(onDismiss: @escaping () -> Void) -> some View {
        modifier(PartialSheetSurface(onDismiss: onDismiss))
    }
}
