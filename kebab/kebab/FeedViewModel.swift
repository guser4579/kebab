import Foundation
import Combine
import Supabase

@MainActor
final class FeedViewModel: ObservableObject {

    @Published var entries: [Entry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let repository: EntryRepository
    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.repository = EntryRepository(supabase: supabase)
        self.supabase = supabase
    }

    func loadEntries() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            entries = try await repository.fetchRootEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendEntry(content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        errorMessage = nil
        do {
            try await repository.insertEntry(content: trimmed)
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteEntry(id: UUID) async {
        errorMessage = nil
        do {
            try await repository.deleteEntry(id: id)
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleEntryHidden(id: UUID, currentValue: Bool) async {
        do {
            try await supabase
                .from("entries")
                .update(["is_content_hidden": !currentValue])
                .eq("id", value: id)
                .execute()

            await loadEntries()
        } catch {
            print("Failed to toggle entry hidden state:", error)
        }
    }
}
