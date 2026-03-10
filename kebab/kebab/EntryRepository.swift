import Foundation
import Supabase

final class EntryRepository {

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func fetchRootEntries() async throws -> [Entry] {
        let entries: [Entry] = try await supabase
            .from("entries_with_comment_counts")
            .select("id,user_id,parent_id,root_id,content,created_at,pinned_at,is_content_hidden,comment_count")
            .order("created_at", ascending: true)
            .execute()
            .value
        return entries
    }

    func fetchComments(rootId: UUID) async throws -> [Entry] {
        let entries: [Entry] = try await supabase
            .from("entries")
            .select("id,user_id,parent_id,root_id,content,created_at,pinned_at,is_content_hidden")
            .eq("root_id", value: rootId)
            .order("created_at", ascending: false)
            .execute()
            .value
        return entries.filter { $0.parent_id != nil }
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

    func togglePin(id: UUID, pin: Bool) async throws {
        let payload = PinUpdatePayload(
            pinned_at: pin ? ISO8601DateFormatter().string(from: Date()) : nil
        )
        try await supabase
            .from("entries")
            .update(payload)
            .eq("id", value: id)
            .execute()
    }

    private struct InsertEntryPayload: Encodable {
        let user_id: UUID
        let parent_id: UUID?
        let root_id: UUID?
        let content: String
    }

    private struct PinUpdatePayload: Encodable {
        let pinned_at: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pinned_at, forKey: .pinned_at)
        }

        enum CodingKeys: String, CodingKey {
            case pinned_at
        }
    }
}
