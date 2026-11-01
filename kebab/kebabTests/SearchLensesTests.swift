//
//  SearchLensesTests.swift
//  kebabTests
//
//  Explore lenses on Search's resting state. Membership, ordering, and
//  colouring are pure functions of (entries, recent activity, now,
//  calendar); these tests pin each lens's rule, the Random draw, and the
//  neighbour-colour guarantee.
//

import Foundation
import Testing
@testable import kebab

struct SearchLensesTests {

    private static let user = UUID()

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Fixed "today": 15 June 2026, noon UTC.
    private static let now = date(2026, 6, 15)

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    private static func root(
        _ content: String = "thought",
        created: Date = daysAgo(1),
        hidden: Bool = false,
        fires: Int = 0,
        resurfaces: Int = 0,
        attachments: [EntryAttachment]? = nil
    ) -> Entry {
        Entry(
            id: UUID(),
            user_id: user,
            parent_id: nil,
            root_id: nil,
            depth: 0,
            content: content,
            created_at: created,
            pinned_at: nil,
            isContentHidden: hidden,
            comment_count: nil,
            resurface_count: resurfaces,
            fire_count: fires,
            attachments: attachments,
            collection_id: nil,
            collection_name: nil,
            collection_parent_id: nil,
            collection_parent_name: nil
        )
    }

    private static func comment(on root: Entry, created: Date = daysAgo(1), hidden: Bool = false) -> Entry {
        Entry(
            id: UUID(),
            user_id: user,
            parent_id: root.id,
            root_id: root.id,
            depth: 1,
            content: "comment",
            created_at: created,
            pinned_at: nil,
            isContentHidden: hidden,
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

    private static let link = EntryAttachment(
        type: "link", url: "https://example.com/a", title: "A", favicon_url: nil, image_url: nil
    )

    private static let image = EntryAttachment(
        type: "image", url: "https://example.com/a.jpg", title: nil, favicon_url: nil, image_url: nil
    )

    private static let xPost: EntryAttachment = {
        let json = """
        {
          "kind": "x_post",
          "status": "resolved",
          "resolved_at": "2026-06-01T00:00:00Z",
          "x_post": {
            "post_id": "1",
            "url": "https://x.com/kebabapp/status/1",
            "text": "post",
            "created_at": null,
            "author": { "id": "42", "name": "Kebab", "username": "kebabapp" },
            "media": []
          }
        }
        """
        let source = try! JSONDecoder().decode(SourceMetadata.self, from: Data(json.utf8))
        return EntryAttachment(
            type: "link", url: "https://x.com/kebabapp/status/1", title: nil,
            favicon_url: nil, image_url: nil, source: source
        )
    }()

    private static func tiles(
        _ entries: [Entry],
        activity: [RecentActivityItem] = [],
        now: Date = now
    ) -> [SearchTile] {
        SearchLenses.tiles(entries: entries, recentActivity: activity, now: now, calendar: calendar)
    }

    private static func tile(_ id: String, in tiles: [SearchTile]) -> SearchTile? {
        tiles.first { $0.id == id }
    }

    // MARK: - Universe

    @Test("Hidden roots never appear in any lens, and comments are never members")
    func hiddenContentAndCommentsNeverAppear() {
        let hidden = Self.root(
            "- [ ] secret",
            created: Self.date(2025, 6, 15),
            hidden: true,
            fires: 3,
            resurfaces: 2,
            attachments: [Self.link, Self.image]
        )
        let visible = Self.root(fires: 1)
        let other = Self.root()
        let hiddenComment = Self.comment(on: visible, hidden: true)
        let comments = (0..<3).map { _ in Self.comment(on: hidden) }

        let tiles = Self.tiles([hidden, visible, other, hiddenComment] + comments)

        let everyMember = tiles.flatMap(\.entryIds)
        #expect(!everyMember.contains(hidden.id))
        #expect(!everyMember.contains(hiddenComment.id))
        #expect(comments.allSatisfy { !everyMember.contains($0.id) })
        #expect(Self.tile("fired", in: tiles)?.entryIds == [visible.id])
    }

    // MARK: - On this day

    @Test("On this day matches previous years within ±3 days, newest first")
    func onThisDayMatchesPreviousYears() {
        let lastYear = Self.root(created: Self.date(2025, 6, 17))
        let twoYearsAgo = Self.root(created: Self.date(2024, 6, 12))
        let outsideWindow = Self.root(created: Self.date(2025, 6, 19))
        let thisYear = Self.root(created: Self.date(2026, 6, 14))

        let tile = Self.tile("onThisDay", in: Self.tiles([lastYear, twoYearsAgo, outsideWindow, thisYear]))

        #expect(tile?.title == "On this day")
        #expect(tile?.entryIds == [lastYear.id, twoYearsAgo.id])
    }

    @Test("On this day matches across New Year")
    func onThisDayStraddlesNewYear() {
        let now = Self.date(2026, 1, 1)
        let lateDecember = Self.root(created: Self.date(2024, 12, 30))
        let lastWeek = Self.root(created: Self.date(2025, 12, 30))

        let tile = Self.tile("onThisDay", in: Self.tiles([lateDecember, lastWeek], now: now))

        #expect(tile?.title == "On this day")
        #expect(tile?.entryIds == [lateDecember.id])
    }

    @Test("With no anniversaries it falls back to A month ago")
    func fallsBackToAMonthAgo() {
        let monthAgo = Self.root(created: Self.date(2026, 5, 13))
        let tooOld = Self.root(created: Self.date(2026, 5, 5))

        let tile = Self.tile("onThisDay", in: Self.tiles([monthAgo, tooOld]))

        #expect(tile?.title == "A month ago")
        #expect(tile?.entryIds == [monthAgo.id])
    }

    @Test("With neither, the tile is absent")
    func onThisDayAbsentWhenNothingMatches() {
        let tiles = Self.tiles([Self.root(created: Self.daysAgo(10)), Self.root(created: Self.daysAgo(100))])
        #expect(Self.tile("onThisDay", in: tiles) == nil)
    }

    // MARK: - Been a while

    @Test("Been a while uses thread activity and respects Recent Activity, oldest first")
    func beenAWhileUsesDescendantActivity() {
        let oldest = Self.root(created: Self.daysAgo(300))
        let old = Self.root(created: Self.daysAgo(90))
        let revivedByComment = Self.root(created: Self.daysAgo(200))
        let reopened = Self.root(created: Self.daysAgo(150))
        let reopenedLongAgo = Self.root(created: Self.daysAgo(120))
        let fresh = Self.root(created: Self.daysAgo(5))

        let entries = [
            oldest, old, revivedByComment, reopened, reopenedLongAgo, fresh,
            Self.comment(on: revivedByComment, created: Self.daysAgo(3)),
            Self.comment(on: old, created: Self.daysAgo(80))
        ]
        let activity = [
            RecentActivityItem(rootId: reopened.id, contextEntryId: reopened.id, kind: .viewed, date: Self.daysAgo(10)),
            RecentActivityItem(rootId: reopenedLongAgo.id, contextEntryId: reopenedLongAgo.id, kind: .viewed, date: Self.daysAgo(70))
        ]

        let tile = Self.tile("beenAWhile", in: Self.tiles(entries, activity: activity))

        #expect(tile?.entryIds == [oldest.id, reopenedLongAgo.id, old.id])
        #expect(tile?.members.last?.date == Self.daysAgo(80))
    }

    // MARK: - Counts

    @Test("Fired and Resurfaced sort by count, then by last activity")
    func countLensesOrdering() {
        let twiceRecent = Self.root(created: Self.daysAgo(2), fires: 2, resurfaces: 1)
        let twiceOld = Self.root(created: Self.daysAgo(20), fires: 2)
        let fiveTimes = Self.root(created: Self.daysAgo(40), fires: 5, resurfaces: 3)

        let tiles = Self.tiles([twiceOld, fiveTimes, twiceRecent])

        #expect(Self.tile("fired", in: tiles)?.entryIds == [fiveTimes.id, twiceRecent.id, twiceOld.id])
        #expect(Self.tile("fired", in: tiles)?.members.first?.reason == "Fired 5 times")
        #expect(Self.tile("resurfaced", in: tiles)?.entryIds == [fiveTimes.id, twiceRecent.id])
        #expect(Self.tile("resurfaced", in: tiles)?.members.last?.reason == "Resurfaced once")
    }

    @Test("Long threads need at least three comments, most comments first")
    func longThreadsThreshold() {
        let two = Self.root()
        let three = Self.root()
        let five = Self.root()
        let entries = [two, three, five]
            + (0..<2).map { _ in Self.comment(on: two) }
            + (0..<3).map { _ in Self.comment(on: three) }
            + (0..<5).map { _ in Self.comment(on: five) }

        let tile = Self.tile("longThreads", in: Self.tiles(entries))

        #expect(tile?.entryIds == [five.id, three.id])
        #expect(tile?.members.first?.reason == "5 comments")
    }

    // MARK: - Content kinds

    @Test("Lists put anything with unchecked items first, then newest")
    func listsOrdering() {
        let doneNew = Self.root("- [x] a\n- [x] b", created: Self.daysAgo(1))
        let openOld = Self.root("- [ ] a\n- [x] b\n- [ ] c", created: Self.daysAgo(30))
        let openNew = Self.root("intro\n- [ ] a", created: Self.daysAgo(5))
        let doneOld = Self.root("- [x] a", created: Self.daysAgo(40))
        let notAList = Self.root("just text")

        let tile = Self.tile("lists", in: Self.tiles([doneNew, openOld, openNew, doneOld, notAList]))

        #expect(tile?.entryIds == [openNew.id, openOld.id, doneNew.id, doneOld.id])
        #expect(tile?.members.map(\.reason) == ["1 open", "2 open", "Done", "Done"])
    }

    @Test("Links exclude X posts; X posts and Photos have their own tiles")
    func linksExcludeXPosts() {
        let plainLink = Self.root(attachments: [Self.link])
        let post = Self.root(attachments: [Self.xPost])
        let photo = Self.root(attachments: [Self.image])

        let tiles = Self.tiles([plainLink, post, photo])

        #expect(Self.tile("links", in: tiles)?.entryIds == [plainLink.id])
        #expect(Self.tile("xPosts", in: tiles)?.entryIds == [post.id])
        #expect(Self.tile("photos", in: tiles)?.entryIds == [photo.id])
    }

    // MARK: - Visibility

    @Test("Empty lenses are dropped, and Random needs at least two roots")
    func emptyLensesAndRandomMinimum() {
        let single = Self.tiles([Self.root(created: Self.daysAgo(1))])
        #expect(single.isEmpty)

        let pair = Self.tiles([Self.root(created: Self.daysAgo(1)), Self.root(created: Self.daysAgo(2))])
        #expect(pair.map(\.id) == ["random"])
        #expect(pair.allSatisfy { !$0.members.isEmpty })
    }

    @Test("Tiles keep display order")
    func displayOrder() {
        let entries = [
            Self.root("- [ ] x", created: Self.date(2025, 6, 15), fires: 1, resurfaces: 1, attachments: [Self.link, Self.image]),
            Self.root(created: Self.daysAgo(100), attachments: [Self.xPost])
        ]
        let commented = entries[0]
        let all = entries + (0..<3).map { _ in Self.comment(on: commented, created: Self.daysAgo(400)) }

        #expect(Self.tiles(all).map(\.id) == [
            "random", "onThisDay", "beenAWhile", "fired", "resurfaced",
            "longThreads", "lists", "links", "xPosts", "photos"
        ])
    }

    // MARK: - Random

    @Test("Random never repeats any of its last five picks when there are more than five roots")
    func randomAvoidsLastFivePicks() {
        let candidates = (0..<8).map { _ in UUID() }
        var generator = SystemRandomNumberGenerator()
        var picks: [UUID] = []

        for _ in 0..<500 {
            let pick = SearchLenses.pickRandom(from: candidates, recentPicks: picks, using: &generator)
            #expect(pick != nil)
            #expect(!picks.suffix(5).contains(pick!))
            picks.append(pick!)
        }
    }

    @Test("With few roots Random still never repeats its previous pick")
    func randomWithFewRootsNeverRepeatsImmediately() {
        let candidates = [UUID(), UUID()]
        var generator = SystemRandomNumberGenerator()
        var picks: [UUID] = []

        for _ in 0..<100 {
            let pick = SearchLenses.pickRandom(from: candidates, recentPicks: picks, using: &generator)!
            #expect(pick != picks.last)
            picks.append(pick)
        }
    }

    // MARK: - Colour

    private static func plainTile(_ id: String, fixed: SearchTileColor? = nil) -> SearchTile {
        SearchTile(
            id: id,
            title: id,
            icon: "dices",
            behavior: .list,
            members: [SearchLensMember(entryId: UUID(), reason: "", date: now)],
            fixedColor: fixed
        )
    }

    /// Every v1 tile present: one root carrying most kinds, one X post.
    private static func everyTile() -> [SearchTile] {
        let entries = [
            Self.root("- [ ] x", created: Self.date(2025, 6, 15), fires: 1, resurfaces: 1, attachments: [Self.link, Self.image]),
            Self.root(created: Self.daysAgo(100), attachments: [Self.xPost])
        ]
        let comments = (0..<3).map { _ in Self.comment(on: entries[0], created: Self.daysAgo(400)) }
        return Self.tiles(entries + comments)
    }

    @Test("Each v1 tile has its own fixed colour")
    func fixedColours() {
        let expected: [String: SearchTileColor] = [
            "random": .violet, "onThisDay": .sky, "beenAWhile": .olive,
            "fired": .pink, "resurfaced": .amber, "longThreads": .teal,
            "lists": .green, "links": .azure, "xPosts": .indigo, "photos": .lemon
        ]
        let tiles = Self.everyTile()

        #expect(tiles.count == expected.count)
        for tile in tiles {
            #expect(tile.color == expected[tile.id])
        }
        #expect(Set(tiles.map(\.color)).count == tiles.count)
    }

    @Test("A month ago keeps On this day's colour")
    func monthAgoColour() {
        let tile = Self.tile("onThisDay", in: Self.tiles([Self.root(created: Self.date(2026, 5, 15)), Self.root()]))
        #expect(tile?.title == "A month ago")
        #expect(tile?.color == .sky)
    }

    @Test("Pink and amber appear only on Fired and Resurfaced")
    func reservedColours() {
        #expect(!SearchTileColor.rotation.contains(.pink))
        #expect(!SearchTileColor.rotation.contains(.amber))
        #expect(SearchTileColor.rotation.count == 8)

        for tile in Self.everyTile() {
            switch tile.id {
            case "fired": #expect(tile.color == .pink)
            case "resurfaced": #expect(tile.color == .amber)
            default: #expect(tile.color != .pink && tile.color != .amber)
            }
        }
    }

    @Test("Tiles without a fixed colour never match a neighbour, whichever tiles are hidden")
    func greedyFallbackNeverMatchesNeighbours() {
        // v1's fixed tiles interleaved with unfixed (v2-style) ones, so the
        // fallback has to dodge fixed neighbours as well as its own.
        let full: [SearchTile] = [
            Self.plainTile("random", fixed: .violet), Self.plainTile("g1"),
            Self.plainTile("onThisDay", fixed: .sky), Self.plainTile("g2"),
            Self.plainTile("fired", fixed: .pink), Self.plainTile("g3"),
            Self.plainTile("resurfaced", fixed: .amber), Self.plainTile("g4"),
            Self.plainTile("links", fixed: .azure), Self.plainTile("g5")
        ]

        // Every subset of the ten tiles (order preserved) — 1,024 layouts.
        for mask in 0..<(1 << full.count) {
            let visible = full.indices.filter { mask & (1 << $0) != 0 }.map { full[$0] }
            let coloured = SearchLenses.assignColors(visible)

            for index in coloured.indices {
                if index >= 2 {
                    #expect(coloured[index].color != coloured[index - 2].color)
                }
                if index % 2 == 1 {
                    #expect(coloured[index].color != coloured[index - 1].color)
                }
                if let fixed = coloured[index].fixedColor {
                    #expect(coloured[index].color == fixed)
                } else {
                    #expect(SearchTileColor.rotation.contains(coloured[index].color))
                }
            }
        }
    }

    @Test("All-unfixed rows never match a neighbour")
    func greedyFallbackAlone() {
        for count in 1...12 {
            let coloured = SearchLenses.assignColors((0..<count).map { Self.plainTile("g\($0)") })
            for index in coloured.indices {
                if index >= 2 { #expect(coloured[index].color != coloured[index - 2].color) }
                if index % 2 == 1 { #expect(coloured[index].color != coloured[index - 1].color) }
            }
        }
    }
}
