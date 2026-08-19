//
//  FeedStoreOrderingTests.swift
//  kebabTests
//
//  FeedStore owns the feed's newest-first array and the live-edge rules
//  that decide whether a new entry joins the rendered list or waits in the
//  arrival buffer. Those rules are what keep the user's reading position
//  stable, and they are stated in product terms (newest, older, live edge)
//  rather than screen coordinates — so they hold identically whichever edge
//  the feed paints the newest entry at. These tests pin them.
//

import Foundation
import Supabase
import Testing
@testable import kebab

@MainActor
struct FeedStoreOrderingTests {

    private static let user = UUID()

    /// No request is ever issued by the paths under test: every method here
    /// is local bookkeeping over an already-loaded array.
    private static func makeStore() -> FeedStore {
        FeedStore(
            supabase: SupabaseClient(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                supabaseKey: "key"
            ),
            // A fresh scope id per store keeps each test off every other
            // test's disk cache.
            scope: .sub(UUID())
        )
    }

    private static func entry(minutesAgo: Double = 0) -> Entry {
        Entry(
            id: UUID(),
            user_id: user,
            parent_id: nil,
            root_id: nil,
            depth: 0,
            content: "e",
            created_at: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
            pinned_at: nil,
            isContentHidden: false,
            comment_count: nil,
            resurface_count: 0,
            fire_count: 0,
            attachments: nil,
            collection_id: nil,
            collection_name: nil,
            collection_parent_id: nil,
            collection_parent_name: nil
        )
    }

    // MARK: - Live edge

    @Test func promotedEntryAtLiveEdgeLandsAtIndexZero() {
        let store = Self.makeStore()
        let older = Self.entry(minutesAgo: 20)
        let newer = Self.entry(minutesAgo: 5)

        store.adoptPromoted(older)
        store.adoptPromoted(newer)

        // Newest first: the most recently adopted entry heads the array.
        #expect(store.entries.map(\.id) == [newer.id, older.id])
        #expect(store.entries.first?.id == newer.id)
        #expect(store.unseenCount == 0)
    }

    // MARK: - Away from the live edge

    @Test func ownEntryHeldWhileAwayLeavesRenderedEntriesUntouched() {
        let store = Self.makeStore()
        let existing = Self.entry(minutesAgo: 20)
        store.adoptPromoted(existing)

        store.didLeaveLiveEdge()
        let mine = Self.entry()
        store.holdOwnEntry(id: mine.id)

        #expect(store.heldPendingIds.contains(mine.id))
        #expect(store.unseenCount == 1)
        #expect(store.entries.map(\.id) == [existing.id])

        // Promotion of a held entry buffers it — it must not appear in the
        // viewport, and it must not be counted twice.
        store.adoptPromoted(mine)
        #expect(store.entries.map(\.id) == [existing.id])
        #expect(store.unseenCount == 1)
        #expect(!store.heldPendingIds.contains(mine.id))
    }

    @Test func arrivalWhileAwayCountsAsUnseenWithoutRendering() {
        let store = Self.makeStore()
        let existing = Self.entry(minutesAgo: 20)
        store.adoptPromoted(existing)

        store.didLeaveLiveEdge()
        let arrival = Self.entry()
        store.adoptPromoted(arrival)

        #expect(store.entries.map(\.id) == [existing.id])
        #expect(store.unseenCount == 1)
    }

    // MARK: - Returning to the live edge

    @Test func reachingLiveEdgeRevealsBufferedArrivalsNewestFirst() {
        let store = Self.makeStore()
        let existing = Self.entry(minutesAgo: 60)
        store.adoptPromoted(existing)

        store.didLeaveLiveEdge()
        let first = Self.entry(minutesAgo: 20)
        let second = Self.entry(minutesAgo: 5)
        store.adoptPromoted(first)
        store.adoptPromoted(second)
        #expect(store.unseenCount == 2)
        #expect(store.entries.map(\.id) == [existing.id])

        store.didReachLiveEdge()

        // The buffer is prepended in the order it holds — never re-sorted by
        // created_at, which would demote a resurfaced entry whose rank comes
        // from feed_order_at.
        #expect(store.entries.map(\.id) == [second.id, first.id, existing.id])
        #expect(store.unseenCount == 0)
        #expect(store.heldPendingIds.isEmpty)
    }

    @Test func reachingLiveEdgeWithNothingBufferedLeavesOrderAlone() {
        let store = Self.makeStore()
        let older = Self.entry(minutesAgo: 20)
        let newer = Self.entry(minutesAgo: 5)
        store.adoptPromoted(older)
        store.adoptPromoted(newer)

        store.didReachLiveEdge()

        #expect(store.entries.map(\.id) == [newer.id, older.id])
        #expect(store.unseenCount == 0)
    }

    // MARK: - Targeted removal

    @Test func failedDeleteRestoresTheEntryToItsOriginalIndex() {
        let store = Self.makeStore()
        let oldest = Self.entry(minutesAgo: 60)
        let middle = Self.entry(minutesAgo: 20)
        let newest = Self.entry(minutesAgo: 5)
        store.adoptPromoted(oldest)
        store.adoptPromoted(middle)
        store.adoptPromoted(newest)

        let snapshot = store.removeForDelete(id: middle.id)
        #expect(snapshot != nil)
        #expect(store.entries.map(\.id) == [newest.id, oldest.id])

        store.restore(snapshot!)
        #expect(store.entries.map(\.id) == [newest.id, middle.id, oldest.id])
    }
}
