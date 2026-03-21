import SwiftUI
import Supabase

struct MainAppView: View {

    private let supabase: SupabaseClient
    @StateObject private var feedViewModel: FeedViewModel
    @State private var composerText: String = ""
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false
    @State private var selectedTab: StickyHeaderView.Tab = .feed
    @State private var isSettingsOpen: Bool = false
    @State private var isSearchActive: Bool = false
    // Toggled to true by onSent; the FeedScrollContent child reads and clears it
    // to scroll the feed to the bottom after a new entry appears. Keeping this
    // flag here (not inside FeedScrollContent) lets the onSent closure write it
    // without needing a captured proxy reference.
    @State private var scrollToBottomOnSend = false

    let authViewModel: AuthViewModel

    init(supabase: SupabaseClient, authViewModel: AuthViewModel) {
        self.supabase = supabase
        _feedViewModel = StateObject(wrappedValue: FeedViewModel(supabase: supabase))
        self.authViewModel = authViewModel
    }

    var body: some View {
        NavigationStack {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Style.Color.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    StickyHeaderView(
                        selectedTab: $selectedTab,
                        onSettingsTapped: {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                isSettingsOpen = true
                            }
                        },
                        onSearchTapped: {
                            isSearchActive = true
                        }
                    )

                    ZStack {
                        // Feed tab — isolated into its own child so that
                        // onScrollGeometryChange state updates don't re-render
                        // MainAppView (and therefore don't churn the composer).
                        FeedScrollContent(
                            feedViewModel: feedViewModel,
                            selectedTab: selectedTab,
                            containerHeight: geometry.size.height,
                            scrollToBottomOnSend: $scrollToBottomOnSend,
                            onMoreTapped: { entry in
                                activeEntryMenuEntry = entry
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = true
                                }
                            },
                            onResurfaceTapped: { entry in
                                Task { await feedViewModel.resurfaceEntry(entry: entry) }
                            },
                            onPinTapped: { entry in
                                Task { await feedViewModel.togglePin(entry: entry) }
                            }
                        )

                        ScrollView {
                            if feedViewModel.hasCompletedInitialLoad && feedViewModel.pinnedEntries.isEmpty {
                                EmptyStateView(
                                    iconName: "pin-filled",
                                    title: "Come back to it",
                                    primaryBody: "Keep your most important thoughts and threads close by pinning them here.",
                                    secondaryBody: "For ideas in progress, links to revisit, and anything you want top of mind."
                                )
                                .padding(Style.Spacing.emptyStateMargin)
                            }
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(feedViewModel.pinnedEntries) { entry in
                                    EntryRowView(entry: entry, feedViewModel: feedViewModel, onMoreTapped: {
                                        activeEntryMenuEntry = entry
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isEntryActionSheetVisible = true
                                        }
                                    }, onResurfaceTapped: {
                                        Task { await feedViewModel.resurfaceEntry(entry: entry) }
                                    }, onPinTapped: {
                                        Task { await feedViewModel.togglePin(entry: entry) }
                                    })
                                }
                            }
                            .padding(.bottom, 16)
                        }
                        .defaultScrollAnchor(.top)
                        .scrollDismissesKeyboard(.interactively)
                        .opacity(selectedTab == .pinned ? 1 : 0)
                        .allowsHitTesting(selectedTab == .pinned)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Style.Color.background)
                    .foregroundColor(Style.Color.primaryText)
                    .task {
                        await feedViewModel.loadEntries()
                    }
                }
                .ignoresSafeArea(edges: .top)
                // Keep the same modifier node in the tree at all times - only the edges parameter changes.
                // A @ViewBuilder conditional (the prior attempt) changed the view type on toggle, causing
                // SwiftUI to destroy and recreate the ScrollView and reset its offset to zero. A stable
                // node with edges: [] (semantic no-op) vs edges: .bottom is a parameter update, not a
                // type change, so the ScrollView position survives both open and close.
                .ignoresSafeArea(.keyboard, edges: isFullScreenEditVisible ? .bottom : [])
                .safeAreaInset(edge: .bottom) {
                    if !isSettingsOpen && selectedTab == .feed {
                        ComposerView(
                            text: $composerText,
                            maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                            onSent: { content in
                                scrollToBottomOnSend = true
                                Task {
                                    await feedViewModel.sendEntry(content: content)
                                }
                            },
                            onFocus: { }
                        )
                    } else {
                        EmptyView()
                    }
                }

                SettingsView(
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            isSettingsOpen = false
                        }
                    },
                    authViewModel: authViewModel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: isSettingsOpen ? 0 : -UIScreen.main.bounds.width)
                .animation(.easeInOut(duration: 0.28), value: isSettingsOpen)
            }
            .overlay(alignment: .bottom) {
                if activeEntryMenuEntry != nil {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isEntryActionSheetVisible = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    activeEntryMenuEntry = nil
                                }
                            }

                        if isEntryActionSheetVisible, let entry = activeEntryMenuEntry {
                            EntryActionSheetView(
                                entry: entry,
                                isComment: false,
                                onDelete: {
                                    Task { await feedViewModel.deleteEntry(id: entry.id) }
                                },
                                onToggleContentHidden: {
                                    Task {
                                        await feedViewModel.toggleEntryHidden(
                                            id: entry.id,
                                            currentValue: entry.isContentHidden
                                        )
                                    }
                                },
                                onBeginTextEdit: {
                                    let toEdit = entry
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isEntryActionSheetVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        activeEntryMenuEntry = nil
                                        fullScreenEditEntry = toEdit
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isFullScreenEditVisible = true
                                        }
                                    }
                                },
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isEntryActionSheetVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        activeEntryMenuEntry = nil
                                    }
                                }
                            )
                            .transition(.move(edge: .bottom))
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .overlay {
                if isFullScreenEditVisible, let editEntry = fullScreenEditEntry {
                    EditEntryFullScreenView(
                        entry: editEntry,
                        initialText: editEntry.content,
                        feedViewModel: feedViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isFullScreenEditVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                fullScreenEditEntry = nil
                                // Full authoritative reload runs after the overlay is completely gone and
                                // the keyboard is dismissed, so no overlay or keyboard layout pressure
                                // is active when entries refreshes. The local patch in updateEntryContent
                                // already has the correct content, so this reload produces no diff visible
                                // to the user (same order, same text) and does not shift scroll position.
                                Task { await feedViewModel.loadEntries() }
                            }
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .navigationDestination(isPresented: $isSearchActive) {
                if let userId = authViewModel.currentUserId {
                    SearchView(supabase: supabase, feedViewModel: feedViewModel, userId: userId)
                }
            }
        }
        }
    }
}

// MARK: - FeedScrollContent

// Owns scrollDistanceFromBottom and hasScrolledToBottom so that the high-frequency
// onScrollGeometryChange updates re-render only this view — not MainAppView and not
// the ComposerView subtree in MainAppView's safeAreaInset.
private struct FeedScrollContent: View {

    @ObservedObject var feedViewModel: FeedViewModel
    let selectedTab: StickyHeaderView.Tab
    let containerHeight: CGFloat
    @Binding var scrollToBottomOnSend: Bool
    let onMoreTapped: (Entry) -> Void
    let onResurfaceTapped: (Entry) -> Void
    let onPinTapped: (Entry) -> Void

    @State private var scrollDistanceFromBottom: CGFloat = 0
    @State private var hasScrolledToBottom = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if feedViewModel.hasCompletedInitialLoad && feedViewModel.feedEntries.isEmpty {
                    EmptyStateView(
                        iconName: "bookmark-02",
                        title: "Save it here",
                        primaryBody: "Kebab is a micro journal for thoughts, links, and things you don't want to lose.\n\nLike a sticky note you'll come back to.",
                        secondaryBody: "Recipes, quotes, ideas, movies to watch, random thoughts that come to you at 3am."
                    )
                    .padding(Style.Spacing.emptyStateMargin)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(feedViewModel.feedEntries) { entry in
                        EntryRowView(entry: entry, feedViewModel: feedViewModel, onMoreTapped: {
                            onMoreTapped(entry)
                        }, onResurfaceTapped: {
                            onResurfaceTapped(entry)
                        }, onPinTapped: {
                            onPinTapped(entry)
                        })
                    }
                }
                .padding(.bottom, 16)

                Color.clear
                    .frame(height: 1)
                    .id("feed-bottom")
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: feedViewModel.entries.count) {
                if !hasScrolledToBottom && !feedViewModel.entries.isEmpty {
                    hasScrolledToBottom = true
                    proxy.scrollTo("feed-bottom", anchor: .bottom)
                } else if scrollToBottomOnSend {
                    scrollToBottomOnSend = false
                    proxy.scrollTo("feed-bottom", anchor: .bottom)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { g in
                max(0, g.contentSize.height - g.contentOffset.y - g.containerSize.height)
            } action: { _, newValue in
                scrollDistanceFromBottom = newValue
            }
            .overlay(alignment: .bottom) {
                let shouldShow = hasScrolledToBottom
                    && selectedTab == .feed
                    && scrollDistanceFromBottom > containerHeight
                Group {
                    if shouldShow {
                        Button {
                            proxy.scrollTo("feed-bottom", anchor: .bottom)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Style.Color.composerBackground)
                                    .frame(width: 36, height: 36)
                                Icon("arrow-up")
                                    .rotationEffect(.degrees(180))
                                    .foregroundColor(Style.Color.primaryText)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: shouldShow)
            }
        }
        .opacity(selectedTab == .feed ? 1 : 0)
        .allowsHitTesting(selectedTab == .feed)
    }
}


#Preview {
    MainAppView(
        supabase: SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "key"
        ),
        authViewModel: AuthViewModel(supabase: SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "key"
        ))
    )
}
