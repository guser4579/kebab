//
//  SearchLenses.swift
//  kebab
//
//  Explore tiles on Search's resting state: lenses over the user's own
//  thoughts, computed on-device from the corpus Search already holds. Pure
//  logic — no SwiftUI, no store access — so every rule here is testable.
//
//  A tile is just data (id, title, icon, colour, ordered members). The view
//  renders whatever tiles it's handed, so new kinds of tile can be added here
//  without touching the UI.
//

import Foundation

// MARK: - Tuning

nonisolated enum SearchLensTuning {
    /// "Been a while": no thread activity — and no Recent Activity — for this long.
    static let beenAWhileDays = 60
    /// "On this day" / "A month ago": ± this many days around the anniversary.
    static let anniversaryWindowDays = 3
    /// "Long threads": at least this many comments under the root.
    static let longThreadMinimumComments = 3
    /// Random needs at least this many roots to be worth showing.
    static let randomMinimumRoots = 2
    /// Random avoids this many of its most recent picks.
    static let randomAvoidedRecentPicks = 5
}

// MARK: - Tile model

/// Colour key for a tile; resolved to `Style.Color.Tile` in the view layer.
nonisolated enum SearchTileColor: String, Sendable, Hashable, CaseIterable {
    case violet, indigo, azure, sky, teal, green, olive, lemon, amber, pink

    /// Hues a tile without a fixed colour picks from. Pink and amber are
    /// reserved for Fired and Resurfaced, which already mean "something I did".
    static let rotation: [SearchTileColor] = [.violet, .indigo, .azure, .sky, .teal, .green, .olive, .lemon]
}

/// One thought in a lens, with the reason it's there ("Fired 4 times") and
/// the date its relative time reads from.
nonisolated struct SearchLensMember: Hashable, Sendable {
    let entryId: UUID
    let reason: String
    let date: Date
}

nonisolated struct SearchTile: Identifiable, Hashable, Sendable {

    enum Behavior: Hashable, Sendable {
        /// Tapping draws one member at random and opens it.
        case random
        /// Tapping opens the ordered member list.
        case list
    }

    let id: String
    let title: String
    let icon: String
    let behavior: Behavior
    let members: [SearchLensMember]
    /// The tile's own colour. Every v1 tile has one; tiles without one (v2's
    /// generated tiles) take a rotation colour from `assignColors`.
    let fixedColor: SearchTileColor?
    /// Assigned over the visible row by `SearchLenses.assignColors`.
    var color: SearchTileColor = .violet

    var entryIds: [UUID] { members.map(\.entryId) }
}

// MARK: - Lenses

nonisolated enum SearchLenses {

    /// Every visible tile, in display order, coloured. Universe: root thoughts
    /// only, never hidden content. Empty lenses are dropped.
    static func tiles(
        entries: [Entry],
        recentActivity: [RecentActivityItem],
        now: Date,
        calendar: Calendar
    ) -> [SearchTile] {
        let activity = ThreadActivity(entries: entries)
        let roots = entries.filter { $0.parent_id == nil && !$0.isContentHidden }
        let lastActivity: [UUID: Date] = Dictionary(
            uniqueKeysWithValues: roots.map { ($0.id, activity.lastActivity(of: $0)) }
        )
        let newestFirst = roots.sorted(by: newerFirst)

        var tiles: [SearchTile] = []

        // 1 · Random
        if roots.count >= SearchLensTuning.randomMinimumRoots {
            tiles.append(SearchTile(
                id: "random",
                title: "Random",
                icon: "dices",
                behavior: .random,
                members: newestFirst.map { member($0, "Created", $0.created_at) },
                fixedColor: .violet
            ))
        }

        // 2 · On this day, falling back to A month ago
        let window = SearchLensTuning.anniversaryWindowDays
        let onThisDay = newestFirst.filter { isAnniversary(of: $0.created_at, now: now, window: window, calendar: calendar) }
        if !onThisDay.isEmpty {
            tiles.append(listTile("onThisDay", "On this day", "calendar-04", onThisDay.map { member($0, "Created", $0.created_at) }, color: .sky))
        } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now) {
            let matches = newestFirst.filter {
                abs(dayDistance($0.created_at, monthAgo, calendar: calendar)) <= window
            }
            tiles.append(listTile("onThisDay", "A month ago", "calendar-04", matches.map { member($0, "Created", $0.created_at) }, color: .sky))
        }

        // 3 · Been a while
        let staleCutoff = calendar.date(byAdding: .day, value: -SearchLensTuning.beenAWhileDays, to: now) ?? now
        let recentlyTouched = Set(recentActivity.filter { $0.date >= staleCutoff }.map(\.rootId))
        let beenAWhile = roots
            .filter { lastActivity[$0.id, default: $0.created_at] < staleCutoff && !recentlyTouched.contains($0.id) }
            .sorted { lhs, rhs in
                let l = lastActivity[lhs.id, default: lhs.created_at]
                let r = lastActivity[rhs.id, default: rhs.created_at]
                return l != r ? l < r : lhs.id.uuidString < rhs.id.uuidString
            }
        tiles.append(listTile("beenAWhile", "Been a while", "clock-01", beenAWhile.map {
            member($0, "Last touched", lastActivity[$0.id, default: $0.created_at])
        }, color: .olive))

        // 4 · Fired
        let fired = roots
            .filter { $0.fire_count > 0 }
            .sorted(by: byCount(\.fire_count, lastActivity: lastActivity))
        tiles.append(listTile("fired", "Fired", "fire-03", fired.map {
            member($0, "Fired \(times($0.fire_count))", lastActivity[$0.id, default: $0.created_at])
        }, color: .pink))

        // 5 · Resurfaced
        let resurfaced = roots
            .filter { $0.resurface_count > 0 }
            .sorted(by: byCount(\.resurface_count, lastActivity: lastActivity))
        tiles.append(listTile("resurfaced", "Resurfaced", "refresh-04", resurfaced.map {
            member($0, "Resurfaced \(times($0.resurface_count))", lastActivity[$0.id, default: $0.created_at])
        }, color: .amber))

        // 6 · Long threads
        let longThreads = roots
            .filter { activity.descendants(of: $0.id) >= SearchLensTuning.longThreadMinimumComments }
            .sorted { lhs, rhs in
                let l = activity.descendants(of: lhs.id)
                let r = activity.descendants(of: rhs.id)
                return l != r ? l > r : newerFirst(lhs, rhs)
            }
        tiles.append(listTile("longThreads", "Long threads", "message-circle", longThreads.map {
            member($0, "\(activity.descendants(of: $0.id)) comments", lastActivity[$0.id, default: $0.created_at])
        }, color: .teal))

        // 7 · Lists — anything still open first, then newest
        let lists = newestFirst
            .filter { Checklist.hasChecklist($0.content) }
            .map { (entry: $0, open: openItemCount($0.content)) }
        let orderedLists = lists.filter { $0.open > 0 } + lists.filter { $0.open == 0 }
        tiles.append(listTile("lists", "Lists", "tick-02", orderedLists.map {
            member($0.entry, $0.open > 0 ? "\($0.open) open" : "Done", lastActivity[$0.entry.id, default: $0.entry.created_at])
        }, color: .green))

        // 8 · Links (X posts have their own tile)
        let links = newestFirst.filter { $0.linkAttachment != nil && $0.xPostSource == nil }
        tiles.append(listTile("links", "Links", "link-02", links.map { member($0, "Created", $0.created_at) }, color: .azure))

        // 9 · X posts
        let xPosts = newestFirst.filter { $0.xPostSource != nil }
        tiles.append(listTile("xPosts", "X posts", "new-twitter", xPosts.map { member($0, "Created", $0.created_at) }, color: .indigo))

        // 10 · Photos
        let photos = newestFirst.filter { !$0.imageAttachments.isEmpty }
        tiles.append(listTile("photos", "Photos", "image-03", photos.map { member($0, "Created", $0.created_at) }, color: .lemon))

        return assignColors(tiles.filter { !$0.members.isEmpty })
    }

    // MARK: Colour

    /// Tiles with a fixed colour keep it — the ten v1 tiles all differ, so
    /// they never match a neighbour however many are hidden. A tile without
    /// one takes the first rotation colour that differs from its left and
    /// upper neighbours in the two-row, column-major grid; two constraints
    /// over eight colours always succeeds, and the reserved hues never
    /// appear in the rotation.
    static func assignColors(_ tiles: [SearchTile], rows: Int = 2) -> [SearchTile] {
        var coloured = tiles
        for index in coloured.indices {
            if let fixed = coloured[index].fixedColor {
                coloured[index].color = fixed
                continue
            }
            var taken: Set<SearchTileColor> = []
            if index >= rows {
                taken.insert(coloured[index - rows].color)
            }
            if index % rows != 0 {
                taken.insert(coloured[index - 1].color)
            }
            coloured[index].color = SearchTileColor.rotation.first { !taken.contains($0) } ?? .violet
        }
        return coloured
    }

    // MARK: Random

    /// A fresh draw at tap time that avoids the most recent picks: the last
    /// five once there are more than five candidates, and otherwise as many as
    /// still leaves one to draw — so consecutive taps never repeat a thought.
    static func pickRandom<G: RandomNumberGenerator>(
        from candidates: [UUID],
        recentPicks: [UUID],
        using generator: inout G
    ) -> UUID? {
        guard !candidates.isEmpty else { return nil }
        let avoidCount = min(SearchLensTuning.randomAvoidedRecentPicks, candidates.count - 1)
        let avoided = Set(recentPicks.suffix(avoidCount))
        let pool = candidates.filter { !avoided.contains($0) }
        return (pool.isEmpty ? candidates : pool).randomElement(using: &generator)
    }

    // MARK: Helpers

    private static func listTile(
        _ id: String,
        _ title: String,
        _ icon: String,
        _ members: [SearchLensMember],
        color: SearchTileColor
    ) -> SearchTile {
        SearchTile(id: id, title: title, icon: icon, behavior: .list, members: members, fixedColor: color)
    }

    private static func member(_ entry: Entry, _ reason: String, _ date: Date) -> SearchLensMember {
        SearchLensMember(entryId: entry.id, reason: reason, date: date)
    }

    /// Stable newest-first: ties break on id so the order never flickers.
    private static func newerFirst(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.created_at != rhs.created_at
            ? lhs.created_at > rhs.created_at
            : lhs.id.uuidString > rhs.id.uuidString
    }

    private static func byCount(
        _ count: KeyPath<Entry, Int>,
        lastActivity: [UUID: Date]
    ) -> (Entry, Entry) -> Bool {
        { lhs, rhs in
            if lhs[keyPath: count] != rhs[keyPath: count] {
                return lhs[keyPath: count] > rhs[keyPath: count]
            }
            let l = lastActivity[lhs.id, default: lhs.created_at]
            let r = lastActivity[rhs.id, default: rhs.created_at]
            return l != r ? l > r : lhs.id.uuidString > rhs.id.uuidString
        }
    }

    private static func times(_ count: Int) -> String {
        count == 1 ? "once" : "\(count) times"
    }

    private static func openItemCount(_ content: String) -> Int {
        content.components(separatedBy: "\n").filter { $0.hasPrefix(Checklist.uncheckedMarker) }.count
    }

    /// Whole calendar days from `b` to `a` (negative when `a` is earlier).
    private static func dayDistance(_ a: Date, _ b: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: b), to: calendar.startOfDay(for: a)).day ?? .max
    }

    /// True when `created` falls within `window` days of today's month/day in
    /// some previous year. Checks the anniversaries either side of the
    /// creation year so windows that straddle New Year still match.
    private static func isAnniversary(of created: Date, now: Date, window: Int, calendar: Calendar) -> Bool {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard let currentYear = today.year else { return false }
        let createdYear = calendar.component(.year, from: created)
        for year in (createdYear - 1)...(createdYear + 1) where year < currentYear {
            var components = today
            components.year = year
            guard let anniversary = calendar.date(from: components) else { continue }
            if abs(dayDistance(created, anniversary, calendar: calendar)) <= window {
                return true
            }
        }
        return false
    }
}
