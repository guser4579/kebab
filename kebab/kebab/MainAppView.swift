import SwiftUI
import Supabase

struct MainAppView: View {

    private let supabase: SupabaseClient
    @StateObject private var feedViewModel: FeedViewModel
    @State private var composerText: String = ""
    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var selectedTab: StickyHeaderView.Tab = .feed
    @State private var isSettingsOpen: Bool = false
    @State private var isSearchActive: Bool = false
    @State private var scrollToBottomOnChange = false
    @State private var hasScrolledToBottom = false
    @State private var scrollDistanceFromBottom: CGFloat = 0

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

                                Color.clear
                                    .frame(height: 1)
                                    .id("feed-bottom")
                            }
                            .scrollDismissesKeyboard(.interactively)
                            .onChange(of: feedViewModel.entries.count) {
                                if !hasScrolledToBottom && !feedViewModel.entries.isEmpty {
                                    hasScrolledToBottom = true
                                    proxy.scrollTo("feed-bottom", anchor: .bottom)
                                } else if scrollToBottomOnChange {
                                    scrollToBottomOnChange = false
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
                                    && scrollDistanceFromBottom > geometry.size.height
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
                .safeAreaInset(edge: .bottom) {
                    if !isSettingsOpen && selectedTab == .feed {
                        ComposerView(
                            text: $composerText,
                            maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                            onSent: { content in
                                scrollToBottomOnChange = true
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
                                onEdit: {
                                    Task {
                                        await feedViewModel.toggleEntryHidden(
                                            id: entry.id,
                                            currentValue: entry.isContentHidden
                                        )
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
            .navigationDestination(isPresented: $isSearchActive) {
                if let userId = authViewModel.currentUserId {
                    SearchView(supabase: supabase, feedViewModel: feedViewModel, userId: userId)
                }
            }
        }
        }
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