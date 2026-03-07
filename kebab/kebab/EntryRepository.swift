import Foundation
import Supabase

final class EntryRepository {

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func fetchRootEntries() async throws -> [Entry] {
        let entries: [Entry] = try await supabase
            .from("entries")
            .select("id,user_id,parent_id,root_id,content,created_at,pinned_at,is_content_hidden")
            .order("created_at", ascending: true)
            .execute()
            .value

        return entries.filter { $0.parent_id == nil }
    }

    func insertEntry(content: String) async throws {
        do {
            let session = try await supabase.auth.session
            let userId = session.user.id

            let payload = InsertEntryPayload(
                user_id: userId,
                parent_id: nil,
                root_id: nil,
                content: content
            )

            let response = try await supabase
                .from("entries")
                .insert(payload)
                .execute()

            print("INSERT RESPONSE:", response)

        } catch {
            print("INSERT ERROR:", error)
            throw error
        }
    }

    func deleteEntry(id: UUID) async throws {
        try await supabase
            .from("entries")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    private struct InsertEntryPayload: Encodable {
        let user_id: UUID
        let parent_id: UUID?
        let root_id: UUID?
        let content: String
    }
}
