//
//  ColdEntryTests.swift
//  kebabTests
//
//  Roots beyond the loaded feed pages live only in the corpus mirror, and an
//  Explore lens is mostly made of them. They must render with the feed's own
//  facts, and an in-place patch must never turn them into new feed arrivals.
//

import Foundation
import Supabase
import Testing
@testable import kebab

@MainActor
struct ColdEntryTests {

    private static func root(id: UUID = UUID(), commentCount: Int? = nil) -> Entry {
        Entry(
            id: id,
            user_id: UUID(),
            parent_id: nil,
            root_id: nil,
            depth: 0,
            content: "old thought",
            created_at: Date(timeIntervalSince1970: 1_000_000),
            pinned_at: nil,
            isContentHidden: false,
            comment_count: commentCount,
            resurface_count: 0,
            fire_count: 0,
            attachments: nil,
            collection_id: nil,
            collection_name: nil,
            collection_parent_id: nil,
            collection_parent_name: nil
        )
    }

    /// No request is ever issued by the paths under test.
    private static func makeViewModel() -> FeedViewModel {
        FeedViewModel(supabase: SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            supabaseKey: "key"
        ))
    }

    @Test("A corpus row gains the feed's comment count and collection breadcrumb")
    func feedRepresentationFillsWhatTheCorpusOmits() {
        let parentId = UUID()
        let collectionId = UUID()

        let entry = SearchCorpusStore.feedRepresentation(
            of: Self.root(),
            commentCount: 4,
            collectionId: collectionId,
            collection: CollectionDisplayInfo(name: "Sub", parentId: parentId, parentName: "Parent")
        )

        #expect(entry.comment_count == 4)
        #expect(entry.collection_id == collectionId)
        #expect(entry.collection_name == "Sub")
        #expect(entry.collection_parent_id == parentId)
        #expect(entry.collection_parent_name == "Parent")
    }

    @Test("Stale carried values give way to what the mirror says now")
    func feedRepresentationOverridesCarriedValues() {
        let filed = Self.root(commentCount: 9)
            .withCollection(id: UUID(), name: "Old", parentId: nil, parentName: nil)

        let entry = SearchCorpusStore.feedRepresentation(
            of: filed,
            commentCount: 2,
            collectionId: nil,
            collection: nil
        )

        #expect(entry.comment_count == 2)
        #expect(entry.collection_id == nil)
        #expect(entry.collection_name == nil)
    }

    @Test("A patch to a cold row stays local and never reaches the feeds")
    func coldPatchNeverBecomesAnArrival() {
        let viewModel = Self.makeViewModel()
        var fannedOut: [Entry] = []
        var mirrored: [Entry] = []
        viewModel.entryResolver = { _ in nil }
        viewModel.onEntryChanged = { fannedOut.append($0) }
        viewModel.onColdEntryChanged = { mirrored.append($0) }

        let cold = Self.root().withFireCount(1)
        viewModel.publishInPlacePatch(cold)

        #expect(fannedOut.isEmpty)
        #expect(mirrored == [cold])
    }

    @Test("A patch to a warm row fans out as it always did")
    func warmPatchFansOut() {
        let viewModel = Self.makeViewModel()
        let warm = Self.root()
        var fannedOut: [Entry] = []
        var mirrored: [Entry] = []
        viewModel.entryResolver = { _ in warm }
        viewModel.onEntryChanged = { fannedOut.append($0) }
        viewModel.onColdEntryChanged = { mirrored.append($0) }

        let patched = warm.withFireCount(1)
        viewModel.publishInPlacePatch(patched)

        #expect(fannedOut == [patched])
        #expect(mirrored.isEmpty)
    }

    @Test("Reconcile adopts an unknown row that matches its scope")
    func reconcileAdoptsUnknownRows() {
        // Pins WHY cold patches bypass onEntryChanged: reconcile treats any
        // unknown row that matches its scope as a new arrival.
        let store = FeedStore(
            supabase: SupabaseClient(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                supabaseKey: "key"
            ),
            scope: .sub(UUID())
        )
        let collectionId: UUID
        if case .sub(let id) = store.scope { collectionId = id } else { return }
        let cold = Self.root().withCollection(id: collectionId, name: "Sub", parentId: nil, parentName: nil)

        store.reconcile(cold)

        #expect(store.entry(id: cold.id) != nil)
    }
}
