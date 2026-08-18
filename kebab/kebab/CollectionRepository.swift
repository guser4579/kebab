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

    /// The raw row the create RPCs return. It lacks `item_count` (so it can't
    /// decode as `Collection`), but its id/name/parent_id are all a caller
    /// needs to build the full local model with itemCount 0.
    private struct CreatedCollectionRow: Decodable {
        let id: UUID
        let name: String
        let parent_id: UUID?
    }

    /// Decodes the created row whether the RPC returns a single record or a
    /// one-row set; nil when the shape is unexpected (callers then fall back
    /// to reload-and-diff).
    private static func decodeCreatedRow(_ data: Data) -> CreatedCollectionRow? {
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(CreatedCollectionRow.self, from: data) {
            return single
        }
        return (try? decoder.decode([CreatedCollectionRow].self, from: data))?.first
    }

    /// Creates a top-level collection and returns it as a full local model
    /// (itemCount 0) decoded from the RPC's own response — no follow-up
    /// list refetch needed. Returns nil if the response shape is unexpected.
    func createCollection(name: String) async throws -> Collection? {
        let response = try await supabase
            .rpc("create_collection", params: ["p_name": name])
            .execute()
        return Self.decodeCreatedRow(response.data).map {
            Collection(id: $0.id, name: $0.name, parentId: $0.parent_id, updatedAt: Date(), itemCount: 0)
        }
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

    /// Atomically moves `entryId` to `collectionId` (nil = All / unfiled) via a
    /// single server-side transaction that verifies ownership of both the entry
    /// and the destination. Replaces the non-atomic remove-then-add pair so a
    /// failure can never leave the entry unfiled. `params` is `[String: String?]`
    /// so a nil destination encodes a JSON null (move to All).
    func moveEntryToCollection(entryId: UUID, collectionId: UUID?) async throws {
        try await supabase
            .rpc("move_entry_to_collection", params: [
                "p_entry_id": entryId.uuidString,
                "p_collection_id": collectionId?.uuidString
            ] as [String: String?])
            .execute()
    }

    /// Creates a sub-collection under `parentId` and returns it as a full
    /// local model (itemCount 0) decoded from the RPC's own response — same
    /// contract as `createCollection`.
    func createSubcollection(parentId: UUID, name: String) async throws -> Collection? {
        let response = try await supabase
            .rpc("create_subcollection", params: [
                "p_parent_id": parentId.uuidString,
                "p_name": name
            ])
            .execute()
        return Self.decodeCreatedRow(response.data).map {
            Collection(id: $0.id, name: $0.name, parentId: $0.parent_id, updatedAt: Date(), itemCount: 0)
        }
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
