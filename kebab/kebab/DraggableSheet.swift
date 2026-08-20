//
//  DraggableSheet.swift
//  kebab
//

import SwiftUI

/// Drag-to-dismiss behavior for floating bottom sheets, making the grabber
/// functional. The sheet tracks a downward drag 1:1 (with rubber-band
/// resistance upward); releasing past the threshold slides it offscreen and
/// then invokes the host's normal dismiss choreography — whose removal
/// transition is invisible because the sheet is already below the screen
/// edge. Releasing short of the threshold springs back.
///
/// Applied by `PartialSheetSurface`, which owns the rest of the treatment.
struct DraggableSheetModifier: ViewModifier {

    /// How far the sheet already floats above the screen's bottom edge. The
    /// dismissing slide has to clear it as well as the sheet's own height,
    /// or the sheet is still onscreen when the removal transition starts.
    let bottomInset: CGFloat
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var sheetHeight: CGFloat = 0
    @State private var isDismissing = false

    func body(content: Content) -> some View {
        // A floating sheet needs no overscroll extension: pulling up simply
        // lifts it and widens its gutter, which is what a floating object
        // does. (An edge-anchored sheet needed sheet-colored background
        // hanging below the screen edge to hide the gap it opened.)
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newValue in
                sheetHeight = newValue
            }
            .offset(y: dragOffset)
            .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        // minimumDistance keeps plain taps flowing to the sheet's buttons.
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isDismissing else { return }
                let translation = value.translation.height
                dragOffset = translation > 0 ? translation : translation / 4
            }
            .onEnded { value in
                guard !isDismissing else { return }
                let distance = value.translation.height
                let projected = value.predictedEndTranslation.height
                let threshold = max(80, sheetHeight * 0.25)

                if distance > threshold || projected > sheetHeight * 0.75 {
                    isDismissing = true
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = max(sheetHeight, 300) + bottomInset
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDismiss()
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

extension View {
    /// Makes a floating bottom sheet draggable-to-dismiss. `onDismiss` must be
    /// the same choreography the sheet's dim-layer tap uses.
    func draggableSheet(
        bottomInset: CGFloat,
        onDismiss: @escaping () -> Void
    ) -> some View {
        modifier(DraggableSheetModifier(bottomInset: bottomInset, onDismiss: onDismiss))
    }
}
