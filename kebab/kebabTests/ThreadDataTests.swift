//
//  ThreadDataTests.swift
//  kebabTests
//
//  Ancestry reconstruction for the thread-anchored comment screen.
//  ThreadData derives everything from parent_id truth over the flat
//  thread fetch; these tests pin the walk's ordering, its bounds at
//  pathological depth, and its behavior on malformed local data.
//

import Foundation
import Testing
@testable import kebab

@MainActor
struct ThreadDataTests {

    private static let user = UUID()

    /// A comment row as fetchComments returns it. `depth` is deliberately
    /// settable to nonsense in some tests — ancestry must never consult it.
    private static func comment(
        id: UUID,
        parentId: UUID,
        rootId: UUID,
        depth: Int = 0,
        minutesAgo: Double = 0
    ) -> Entry {
        Entry(
            id: id,
            user_id: user,
            parent_id: parentId,
            root_id: rootId,
            depth: depth,
            content: "c",
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

    /// root → c1 → c2 → … → cN as a strict chain; returns (rootId, chain).
    private static func chain(depth: Int) -> (rootId: UUID, entries: [Entry]) {
        let rootId = UUID()
        var entries: [Entry] = []
        var parentId = rootId
        for level in 1...depth {
            let id = UUID()
            entries.append(comment(
                id: id, parentId: parentId, rootId: rootId,
                depth: level, minutesAgo: Double(depth - level)
            ))
            parentId = id
        }
        return (rootId, entries)
    }

    // MARK: - Ancestry

    @Test func directChildOfRootHasNoAncestors() {
        let (_, entries) = Self.chain(depth: 1)
        let data = ThreadData(entries: entries)
        #expect(data.ancestors(of: entries[0].id).isEmpty)
    }

    @Test func severalLevelsComeBackRootWardFirst() {
        let (_, entries) = Self.chain(depth: 4)
        let data = ThreadData(entries: entries)
        let ancestors = data.ancestors(of: entries[3].id)
        #expect(ancestors.map(\.id) == [entries[0].id, entries[1].id, entries[2].id])
    }

    @Test func depthTwentyFiveIsCompleteAndOrdered() {
        let (_, entries) = Self.chain(depth: 25)
        let data = ThreadData(entries: entries)
        let ancestors = data.ancestors(of: entries[24].id)
        #expect(ancestors.count == 24)
        #expect(ancestors.map(\.id) == entries.dropLast().map(\.id))
    }

    @Test func missingIntermediateParentTruncatesToTheValidPortion() {
        let (_, entries) = Self.chain(depth: 5)
        // Drop c2 (index 1): the walk from c5 reaches c4, c3, then stops at
        // the gap — the portion nearest the anchor still renders.
        let withGap = entries.filter { $0.id != entries[1].id }
        let data = ThreadData(entries: withGap)
        let ancestors = data.ancestors(of: entries[4].id)
        #expect(ancestors.map(\.id) == [entries[2].id, entries[3].id])
    }

    @Test func cyclicCorruptionTerminatesInsteadOfLooping() {
        let rootId = UUID()
        let idA = UUID()
        let idB = UUID()
        // a and b claim each other as parent — impossible server-side
        // (ON DELETE CASCADE + FK), but local state must never hang on it.
        let a = Self.comment(id: idA, parentId: idB, rootId: rootId)
        let b = Self.comment(id: idB, parentId: idA, rootId: rootId)
        let data = ThreadData(entries: [a, b])
        let ancestors = data.ancestors(of: idA)
        #expect(ancestors.map(\.id) == [idB])
    }

    @Test func ancestryIgnoresThePersistedDepthField() {
        let (_, entries) = Self.chain(depth: 3)
        // Lie about depth on every row; parent_id remains truthful.
        let lying = entries.map { entry in
            Self.comment(
                id: entry.id,
                parentId: entry.parent_id!,
                rootId: entry.root_id!,
                depth: 999
            )
        }
        let data = ThreadData(entries: lying)
        let ancestors = data.ancestors(of: entries[2].id)
        #expect(ancestors.map(\.id) == [entries[0].id, entries[1].id])
    }

    @Test func unknownAnchorIdYieldsNothing() {
        let (_, entries) = Self.chain(depth: 3)
        let data = ThreadData(entries: entries)
        #expect(data.ancestors(of: UUID()).isEmpty)
        #expect(data.entry(id: UUID()) == nil)
    }

    // MARK: - Mutation: ancestor removal (the cascade filter)

    @Test func removingAnAncestorSubtreeLeavesNoGhostAnchor() {
        let (_, entries) = Self.chain(depth: 5)
        // Simulate deleting c2: the client filters c2's whole subtree
        // (c2…c5) exactly as deleteCommentOptimistically does.
        var doomed: Set<UUID> = [entries[1].id]
        var changed = true
        while changed {
            changed = false
            for entry in entries {
                if let parent = entry.parent_id,
                   doomed.contains(parent), !doomed.contains(entry.id) {
                    doomed.insert(entry.id)
                    changed = true
                }
            }
        }
        let data = ThreadData(entries: entries.filter { !doomed.contains($0.id) })
        // The old anchor (c5) is gone from thread truth, and the survivor
        // (c1) has a clean, empty ancestry.
        #expect(data.entry(id: entries[4].id) == nil)
        #expect(data.ancestors(of: entries[4].id).isEmpty)
        #expect(data.entry(id: entries[0].id) != nil)
        #expect(data.ancestors(of: entries[0].id).isEmpty)
        #expect(data.totalCount == 1)
    }

    // MARK: - Ordering invariants the spine relies on

    @Test func directChildrenSortOldestFirstRegardlessOfFetchOrder() {
        let rootId = UUID()
        let parent = Self.comment(id: UUID(), parentId: rootId, rootId: rootId, minutesAgo: 30)
        let older = Self.comment(id: UUID(), parentId: parent.id, rootId: rootId, minutesAgo: 20)
        let newer = Self.comment(id: UUID(), parentId: parent.id, rootId: rootId, minutesAgo: 5)
        // Fetch order is newest-first; presentation must be oldest-first.
        let data = ThreadData(entries: [newer, older, parent])
        #expect(data.directChildren(of: parent.id).map(\.id) == [older.id, newer.id])
        #expect(data.subtreeCount(for: parent.id) == 2)
    }
}
