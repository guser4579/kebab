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
    }

    // MARK: - Computed helpers

    /// Top-level collections only (parentId == nil), in the order returned by the backend.
    var parentCollections: [Collection] {
        collections.filter { $0.parentId == nil }
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Create

    @discardableResult
    func createCollection(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            try await repository.createCollection(name: trimmed)
            await loadCollections()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a sub-collection under `parentId`.
    /// Returns the newly created `Collection` (sourced from a fresh `get_my_collections` reload)
    /// on success, or `nil` on failure.
    @discardableResult
    func createSubcollection(parentId: UUID, name: String) async -> Collection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Snapshot existing sub-collection IDs so we can identify the new one after reload.
        let existingIds = Set(collections.filter { $0.parentId == parentId }.map { $0.id })

        do {
            try await repository.createSubcollection(parentId: parentId, name: trimmed)
            await loadCollections()
            // The newly created sub-collection is whichever ID wasn't there before.
            return collections.first { $0.parentId == parentId && !existingIds.contains($0.id) }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Rename

    @discardableResult
    func renameCollection(id: UUID, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            try await repository.renameCollection(id: id, name: trimmed)
            await loadCollections()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Delete

    @discardableResult
    func deleteCollection(id: UUID) async -> Bool {
        do {
            try await repository.deleteCollection(id: id)
            await loadCollections()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
