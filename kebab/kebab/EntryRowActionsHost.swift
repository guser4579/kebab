//
//  EntryRowActionsHost.swift
//  kebab
//
//  What a list of EntryRowViews needs its host to present: the "…" action
//  sheet and everything it leads to, the reminder sheet, and the failed-sync
//  alert. The feed and the Explore lens lists both host them through these
//  modifiers; each owner keeps its own state and passes it in as bindings.
//

import SwiftUI

extension View {

    /// The "…" action sheet, plus the full-screen editor and collection
    /// picker it opens. `onEntryMoved` runs after a collection move persists.
    func entryActionsHost(
        menuEntry: Binding<Entry?>,
        isMenuVisible: Binding<Bool>,
        editEntry: Binding<Entry?>,
        isEditVisible: Binding<Bool>,
        addToCollectionEntry: Binding<Entry?>,
        isAddToCollectionVisible: Binding<Bool>,
        addToCollectionAppearsInPlace: Binding<Bool>,
        feedViewModel: FeedViewModel,
        openReminderSheet: @escaping (Entry) -> Void,
        onEntryMoved: (() -> Void)? = nil
    ) -> some View {
        modifier(EntryActionsHost(
            menuEntry: menuEntry,
            isMenuVisible: isMenuVisible,
            editEntry: editEntry,
            isEditVisible: isEditVisible,
            addToCollectionEntry: addToCollectionEntry,
            isAddToCollectionVisible: isAddToCollectionVisible,
            addToCollectionAppearsInPlace: addToCollectionAppearsInPlace,
            feedViewModel: feedViewModel,
            openReminderSheet: openReminderSheet,
            onEntryMoved: onEntryMoved
        ))
    }

    /// The reminder sheet: same contextual-sheet chrome as the entry actions.
    /// Deliberately NOT ignoring the keyboard region — the optional note field
    /// needs the sheet to lift.
    func entryReminderHost(entry: Binding<Entry?>, isVisible: Binding<Bool>) -> some View {
        modifier(EntryReminderHost(entry: entry, isVisible: isVisible))
    }

    /// Retry / Discard for a pending entry the server permanently rejected.
    func entryPendingWarningAlert(id: Binding<UUID?>, feedViewModel: FeedViewModel) -> some View {
        alert("Entry couldn\u{2019}t sync", isPresented: Binding(
            get: { id.wrappedValue != nil },
            set: { if !$0 { id.wrappedValue = nil } }
        )) {
            Button("Try again") {
                if let pending = id.wrappedValue {
                    feedViewModel.retryPending(id: pending)
                }
                id.wrappedValue = nil
            }
            Button("Discard entry", role: .destructive) {
                if let pending = id.wrappedValue {
                    feedViewModel.discardPending(id: pending)
                }
                id.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) {
                id.wrappedValue = nil
            }
        } message: {
            Text("This entry is saved on your phone, but the server rejected it. You can retry or discard it.")
        }
    }
}

// MARK: - Action sheet, editor, collection picker

private struct EntryActionsHost: ViewModifier {

    @Binding var menuEntry: Entry?
    @Binding var isMenuVisible: Bool
    @Binding var editEntry: Entry?
    @Binding var isEditVisible: Bool
    @Binding var addToCollectionEntry: Entry?
    @Binding var isAddToCollectionVisible: Bool
    @Binding var addToCollectionAppearsInPlace: Bool
    let feedViewModel: FeedViewModel
    let openReminderSheet: (Entry) -> Void
    let onEntryMoved: (() -> Void)?

    @EnvironmentObject private var scopeCoordinator: FeedScopeCoordinator
    @EnvironmentObject private var noticeCenter: TransientNoticeCenter
    @EnvironmentObject private var recentActivityStore: RecentActivityStore
    @EnvironmentObject private var searchCorpusStore: SearchCorpusStore
    @EnvironmentObject private var collectionsViewModel: CollectionsViewModel

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if menuEntry != nil {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isMenuVisible = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    menuEntry = nil
                                }
                            }

                        if isMenuVisible, let entry = menuEntry {
                            EntryActionSheetView(
                                entry: entry,
                                onDelete: {
                                    performDelete(entry)
                                },
                                onToggleContentHidden: {
                                    // Optimistic inside toggleEntryHidden: the
                                    // row updates instantly; a genuine failure
                                    // rolls back and surfaces quietly.
                                    Task {
                                        let ok = await feedViewModel.toggleEntryHidden(
                                            id: entry.id,
                                            currentValue: entry.isContentHidden
                                        )
                                        if !ok {
                                            noticeCenter.show("Couldn\u{2019}t update entry")
                                        }
                                    }
                                },
                                onBeginTextEdit: {
                                    let toEdit = entry
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isMenuVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        menuEntry = nil
                                        editEntry = toEdit
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isEditVisible = true
                                        }
                                    }
                                },
                                onRemindMe: {
                                    let target = entry
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isMenuVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        menuEntry = nil
                                        openReminderSheet(target)
                                    }
                                },
                                onAddToCollection: {
                                    let toAdd = entry
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isMenuVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        menuEntry = nil
                                        addToCollectionEntry = toAdd
                                        addToCollectionAppearsInPlace = false
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            isAddToCollectionVisible = true
                                        }
                                    }
                                },
                                onDismiss: {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isMenuVisible = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        menuEntry = nil
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
                if isEditVisible, let entry = editEntry {
                    EditEntryFullScreenView(
                        entry: entry,
                        initialText: entry.content,
                        feedViewModel: feedViewModel,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isEditVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                editEntry = nil
                            }
                            // No authoritative reload: the optimistic patch in
                            // updateEntryContent is the visible truth and fans
                            // out to every warm scope. A reload here could
                            // even race the in-flight persist and briefly
                            // revert the edit.
                        },
                        onPersistSuccess: {
                            // Editing is a strong resume signal.
                            recentActivityStore.record(
                                rootId: entry.root_id ?? entry.id,
                                contextEntryId: entry.id,
                                kind: .edited
                            )
                        },
                        onPersistFailure: {
                            // updateEntryContent already rolled the row back.
                            noticeCenter.show("Couldn\u{2019}t save edit")
                        }
                    )
                    .transition(.move(edge: .bottom))
                }
            }
            .overlay {
                if isAddToCollectionVisible, let entry = addToCollectionEntry {
                    AddToCollectionFullScreenView(
                        entry: entry,
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                isAddToCollectionVisible = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                addToCollectionEntry = nil
                                addToCollectionAppearsInPlace = false
                            }
                        },
                        onConfirm: { oldId, newId in
                            // Local-first move: membership patches every warm
                            // scope immediately via the fan-out; persistence
                            // runs behind, counts reconcile quietly.
                            searchCorpusStore.markStale()
                            Task {
                                let ok = await feedViewModel.moveEntry(id: entry.id, from: oldId, to: newId)
                                collectionsViewModel.refreshQuietly()
                                if !ok {
                                    noticeCenter.show("Couldn\u{2019}t move entry")
                                }
                                onEntryMoved?()
                            }
                        }
                    )
                    // Quick-action path appears in place (a quiet fade in its
                    // final position); the ellipsis path keeps its slide.
                    .transition(addToCollectionAppearsInPlace ? .opacity : .move(edge: .bottom))
                }
            }
    }

    private func performDelete(_ entry: Entry) {
        let removals = scopeCoordinator.removeForDelete(id: entry.id)
        Task {
            let deleted = await feedViewModel.deleteEntry(id: entry.id)
            if !deleted {
                scopeCoordinator.restoreAfterFailedDelete(removals)
                noticeCenter.show("Failed to delete")
            }
        }
    }
}

// MARK: - Reminder sheet

private struct EntryReminderHost: ViewModifier {

    @Binding var entry: Entry?
    @Binding var isVisible: Bool

    @EnvironmentObject private var reminderStore: ReminderStore

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if entry != nil {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .transaction { $0.animation = nil }
                            .onTapGesture { dismiss() }

                        if isVisible, let entry {
                            ReminderSheetView(
                                entry: entry,
                                existing: reminderStore.activeReminder(for: entry.id),
                                authorization: reminderStore.authorization,
                                onSet: { mode, fireAt, note in
                                    await reminderStore.save(
                                        entry: entry,
                                        mode: mode,
                                        fireAt: fireAt,
                                        note: note
                                    )
                                },
                                onRemove: {
                                    Task { await reminderStore.removeReminder(entryId: entry.id) }
                                },
                                onDismiss: { dismiss() }
                            )
                            .transition(.move(edge: .bottom))
                        }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.25)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            entry = nil
        }
    }
}
