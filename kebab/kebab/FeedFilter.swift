//
//  FeedFilter.swift
//  kebab
//

import Foundation

enum FeedFilter: Hashable, Equatable {
    case hasLink
    case mostFlames
    case mostComments
    case mostResurfaced
    case random
    case collection(id: UUID, name: String)

    var displayName: String {
        switch self {
        case .hasLink:               return "has link"
        case .mostFlames:            return "most flames"
        case .mostComments:          return "most comments"
        case .mostResurfaced:        return "most resurfaced"
        case .random:                return "random"
        case .collection(_, let n):  return n
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .hasLink:              hasher.combine(0)
        case .mostFlames:           hasher.combine(1)
        case .mostComments:         hasher.combine(2)
        case .mostResurfaced:       hasher.combine(3)
        case .random:               hasher.combine(4)
        case .collection(let id, _): hasher.combine(5); hasher.combine(id)
        }
    }

    static func == (lhs: FeedFilter, rhs: FeedFilter) -> Bool {
        switch (lhs, rhs) {
        case (.hasLink, .hasLink),
             (.mostFlames, .mostFlames),
             (.mostComments, .mostComments),
             (.mostResurfaced, .mostResurfaced),
             (.random, .random):
            return true
        case (.collection(let a, _), .collection(let b, _)):
            return a == b
        default:
            return false
        }
    }
}
