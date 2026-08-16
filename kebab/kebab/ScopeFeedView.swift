import SwiftUI

/// One feed scope's surface: inverted scroll container + its FeedStore + the
/// scope's own three-state jump-to-newest FAB. MainAppView keeps one of these
/// alive per visited scope, so switching scopes swaps already-open surfaces.
struct ScopeFeedView: View {

    @ObservedObject var store: FeedStore
    /// Scoped collection name for the empty state; nil for All.
    let scopeName: String?
    @ObservedObject var feedViewModel: FeedViewModel
    let containerHeight: CGFloat
    let settlingEntryId: UUID?
    /// True while the post-capture quick actions occupy the area above the
    /// composer: they take temporary priority over the FAB, which returns via
    /// its normal transition once they dismiss. The underlying unseen/distance
    /// state keeps updating untouched.
    var suppressesFAB: Bool = false
    var onUserScroll: (() -> Void)?
    var onEntryOpened: (() -> Void)?
    let onMoreTapped: (Entry) -> Void
    let onResurfaceTapped: (Entry) -> Void
    let onPinTapped: (Entry) -> Void
    let onFireTapped: (Entry) -> Void
    let onPendingWarningTapped: (Entry) -> Void

    @State private var scrollToLiveEdgeSignal = 0
    @State private var distanceFromLiveEdge: CGFloat = 0

    /// Newest-first: outbox pending entries (except ones held while away)
    /// render at the live edge ahead of the server rows.
    private var displayEntries: [Entry] {
        let pending = feedViewModel.pendingDisplayEntries
            .filter { store.scope.matches($0) && !store.heldPendingIds.contains($0.id) }
        return pending + store.entries
    }

    var body: some View {
        Group {
            if displayEntries.isEmpty {
                if store.hasLoadedOnce, let scopeName {
                    // An empty collection is a valid destination, not an error.
                    collectionEmptyState(name: scopeName)
                } else if store.hasLoadedOnce {
                    AllFeedEmptyStateView()
                } else {
                    feedSkeleton
                }
            } else {
                let entries = displayEntries
                InvertedFeedScrollView(
                    items: entries,
                    scrollToLiveEdgeSignal: $scrollToLiveEdgeSignal,
                    onLiveEdgeChange: { live in
                        if live { store.didReachLiveEdge() } else { store.didLeaveLiveEdge() }
                    },
                    onDistanceChange: { distanceFromLiveEdge = $0 },
                    onApproachHistoryEnd: {
                        Task { await store.loadOlderIfNeeded() }
                    },
                    onUserScroll: { onUserScroll?() }
                ) { entry in
                    EntryRowView(
                        entry: entry,
                        feedViewModel: feedViewModel,
                        // Newest (first) row sits flush above the composer.
                        showBottomSeparator: entry.id != entries.first?.id || entries.count == 1,
                        onResultActivated: { onEntryOpened?() },
                        onMoreTapped: { onMoreTapped(entry) },
                        onResurfaceTapped: { onResurfaceTapped(entry) },
                        onPinTapped: { onPinTapped(entry) },
                        onFireTapped: { onFireTapped(entry) },
                        onPendingWarningTapped: { onPendingWarningTapped(entry) },
                        isSettling: entry.id == settlingEntryId,
                        // Only All shows an entry's collection home —
                        // collection scopes already are that context.
                        showsCollectionProvenance: store.scope == .all
                    )
                }
            }
        }
        .overlay(alignment: .bottom) { fab }
    }

    /// Quiet empty state for a collection or sub-collection scope, in the
    /// comment empty state's visual language: meta/secondary text with two
    /// trace glyphs anchored just outside its corners, centered in the empty
    /// feed area. The composer below remains the action. Deliberately exempt
    /// from the 24-character display rule: the full stored name shows here,
    /// wrapping naturally within a capped width. Chips and other compact
    /// labels keep the truncated form.
    private func collectionEmptyState(name: String) -> some View {
        Text("Add entries to \(name)")
            .font(Style.Typography.meta())
            .lineSpacing(Style.Typography.metaLineHeight - 14)
            .multilineTextAlignment(.center)
            .foregroundColor(Style.Color.secondary)
            .overlay(alignment: .topLeading) {
                Text("·")
                    .font(Style.Typography.mono(size: 12))
                    .foregroundColor(Style.Color.secondary)
                    .opacity(0.35)
                    .offset(x: -18, y: -16)
            }
            .overlay(alignment: .bottomTrailing) {
                Text("+")
                    .font(Style.Typography.mono(size: 11))
                    .foregroundColor(Style.Color.secondary)
                    .opacity(0.3)
                    .offset(x: 16, y: 14)
            }
            // Cap the wrap width so long names break into centered lines
            // instead of running edge-to-edge.
            .frame(maxWidth: 280)
            .padding(.horizontal, Style.Spacing.emptyStateMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Add entries to \(name)")
    }

    // MARK: - Three-state FAB (All only)

    /// The FAB exists only on All: it communicates newness at the live edge.
    /// Collection scopes preserve the user's context quietly and render no
    /// FAB under any scroll condition — their stores still buffer arrivals
    /// underneath exactly as before, revealed on returning to the live edge.
    private var showFAB: Bool {
        store.scope == .all
            && !suppressesFAB
            && (store.unseenCount > 0 || distanceFromLiveEdge > containerHeight)
    }

    private var fab: some View {
        Group {
            if showFAB {
                Button {
                    scrollToLiveEdgeSignal += 1
                } label: {
                    HStack(spacing: 6) {
                        Icon("arrow-up", glyphSize: Style.Icon.glyphSmall)
                            .rotationEffect(.degrees(180))
                            .foregroundColor(Style.Color.primaryText)
                        if store.unseenCount > 0 {
                            Text(store.unseenCount == 1 ? "1 new entry" : "\(store.unseenCount) new entries")
                                .font(Style.Typography.meta())
                                .foregroundColor(Style.Color.primaryText)
                                .fixedSize(horizontal: true, vertical: false)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, store.unseenCount > 0 ? 14 : 0)
                    .frame(minWidth: 36)
                    .frame(height: 36)
                    .glassEffect(
                        .regular.tint(Style.Color.composerBackground.opacity(0.5)),
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showFAB)
        .animation(.easeInOut(duration: 0.2), value: store.unseenCount)
    }

    /// Restrained fallback for a true cold launch with no usable cache.
    private var feedSkeleton: some View {
        VStack(spacing: Style.Spacing.x4) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Style.Spacing.x2) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Style.Color.separator)
                        .frame(width: 42, height: 10)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Style.Color.separator.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Style.Color.separator.opacity(0.6))
                        .frame(width: 220, height: 14)
                }
                .padding(.horizontal, Style.Layout.entryContentPadding)
            }
            Spacer()
        }
        .padding(.top, Style.Spacing.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
