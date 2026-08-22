//
//  PartialSheetSurface.swift
//  kebab
//

import SwiftUI

/// The one geometry every surface that floats against the bottom of the
/// screen is cut from — partial bottom sheets and the menu's fixed feedback
/// container alike.
///
/// Two things make such a surface: the `gutter` it keeps from the left,
/// right, and bottom *physical* edges of the screen (not the safe area, so
/// the gap reads the same on all three sides), and the `shape` whose bottom
/// corners are drawn *concentric* with the display's own corners rather than
/// at a radius of their own. `ConcentricRectangle` asks the container shape —
/// the screen, since nothing between here and the window overrides it — what
/// it curves at and subtracts this surface's inset from it. That is what
/// keeps the gutter from pinching or flaring as both curves turn through the
/// bottom corners, and it is why no display corner radius is hard-coded or
/// looked up per device: a phone with a different shell reports a different
/// container shape and the surface follows it. The top corners sit nowhere
/// near a screen corner, so they keep their own fixed radius.
///
/// There is deliberately exactly one *rule* here, but not one shape: the
/// gutter and the concentric-bottom rule are shared, while the top radius is
/// each surface's own business. A partial sheet's top edge announces a modal
/// arriving and earns a large radius; a container merely fixed to the bottom
/// of a screen is furniture and does not. Forcing both through one four-corner
/// shape is what made the feedback container read as a sheet that failed to
/// open.
///
/// A note on what the display's curve can and cannot reach. The concentric
/// radius resolves against the display and is roughly `displayRadius -
/// gutter` — around 55pt on a current iPhone — but SwiftUI will not draw a
/// corner larger than half the surface's shorter side. A surface has to be
/// about 110pt tall before its bottom corners can be drawn at their true
/// concentric radius; below that they are capped at `height / 2`, and the
/// gutter widens through the turn by exactly the difference. Partial sheets
/// clear that comfortably. A short fixed container does not, and no shape can
/// make it: the curve it wants is simply taller than it is.
enum BottomEdgeSurface {

    /// Distance kept from the left, right, and bottom physical screen edges.
    static var gutter: CGFloat { Style.Layout.partialSheetGutter }

    /// Fixed on top at `topRadius`, concentric with the screen on the bottom.
    /// The `minimum` is the fallback for a display that curves less than the
    /// surface does (or not at all): the corner never goes squarer than the
    /// top corners.
    ///
    /// The top corners are deliberately *not* concentric — they sit nowhere
    /// near a screen corner and answer to nothing but themselves — and they
    /// are deliberately small, because the top and bottom corners compete for
    /// the same vertical run: every point of top radius is a point the bottom
    /// corner cannot use.
    static func shape(topRadius: CGFloat) -> ConcentricRectangle {
        let fixed = Edge.Corner.Style.fixed(topRadius)
        return ConcentricRectangle(
            topLeadingCorner: fixed,
            topTrailingCorner: fixed,
            bottomLeadingCorner: .concentric(minimum: fixed),
            bottomTrailingCorner: .concentric(minimum: fixed)
        )
    }

    /// The partial sheets' shape. Unchanged: their top corners are a sheet's.
    static var sheetShape: ConcentricRectangle {
        shape(topRadius: Style.Layout.partialSheetCornerRadius)
    }

    /// The shape for a container fixed to the bottom of a screen — the menu's
    /// feedback invitation. Same gutter and same bottom rule as a sheet, a
    /// restrained top corner of its own.
    static var fixedContainerShape: ConcentricRectangle {
        shape(topRadius: Style.Layout.bottomContainerCornerRadius)
    }
}

/// Paints a view as a bottom-edge surface: fill, mask, and border all taken
/// from `BottomEdgeSurface.shape`.
///
/// All three are the same shape value *rendered the same way* — as shape
/// views — and that is the whole point of this type. A `ConcentricRectangle`
/// only knows what to curve its bottom corners at when it is resolved against
/// the container shape; a plain `.background(color)` + `.clipShape(shape)`
/// pair resolves the surface's fill through a different path than the
/// rendered border does, and when the two disagree about the concentric
/// radius the fill spills past the border through the bottom corners. Fill,
/// mask, and border here cannot disagree, because there is one shape and one
/// way of drawing it.
///
/// `ConcentricRectangle` is not insettable, so a border is stroked at twice
/// its intended width and the mask — applied last, over the whole composite —
/// takes the outer half back. What is left is a hairline lying entirely
/// inside the same path the fill is cut to: `strokeBorder` semantics without
/// a second shape to approximate the first with. `stroke` is optional; a
/// surface that carries its own solid fill needs no outline to sit on.
struct BottomEdgeSurfaceStyle: ViewModifier {

    /// Visible border weight. Stroked at `2 ×` this and masked back down.
    private static let borderWidth: CGFloat = 1

    let shape: ConcentricRectangle
    let fill: SwiftUI.Color
    let stroke: SwiftUI.Color?

    func body(content: Content) -> some View {
        content
            .background { shape.fill(fill) }
            .overlay {
                if let stroke {
                    shape.stroke(stroke, lineWidth: Self.borderWidth * 2)
                }
            }
            .mask { shape.fill(SwiftUI.Color.black) }
    }
}

/// The one presentation treatment for Kebab's partial bottom sheets.
///
/// A partial sheet is a floating object: it hugs its content and sits the
/// `BottomEdgeSurface` gutter from the left, right, and bottom edges of the
/// screen, so the gap reads evenly on all three sides. Everything a partial
/// sheet needs to look and behave like a sheet lives here — surface, corners,
/// hairline, drag-to-dismiss, inset — so the treatment is owned in one place
/// rather than restated per screen.
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
            .modifier(
                BottomEdgeSurfaceStyle(
                    shape: BottomEdgeSurface.sheetShape,
                    fill: Style.Color.background,
                    stroke: Style.Color.separator
                )
            )
            .draggableSheet(
                bottomInset: BottomEdgeSurface.gutter,
                onDismiss: onDismiss
            )
            .padding(.horizontal, BottomEdgeSurface.gutter)
            // The same gutter on the bottom as on the sides. Keyboard
            // avoidance still moves the sheet as it always did; the sheet then
            // floats this same distance above the keyboard.
            .padding(.bottom, BottomEdgeSurface.gutter)
    }
}

extension View {
    /// Presents this content as a floating partial bottom sheet. `onDismiss`
    /// must be the same choreography the host's dim-layer tap uses.
    func partialSheetSurface(onDismiss: @escaping () -> Void) -> some View {
        modifier(PartialSheetSurface(onDismiss: onDismiss))
    }

    /// Paints this content as a bottom-edge surface — the shared fill/mask/
    /// border treatment partial sheets use — without a sheet's drag,
    /// transitions, or gutter. For surfaces that are *fixed* to the bottom of
    /// a screen rather than presented over it; the host owns the gutter and
    /// picks the shape, since a fixed container's top corners are not a
    /// sheet's.
    func bottomEdgeSurface(
        shape: ConcentricRectangle,
        fill: SwiftUI.Color,
        stroke: SwiftUI.Color? = nil
    ) -> some View {
        modifier(BottomEdgeSurfaceStyle(shape: shape, fill: fill, stroke: stroke))
    }
}
