import SwiftUI

/// The one place in the app that knows the feed is rendered flipped.
///
/// Renders `items` (newest first) as a vertically inverted scroll view, so
/// the newest item sits at the visual bottom and the view opens there with
/// zero programmatic scrolling: unflipped offset 0 IS the live edge. Older
/// history loads are plain appends — geometrically exact, no anchoring APIs.
///
/// Everything exposed to callers is in product terms:
///   - `onLiveEdgeChange`: the newest item is / is no longer at the bottom
///   - `distanceFromLiveEdge`: points of content between the viewport and
///     the newest item (exact — the origin side is always materialized)
///   - `onApproachHistoryEnd`: the user is nearing the oldest loaded item;
///     fire the next page prefetch
///   - `scrollToLiveEdgeSignal`: bump to smoothly return to the newest item
struct InvertedFeedScrollView<Item: Identifiable, Row: View>: View where Item.ID == UUID {

    let items: [Item]                       // newest first
    /// Points from the live edge within which the feed still counts as live.
    var liveEdgeTolerance: CGFloat = 60
    /// Screens of remaining history below which the next page is prefetched.
    var prefetchScreens: CGFloat = 2.5
    @Binding var scrollToLiveEdgeSignal: Int
    var onLiveEdgeChange: ((Bool) -> Void)? = nil
    var onDistanceChange: ((CGFloat) -> Void)? = nil
    var onApproachHistoryEnd: (() -> Void)? = nil
    var onUserScroll: (() -> Void)? = nil
    @ViewBuilder let row: (Item) -> Row

    @State private var position = ScrollPosition(idType: UUID.self)
    @State private var isAtLiveEdge = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                        .scaleEffect(x: 1, y: -1)
                }
            }
            .scrollTargetLayout()
        }
        .scaleEffect(x: 1, y: -1)
        .scrollIndicators(.hidden) // the indicator renders mirrored when flipped
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in
            // Unflipped offset 0 = visual bottom = live edge. contentInsets.top
            // absorbs the safe-area so the resting offset reads as ~0.
            let distance = max(0, g.contentOffset.y + g.contentInsets.top)
            onDistanceChange?(distance)

            let live = distance <= liveEdgeTolerance
            if live != isAtLiveEdge {
                isAtLiveEdge = live
                onLiveEdgeChange?(live)
            }

            // Remaining unseen history below the viewport (unflipped: content
            // past the far end). When it shrinks under the prefetch window,
            // ask for the next older page.
            let remaining = g.contentSize.height - (g.contentOffset.y + g.containerSize.height)
            if remaining < g.containerSize.height * prefetchScreens {
                onApproachHistoryEnd?()
            }
        }
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .interacting { onUserScroll?() }
        }
        .onChange(of: scrollToLiveEdgeSignal) { _, _ in
            // Visual bottom is the unflipped top edge.
            withAnimation(.easeOut(duration: 0.3)) {
                position.scrollTo(edge: .top)
            }
        }
    }
}
