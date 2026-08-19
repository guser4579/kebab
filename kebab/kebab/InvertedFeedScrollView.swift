import SwiftUI

/// The primary feed's scroll container.
///
/// Renders `items` (newest first) upright, so the newest item sits at the
/// top and the view opens there with zero programmatic scrolling: offset 0
/// IS the live edge. Older history loads are plain appends past the far
/// end — geometrically exact, no anchoring APIs.
///
/// Everything exposed to callers is in product terms:
///   - `onLiveEdgeChange`: the newest item is / is no longer on screen
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
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden) // deliberate: the feed reads as one surface
        .scrollPosition($position)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in
            // Offset 0 = top = live edge. contentInsets.top absorbs the
            // safe-area so the resting offset reads as ~0.
            let distance = max(0, g.contentOffset.y + g.contentInsets.top)
            onDistanceChange?(distance)

            let live = distance <= liveEdgeTolerance
            if live != isAtLiveEdge {
                isAtLiveEdge = live
                onLiveEdgeChange?(live)
            }

            // Remaining unseen history below the viewport (content past the
            // far end). When it shrinks under the prefetch window, ask for
            // the next older page.
            let remaining = g.contentSize.height - (g.contentOffset.y + g.containerSize.height)
            if remaining < g.containerSize.height * prefetchScreens {
                onApproachHistoryEnd?()
            }
        }
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .interacting { onUserScroll?() }
        }
        .onChange(of: scrollToLiveEdgeSignal) { _, _ in
            // The newest item sits at the top edge.
            withAnimation(.easeOut(duration: 0.3)) {
                position.scrollTo(edge: .top)
            }
        }
    }
}
