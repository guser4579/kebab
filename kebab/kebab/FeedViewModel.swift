import Foundation
import Combine
import Supabase

@MainActor
final class FeedViewModel: ObservableObject {

    @Published var entries: [Entry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    var feedEntries: [Entry] {
        entries.filter { $0.pinned_at == nil }
    }

    var pinnedEntries: [Entry] {
        entries.filter { $0.pinned_at != nil }
               .sorted { $0.pinned_at! < $1.pinned_at! }
    }

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

    func togglePin(entry: Entry) async {
        do {
            try await repository.togglePin(id: entry.id, pin: entry.pinned_at == nil)
            await loadEntries()
        } catch {
            print("Failed to toggle pin:", error)
        }
    }

    func loadComments(rootId: UUID) async -> [Entry] {
        do {
            return try await repository.fetchComments(rootId: rootId)
        } catch {
            return []
        }
    }

    func sendComment(content: String, rootEntry: Entry) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let session = try await supabase.auth.session
            let payload = InsertCommentPayload(
                user_id: session.user.id,
                parent_id: rootEntry.id,
                root_id: rootEntry.id,
                content: trimmed,
                is_content_hidden: false
            )
            try await supabase
                .from("entries")
                .insert(payload)
                .execute()
        } catch {
            print("Failed to send comment:", error)
        }
    }
}

private struct InsertCommentPayload: Encodable {
    let user_id: UUID
    let parent_id: UUID
    let root_id: UUID
    let content: String
    let is_content_hidden: Bool
}
