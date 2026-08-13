//
//  CollectionFilter.swift
//  kebab
//

import Foundation

/// Single-select collection scope applied to the feed.
///
/// At most one collection filter is active at a time (tapping a different
/// collection chip replaces the previous filter). The "has link" filter is an
/// independent boolean on FeedViewModel and can combine with any collection
/// filter.
enum CollectionFilter: Hashable, Equatable {
    /// A parent collection plus all of its sub-collections ("View all").
    /// Also used for parent collections without subs.
    case all(parentId: UUID)
    /// Exactly one collection — a sub-collection picked from the chip sheet.
    case single(id: UUID)

    /// The collection new composer entries are added to while this filter is
    /// active: the parent itself for `.all`, the specific collection for `.single`.
    var targetCollectionId: UUID {
        switch self {
        case .all(let parentId): return parentId
        case .single(let id):    return id
        }
    }
}
