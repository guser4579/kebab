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
