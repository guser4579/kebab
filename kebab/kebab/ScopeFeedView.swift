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
                    Text("Nothing in \(scopeName) yet.")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(Style.Spacing.emptyStateMargin)
                } else if store.hasLoadedOnce {
                    EmptyStateView(
                        iconName: "bookmark-02",
                        title: "Save it here",
                        primaryBody: "Kebab is a micro journal for thoughts, links, and things you don't want to lose.\n\nLike a sticky note you'll come back to.",
                        secondaryBody: "Recipes, quotes, ideas, movies to watch, random thoughts that come to you at 3am."
                    )
                    .padding(Style.Spacing.emptyStateMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                        isSettling: entry.id == settlingEntryId
                    )
                }
            }
        }
        .overlay(alignment: .bottom) { fab }
    }

    // MARK: - Three-state FAB

    /// All communicates newness; collections preserve context quietly. The
    /// informational unseen-count state exists only on All — collection
    /// scopes keep the plain two-state arrow while their stores continue
    /// buffering arrivals underneath exactly as before.
    private var showsUnseenCount: Bool { store.scope == .all }

    private var showFAB: Bool {
        (showsUnseenCount && store.unseenCount > 0) || distanceFromLiveEdge > containerHeight
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
                        if showsUnseenCount && store.unseenCount > 0 {
                            Text(store.unseenCount == 1 ? "1 new entry" : "\(store.unseenCount) new entries")
                                .font(Style.Typography.meta())
                                .foregroundColor(Style.Color.primaryText)
                                .fixedSize(horizontal: true, vertical: false)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, (showsUnseenCount && store.unseenCount > 0) ? 14 : 0)
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
