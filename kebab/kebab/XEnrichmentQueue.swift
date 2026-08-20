//
//  XEnrichmentQueue.swift
//  kebab
//

import Foundation

/// A source whose X lookup failed for a reason worth trying again — offline at
/// save time, a timeout, a rate limit, X briefly down.
///
/// Permanent verdicts never land here: those are written onto the attachment as
/// `unavailable` and are never asked about again.
nonisolated struct PendingXEnrichment: Codable, Sendable, Equatable, Identifiable {
    /// The entry that owns the source. Stable and client-generated, so this
    /// survives promotion, relaunch, and reconciliation.
    let id: UUID
    let postID: String
    /// The link attachment's own url, so the drain patches the right element
    /// on entries that carry several attachments.
    let sourceURL: String
    var attempts: Int
}

/// Bounded, durable retry for X enrichment.
///
/// This is deliberately NOT a background refresh system. It exists for exactly
/// one case: the user saved a post while the lookup couldn't succeed, so Kebab
/// still owes them one. Each source gets at most `maxAttempts` lookups, ever,
/// after which it stays a generic link card forever. Nothing here refreshes an
/// already-resolved post — X bills per read, and a saved post is a keepsake,
/// not a live view.
///
/// Stored per user (`xEnrichment_<uid>`) and, being a LocalStore file, also
/// wiped wholesale by the sign-out purge.
nonisolated enum XEnrichmentQueue {

    /// Includes the attempt made at save time, so a source is looked up at most
    /// three times across its entire life.
    static let maxAttempts = 3

    private static func key(_ userId: UUID) -> String {
        "xEnrichment_\(userId.uuidString)"
    }

    static func load(userId: UUID) -> [PendingXEnrichment] {
        LocalStore.load([PendingXEnrichment].self, from: key(userId)) ?? []
    }

    private static func save(_ items: [PendingXEnrichment], userId: UUID) {
        LocalStore.save(items, as: key(userId))
    }

    /// Records that an attempt was spent. Returns nothing to the caller: at the
    /// ceiling the item is simply not written back, which is how the retry loop
    /// terminates.
    static func recordAttempt(
        entryId: UUID,
        postID: String,
        sourceURL: String,
        userId: UUID
    ) {
        var items = load(userId: userId)
        if let index = items.firstIndex(where: { $0.id == entryId }) {
            items[index].attempts += 1
            if items[index].attempts >= maxAttempts {
                items.remove(at: index)
            }
        } else {
            items.append(
                PendingXEnrichment(id: entryId, postID: postID, sourceURL: sourceURL, attempts: 1)
            )
        }
        save(items, userId: userId)
    }

    /// Drops an item because it reached a durable verdict — resolved, or
    /// permanently unavailable.
    static func remove(entryId: UUID, userId: UUID) {
        let items = load(userId: userId)
        guard items.contains(where: { $0.id == entryId }) else { return }
        save(items.filter { $0.id != entryId }, userId: userId)
    }
}
