import Foundation
import Combine
import Supabase

@MainActor
final class CollectionsViewModel: ObservableObject {

    @Published var collections: [Collection] = []
    @Published var isLoading: Bool = false
    @Published var hasCompletedInitialLoad: Bool = false
    @Published var errorMessage: String?

    private let repository: CollectionRepository

    init(supabase: SupabaseClient) {
        self.repository = CollectionRepository(supabase: supabase)
        // Offline read layer: chips and pickers render instantly from the
        // last-known collections list.
        collections = LocalStore.load([Collection].self, from: "collections") ?? []
        hasCompletedInitialLoad = !collections.isEmpty
    }

    // MARK: - Computed helpers

    /// Top-level collections only (parentId == nil), sorted alphabetically —
    /// a stable order users can memorize, unlike recently-changed-first.
    var parentCollections: [Collection] {
        collections
            .filter { $0.parentId == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Sub-collections belonging to `parentId`, sorted alphabetically.
    func subCollections(for parentId: UUID) -> [Collection] {
        collections
            .filter { $0.parentId == parentId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Load

    func loadCollections() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasCompletedInitialLoad = true
        }

        do {
            collections = try await repository.getMyCollections()
            LocalStore.save(collections, as: "collections")
        } catch {
            // Offline or failed refresh: keep showing the cached list.
            errorMessage = error.localizedDescription
        }
    }

    /// Quiet background reconcile: refetches the authoritative list (fresh
    /// item counts, server timestamps) without flipping isLoading or touching
    /// errorMessage — pickers and chips never see a loading state from it.
    func refreshQuietly() {
        Task {
            guard let fresh = try? await repository.getMyCollections() else { return }
            if fresh != collections {
                collections = fresh
                LocalStore.save(collections, as: "collections")
            }
            hasCompletedInitialLoad = true
        }
    }

    // MARK: - Create

    /// Creates a top-level collection. One RPC: the created row comes back
    /// from the create call itself and is appended locally — no follow-up
    /// list refetch before the caller can navigate into it. A quiet
    /// reconcile fetches authoritative counts behind.
    @discardableResult
    func createCollection(name: String) async -> Collection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            if let created = try await repository.createCollection(name: trimmed) {
                collections.append(created)
                LocalStore.save(collections, as: "collections")
                refreshQuietly()
                return created
            }
            // Unexpected RPC response shape: fall back to reload-and-diff.
            let existingIds = Set(collections.filter { $0.parentId == nil }.map { $0.id })
            await loadCollections()
            return collections.first { $0.parentId == nil && !existingIds.contains($0.id) }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Creates a sub-collection under `parentId` — same one-RPC contract as
    /// `createCollection`.
    @discardableResult
    func createSubcollection(parentId: UUID, name: String) async -> Collection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            if let created = try await repository.createSubcollection(parentId: parentId, name: trimmed) {
                collections.append(created)
                LocalStore.save(collections, as: "collections")
                refreshQuietly()
                return created
            }
            let existingIds = Set(collections.filter { $0.parentId == parentId }.map { $0.id })
            await loadCollections()
            return collections.first { $0.parentId == parentId && !existingIds.contains($0.id) }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Rename (local-first)

    /// Applies a rename to the local model immediately — call before
    /// dismissing the naming surface. Returns the renamed row, or nil when
    /// the collection is unknown locally.
    func applyLocalRename(id: UUID, name: String) -> Collection? {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return nil }
        let old = collections[idx]
        let renamed = Collection(
            id: old.id,
            name: name,
            parentId: old.parentId,
            updatedAt: Date(),
            itemCount: old.itemCount
        )
        collections[idx] = renamed
        LocalStore.save(collections, as: "collections")
        return renamed
    }

    /// Persists a rename already applied via `applyLocalRename`; rolls the
    /// local row back to `previous` on a genuine failure.
    func persistRename(id: UUID, name: String, rollbackTo previous: Collection) async -> Bool {
        do {
            try await repository.renameCollection(id: id, name: name)
            refreshQuietly()
            return true
        } catch {
            if let idx = collections.firstIndex(where: { $0.id == id }) {
                collections[idx] = previous
                LocalStore.save(collections, as: "collections")
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Delete (local-first)

    /// Removes a collection — and, for a parent, its sub-collections — from
    /// the local model immediately. Returns the removed rows for restore.
    func removeLocally(collectionId: UUID) -> [Collection] {
        let removed = collections.filter { $0.id == collectionId || $0.parentId == collectionId }
        guard !removed.isEmpty else { return [] }
        collections.removeAll { $0.id == collectionId || $0.parentId == collectionId }
        LocalStore.save(collections, as: "collections")
        return removed
    }

    /// A failed delete: put the removed rows back.
    func restoreLocally(_ rows: [Collection]) {
        let known = Set(collections.map { $0.id })
        collections.append(contentsOf: rows.filter { !known.contains($0.id) })
        LocalStore.save(collections, as: "collections")
    }

    /// Persists a delete already applied via `removeLocally`.
    func persistDelete(id: UUID) async -> Bool {
        do {
            try await repository.deleteCollection(id: id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
