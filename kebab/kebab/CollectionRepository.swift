import Foundation
import Supabase

private struct CollectionEntryRow: Decodable {
    let collection_id: UUID
}

final class CollectionRepository {

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    func getMyCollections() async throws -> [Collection] {
        let collections: [Collection] = try await supabase
            .rpc("get_my_collections")
            .execute()
            .value
        return collections
    }

    func createCollection(name: String) async throws {
        try await supabase
            .rpc("create_collection", params: ["p_name": name])
            .execute()
    }

    func renameCollection(id: UUID, name: String) async throws {
        try await supabase
            .rpc("rename_collection", params: ["p_collection_id": id.uuidString, "p_name": name])
            .execute()
    }

    func deleteCollection(id: UUID) async throws {
        try await supabase
            .rpc("delete_collection", params: ["p_collection_id": id.uuidString])
            .execute()
    }

    func addEntryToCollection(entryId: UUID, collectionId: UUID) async throws {
        try await supabase
            .rpc("add_entry_to_collection", params: [
                "p_entry_id": entryId.uuidString,
                "p_collection_id": collectionId.uuidString
            ])
            .execute()
    }

    func removeEntryFromCollection(entryId: UUID, collectionId: UUID) async throws {
        try await supabase
            .rpc("remove_entry_from_collection", params: [
                "p_entry_id": entryId.uuidString,
                "p_collection_id": collectionId.uuidString
            ])
            .execute()
    }

    /// Returns the collection ID the entry currently belongs to, or nil if unassigned.
    func getCollectionIdForEntry(entryId: UUID) async throws -> UUID? {
        let rows: [CollectionEntryRow] = try await supabase
            .from("collection_entries")
            .select("collection_id")
            .eq("entry_id", value: entryId)
            .limit(1)
            .execute()
            .value
        return rows.first?.collection_id
    }
}
