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
            .select("id,user_id,parent_id,root_id,content,created_at,pinned_at,is_content_hidden,comment_count,resurface_count,attachments")
            .order("feed_order_at", ascending: true)
            .execute()
            .value
        return entries
    }

    func fetchComments(rootId: UUID) async throws -> [Entry] {
        let entries: [Entry] = try await supabase
            .from("entries")
            .select("id,user_id,parent_id,root_id,content,created_at,pinned_at,is_content_hidden,resurface_count,attachments")
            .eq("root_id", value: rootId)
            .order("created_at", ascending: false)
            .execute()
            .value
        return entries.filter { $0.parent_id != nil }
    }

    @discardableResult
    func insertEntry(content: String, attachments: [EntryAttachment]? = nil) async throws -> UUID {
        do {
            let session = try await supabase.auth.session
            let userId = session.user.id

            let payload = InsertEntryPayload(
                user_id: userId,
                parent_id: nil,
                root_id: nil,
                content: content,
                attachments: attachments
            )

            let inserted: InsertedRow = try await supabase
                .from("entries")
                .insert(payload)
                .select("id")
                .single()
                .execute()
                .value

            return inserted.id

        } catch {
            print("INSERT ERROR:", error)
            throw error
        }
    }

    func updateAttachments(entryId: UUID, attachments: [EntryAttachment]) async throws {
        let payload = AttachmentUpdatePayload(attachments: attachments)
        try await supabase
            .from("entries")
            .update(payload)
            .eq("id", value: entryId)
            .execute()
    }

    func searchEntries(query: String) async throws -> [Entry] {
        let entries: [Entry] = try await supabase
            .rpc("search_entries", params: ["search_query": query])
            .execute()
            .value
        return entries
    }

    func resurfaceEntry(id: UUID) async throws {
        try await supabase
            .rpc("resurface_entry", params: ["entry_id": id.uuidString])
            .execute()
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
        let attachments: [EntryAttachment]?
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

    private struct InsertedRow: Decodable {
        let id: UUID
    }

    private struct AttachmentUpdatePayload: Encodable {
        let attachments: [EntryAttachment]
    }
}
