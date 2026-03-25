import Foundation
import Combine
import Supabase

/// Drives the feed of entries inside a single collection.
///
/// Mutations that affect the main feed (delete, hide, edit, fire) are delegated to
/// `feedViewModel` so both surfaces stay in sync. Collection-specific mutations
/// (removeFromCollection) additionally reload the collections list and this feed.
@MainActor
final class CollectionFeedViewModel: ObservableObject {

    @Published var entries: [Entry] = []
    @Published var isLoading = false
    @Published var hasCompletedInitialLoad = false
    @Published var errorMessage: String?

    let collection: Collection
    let feedViewModel: FeedViewModel

    private let entryRepository: EntryRepository
    private let collectionRepository: CollectionRepository
    private let collectionsViewModel: CollectionsViewModel

    init(
        collection: Collection,
        supabase: SupabaseClient,
        feedViewModel: FeedViewModel,
        collectionsViewModel: CollectionsViewModel
    ) {
        self.collection = collection
        self.feedViewModel = feedViewModel
        self.collectionsViewModel = collectionsViewModel
        self.entryRepository = EntryRepository(supabase: supabase)
        self.collectionRepository = CollectionRepository(supabase: supabase)
    }

    // MARK: - Load

    func loadEntries() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasCompletedInitialLoad = true
        }
        do {
            entries = try await entryRepository.fetchCollectionEntries(collectionId: collection.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Fire (optimistic, delegated to feedViewModel for haptic + API)

    func fireEntry(entry: Entry) async {
        entries = entries.map { $0.id == entry.id ? $0.withFireCount($0.fire_count + 1) : $0 }
        let ok = await feedViewModel.fireEntry(entry: entry)
        if !ok {
            entries = entries.map { $0.id == entry.id ? $0.withFireCount(entry.fire_count) : $0 }
        }
    }

    // MARK: - Delete

    func deleteEntry(id: UUID) async {
        await feedViewModel.deleteEntry(id: id)
        await collectionsViewModel.loadCollections()
        await loadEntries()
    }

    // MARK: - Hide / Unhide

    @discardableResult
    func toggleEntryHidden(id: UUID, currentValue: Bool) async -> Bool {
        let ok = await feedViewModel.toggleEntryHidden(id: id, currentValue: currentValue)
        if ok { await loadEntries() }
        return ok
    }

    // MARK: - Edit

    @discardableResult
    func updateEntryContent(id: UUID, content: String) async -> Bool {
        let ok = await feedViewModel.updateEntryContent(id: id, content: content)
        if ok {
            entries = entries.map { $0.id == id ? $0.withContent(content) : $0 }
        }
        return ok
    }

    // MARK: - Remove from collection

    /// Removes the entry from the collection system entirely, returning it to the primary feed.
    /// This is correct for both parent-collection and sub-collection contexts.
    @discardableResult
    func removeFromCollection(entryId: UUID) async -> Bool {
        do {
            try await collectionRepository.removeEntryFromCollection(
                entryId: entryId,
                collectionId: collection.id
            )
            Haptics.mediumTap()
            await feedViewModel.loadEntries()
            await collectionsViewModel.loadCollections()
            await loadEntries()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Send entry (sub-collection context)

    /// Creates a new root entry and immediately assigns it to this collection.
    /// Used when composing from a sub-collection detail screen so the entry
    /// is never transiently visible in the primary feed.
    func sendEntry(content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        errorMessage = nil
        do {
            let entryId = try await entryRepository.insertEntry(content: trimmed)
            try await collectionRepository.addEntryToCollection(
                entryId: entryId,
                collectionId: collection.id
            )
            Haptics.mediumTap()
            await feedViewModel.loadEntries()
            await collectionsViewModel.loadCollections()
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
