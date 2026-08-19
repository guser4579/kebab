//
//  ReminderRepository.swift
//  kebab
//

import Foundation
import Supabase

/// Server side of the durable reminder record. The table is tiny and
/// user-scoped by RLS; the whole set fits in one request, so there is no
/// pagination and no per-entry lookup.
final class ReminderRepository {

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    private static let columns =
        "entry_id,user_id,fire_at,mode,note,created_at,acknowledged_at,note_dismissed_at"

    func fetchAll() async throws -> [EntryReminder] {
        try await supabase
            .from("entry_reminders")
            .select(Self.columns)
            .execute()
            .value
    }

    /// One row per entry: the primary key is `entry_id`, so an upsert is
    /// exactly the "one active reminder per entry" rule expressed in SQL.
    func upsert(_ reminder: EntryReminder) async throws {
        try await supabase
            .from("entry_reminders")
            .upsert(reminder, onConflict: "entry_id")
            .execute()
    }

    func delete(entryId: UUID) async throws {
        try await supabase
            .from("entry_reminders")
            .delete()
            .eq("entry_id", value: entryId)
            .execute()
    }
}
