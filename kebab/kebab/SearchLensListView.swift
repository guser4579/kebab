//
//  SearchLensListView.swift
//  kebab
//

import SwiftUI

/// Every thought in one Explore lens, in the lens's order, rendered as real
/// feed rows. Which thoughts appear, and in what order, is a snapshot from
/// when the list opened — it never reshuffles under the user. Each row's
/// values stay live: warm stores first, like the feed, then the corpus mirror
/// for the older thoughts no feed page has loaded. A thought deleted or hidden
/// from here drops out.
struct SearchLensListView: View {

    let tile: SearchTile
    let workspace: SearchWorkspace
    @ObservedObject var feedViewModel: FeedViewModel
    @ObservedObject private var corpus: SearchCorpusStore

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scopeCoordinator: FeedScopeCoordinator
    @EnvironmentObject private var recentActivityStore: RecentActivityStore
    @EnvironmentObject private var reminderStore: ReminderStore

    @State private var activeEntryMenuEntry: Entry?
    @State private var isEntryActionSheetVisible = false
    @State private var fullScreenEditEntry: Entry?
    @State private var isFullScreenEditVisible = false
    @State private var addToCollectionEntry: Entry?
    @State private var isAddToCollectionVisible = false
    @State private var addToCollectionAppearsInPlace = false
    @State private var reminderSheetEntry: Entry?
    @State private var isReminderSheetVisible = false
    @State private var pendingWarningId: UUID?

    init(tile: SearchTile, workspace: SearchWorkspace, feedViewModel: FeedViewModel) {
        self.tile = tile
        self.workspace = workspace
        self.feedViewModel = feedViewModel
        self.corpus = workspace.corpus
    }

    /// Members still worth showing. Decided from the mirror alone, which every
    /// patch and delete reaches, so a long list never walks the warm stores
    /// for rows that aren't on screen.
    private var visibleIds: [UUID] {
        tile.entryIds.filter { id in
            guard let entry = corpus.indexedEntry(id: id) else { return false }
            return !entry.isContentHidden && !feedViewModel.isEntryDeleted(id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailHeaderBar(title: tile.title, onBack: { dismiss() })

            let ids = visibleIds
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ids, id: \.self) { id in
                        if let entry = currentEntry(id: id) {
                            row(for: entry, isLast: id == ids.last)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .entryActionsHost(
            menuEntry: $activeEntryMenuEntry,
            isMenuVisible: $isEntryActionSheetVisible,
            editEntry: $fullScreenEditEntry,
            isEditVisible: $isFullScreenEditVisible,
            addToCollectionEntry: $addToCollectionEntry,
            isAddToCollectionVisible: $isAddToCollectionVisible,
            addToCollectionAppearsInPlace: $addToCollectionAppearsInPlace,
            feedViewModel: feedViewModel,
            openReminderSheet: { openReminderSheet(for: $0) },
            // A cold row's new home comes back with the corpus refetch.
            onEntryMoved: { Task { await corpus.refreshIfNeeded() } }
        )
        .entryReminderHost(entry: $reminderSheetEntry, isVisible: $isReminderSheetVisible)
        .entryPendingWarningAlert(id: $pendingWarningId, feedViewModel: feedViewModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.Color.background)
        .foregroundColor(Style.Color.primaryText)
        .ignoresSafeArea(edges: .top)
        .background(Style.Color.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .enablesSwipeBack()
        .onAppear {
            // Returning from a thought: anything changed in there that only
            // marked the corpus stale comes back here.
            Task { await corpus.refreshIfNeeded() }
        }
    }

    private func currentEntry(id: UUID) -> Entry? {
        scopeCoordinator.entry(id: id)
            ?? corpus.feedEntry(id: id, collectionInfo: feedViewModel.collectionInfoResolver)
    }

    private func row(for entry: Entry, isLast: Bool) -> some View {
        EntryRowView(
            entry: entry,
            feedViewModel: feedViewModel,
            showBottomSeparator: !isLast,
            onResultActivated: { workspace.noteOpened(entryId: entry.id) },
            onMoreTapped: {
                activeEntryMenuEntry = entry
                withAnimation(.easeOut(duration: 0.25)) {
                    isEntryActionSheetVisible = true
                }
            },
            onResurfaceTapped: {
                recentActivityStore.record(
                    rootId: entry.id,
                    contextEntryId: entry.id,
                    kind: .resurfaced
                )
                Task {
                    if await feedViewModel.resurfaceEntry(entry: entry) {
                        scopeCoordinator.revalidateScopes(containing: entry)
                    }
                }
            },
            onFireTapped: {
                Task { await feedViewModel.fireEntry(entry: entry) }
            },
            onPendingWarningTapped: { pendingWarningId = entry.id },
            reminder: reminderStore.reminder(for: entry.id),
            remindersCanDeliver: reminderStore.authorization.canDeliver,
            onReminderTapped: { openReminderSheet(for: entry) },
            // A lens spans collections, the way All does.
            showsCollectionProvenance: true
        )
    }

    private func openReminderSheet(for entry: Entry) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        reminderSheetEntry = entry
        withAnimation(.easeOut(duration: 0.25)) {
            isReminderSheetVisible = true
        }
    }
}
