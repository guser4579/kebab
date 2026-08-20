import Foundation

/// On-device retrieval engine. Owns a derived index over the corpus snapshot
/// and evaluates queries into `SearchResultSet`s — literal-first matching with
/// conservative typo tolerance, thought-cluster grouping, snippet
/// construction, and ranking (match quality → personal engagement → recency).
///
/// An actor so query evaluation and index builds never touch the main thread;
/// at corpus scale (hundreds–thousands of short notes) a full evaluation is
/// well under a frame.
actor SearchEngine {

    // MARK: - Index

    private struct Token {
        let text: String        // folded
        let start: Int          // character offset into the source string
        let end: Int
    }

    private struct Doc {
        let entry: Entry
        let rootId: UUID
        let contentTokens: [Token]
        /// Title + domain + URL of the link attachment, tokenized. Offsets are
        /// into `attachmentTitle` only while they fall inside it.
        let attachmentTokens: [Token]
        let attachmentTitle: String
        let collectionNameFolded: String?
    }

    private var docs: [Doc] = []
    private var entryById: [UUID: Entry] = [:]
    private var childrenByParent: [UUID: [UUID]] = [:]
    private var descendantCount: [UUID: Int] = [:]
    private var lastActivityByRoot: [UUID: Date] = [:]
    private var membership: [UUID: UUID] = [:]
    private var collectionNames: [UUID: String] = [:]

    // MARK: - Index build

    func update(snapshot: SearchCorpusSnapshot) {
        membership = snapshot.membership
        collectionNames = snapshot.collectionNames

        entryById = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        childrenByParent = [:]
        for entry in snapshot.entries {
            if let parent = entry.parent_id {
                childrenByParent[parent, default: []].append(entry.id)
            }
        }

        descendantCount = [:]
        lastActivityByRoot = [:]
        for entry in snapshot.entries {
            let rootId = entry.root_id ?? entry.id
            if entry.parent_id != nil {
                descendantCount[rootId, default: 0] += 1
            }
            let existing = lastActivityByRoot[rootId] ?? .distantPast
            if entry.created_at > existing {
                lastActivityByRoot[rootId] = entry.created_at
            }
        }

        docs = snapshot.entries.compactMap { entry in
            // Hidden content is deliberately concealed — it never matches, and
            // deleted/inactive content never reaches the corpus at all.
            guard !entry.isContentHidden else { return nil }
            let rootId = entry.root_id ?? entry.id
            let collectionId = membership[rootId]
            let collectionName = collectionId.flatMap { collectionNames[$0] }

            var attachmentTitle = ""
            var attachmentText = ""
            if let link = entry.linkAttachment {
                attachmentTitle = link.title ?? ""
                let domain = URL(string: link.url)?.host ?? ""
                attachmentText = attachmentTitle + "\n" + domain + "\n" + link.url
                // Imported source text is searchable AS source text: it joins
                // the attachment index, never `contentTokens`. A hit on a
                // saved X post and a hit on something the user wrote stay
                // distinguishable in both the model and the ranking (the
                // attachment pass is already weighted at 0.9).
                //
                // Appended after the title on purpose — highlight offsets are
                // only usable inside the leading title span, so this extends
                // what matches without disturbing what highlights.
                if let post = link.xPostSource {
                    attachmentText += "\n" + post.searchableText
                }
            }

            return Doc(
                entry: entry,
                rootId: rootId,
                contentTokens: Self.tokenize(entry.content),
                attachmentTokens: Self.tokenize(attachmentText),
                attachmentTitle: attachmentTitle,
                collectionNameFolded: collectionName.map(Self.fold)
            )
        }
    }

    // MARK: - Query evaluation

    func search(rawQuery: String, recentActivityRoots: Set<UUID>) -> SearchResultSet {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let plan = Self.interpret(query: trimmed)

        struct DocHit {
            let docIndex: Int
            let score: Double
            let highlights: [Range<Int>]
            let attachmentHighlights: [Range<Int>]
            let matchedInContent: Bool
        }

        var confirmed: [DocHit] = []
        var nearMisses: [DocHit] = []

        for (index, doc) in docs.enumerated() {
            if let window = plan.window,
               !window.contains(doc.entry.created_at) { continue }
            switch plan.typeFilter {
            case .link where doc.entry.linkAttachment == nil: continue
            case .comment where doc.entry.parent_id == nil: continue
            default: break
            }

            // Phrase pass: the whole query appearing verbatim dominates.
            if plan.terms.count >= 2,
               let phraseRange = doc.entry.content.range(
                   of: trimmed,
                   options: [.caseInsensitive, .diacriticInsensitive]
               ) {
                let content = doc.entry.content
                let start = content.distance(from: content.startIndex, to: phraseRange.lowerBound)
                let end = content.distance(from: content.startIndex, to: phraseRange.upperBound)
                var score = 1000.0
                if start == 0 {
                    score += 200
                } else {
                    let before = content[content.index(phraseRange.lowerBound, offsetBy: -1)]
                    if !before.isLetter && !before.isNumber { score += 200 }
                }
                confirmed.append(DocHit(
                    docIndex: index, score: score,
                    highlights: [start..<end], attachmentHighlights: [],
                    matchedInContent: true
                ))
                continue
            }

            // Token pass: every significant term must land somewhere.
            var termScores: [Double] = []
            var highlights: [Range<Int>] = []
            var attachmentHighlights: [Range<Int>] = []
            var unmatchedTerms = 0
            var matchedInContent = false

            for term in plan.terms {
                var best = 0.0
                var bestRange: Range<Int>?
                var bestInAttachment = false

                for token in doc.contentTokens {
                    let s = Self.tokenScore(term: term, token: token.text)
                    if s > best {
                        best = s
                        bestRange = token.start..<token.end
                        bestInAttachment = false
                    }
                    if best >= 100 { break }
                }
                if best < 100 {
                    for token in doc.attachmentTokens {
                        let s = Self.tokenScore(term: term, token: token.text) * 0.9
                        if s > best {
                            best = s
                            // Only offsets inside the title are usable for
                            // highlighting (the snippet shows the title).
                            bestRange = token.end <= doc.attachmentTitle.count
                                ? token.start..<token.end : nil
                            bestInAttachment = true
                        }
                    }
                }
                if best == 0, let name = doc.collectionNameFolded {
                    // Collection name as a contextual relevance signal.
                    if name.contains(term) { best = 50 }
                }

                if best == 0 {
                    unmatchedTerms += 1
                } else {
                    termScores.append(best)
                    if let range = bestRange {
                        if bestInAttachment {
                            attachmentHighlights.append(range)
                        } else {
                            highlights.append(range)
                            matchedInContent = true
                        }
                    }
                }
            }

            guard !termScores.isEmpty else { continue }
            let average = termScores.reduce(0, +) / Double(plan.terms.count)

            if unmatchedTerms == 0 {
                confirmed.append(DocHit(
                    docIndex: index, score: average,
                    highlights: highlights.sorted { $0.lowerBound < $1.lowerBound },
                    attachmentHighlights: attachmentHighlights,
                    matchedInContent: matchedInContent
                ))
            } else if unmatchedTerms == 1 && plan.terms.count >= 2 {
                nearMisses.append(DocHit(
                    docIndex: index, score: average,
                    highlights: highlights.sorted { $0.lowerBound < $1.lowerBound },
                    attachmentHighlights: attachmentHighlights,
                    matchedInContent: matchedInContent
                ))
            }
        }

        // Every matched object is its own independently ranked result.
        // Thread signals (thread size, root engagement, recency) still feed
        // ranking; they just never become visible structure.
        func makeItem(_ hit: DocHit) -> SearchResultItem {
            let doc = docs[hit.docIndex]
            let snippet: SearchSnippet
            if hit.matchedInContent || !doc.entry.content.isEmpty {
                snippet = Self.makeSnippet(content: doc.entry.content, highlights: hit.highlights)
            } else {
                // Link-only entry matched through its attachment.
                snippet = SearchSnippet(
                    text: doc.attachmentTitle.isEmpty
                        ? (URL(string: doc.entry.linkAttachment?.url ?? "")?.host ?? doc.entry.linkAttachment?.url ?? "")
                        : doc.attachmentTitle,
                    highlights: doc.attachmentTitle.isEmpty ? [] : hit.attachmentHighlights
                )
            }

            let rootId = doc.rootId
            var engagement = 0.0
            engagement += min(12, 2 * log2(Double(1 + (descendantCount[rootId] ?? 0))))
            if let root = entryById[rootId] {
                engagement += min(9, Double(root.resurface_count) * 3)
                engagement += min(6, Double(root.fire_count) * 2)
            }
            if recentActivityRoots.contains(rootId) { engagement += 15 }
            let age = Date().timeIntervalSince(lastActivityByRoot[rootId] ?? doc.entry.created_at)
            engagement += 10 * exp(-age / (86_400 * 45))   // recency: tie-break scale only

            let collectionId = membership[rootId]
            return SearchResultItem(
                entry: doc.entry,
                snippet: snippet,
                rootId: rootId,
                collectionId: collectionId,
                collectionName: collectionId.flatMap { collectionNames[$0] },
                score: hit.score * 10 + engagement
            )
        }

        func rank(_ items: [SearchResultItem]) -> [SearchResultItem] {
            items.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.entry.created_at != $1.entry.created_at {
                    return $0.entry.created_at > $1.entry.created_at
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        }

        let results = rank(confirmed.map(makeItem))
        let confirmedIds = Set(results.map(\.id))

        // Near-miss tier: only high-confidence leftovers, never interleaved.
        let possible = rank(nearMisses.map(makeItem))
            .filter { !confirmedIds.contains($0.id) && $0.score >= 550 }
            .prefix(3)

        var facetCounts: [UUID: Int] = [:]
        for item in results {
            if let id = item.collectionId {
                facetCounts[id, default: 0] += 1
            }
        }
        let facets = facetCounts
            .compactMap { id, count -> SearchCollectionFacet? in
                guard let name = collectionNames[id] else { return nil }
                return SearchCollectionFacet(collectionId: id, name: name, clusterCount: count)
            }
            .sorted {
                if $0.clusterCount != $1.clusterCount { return $0.clusterCount > $1.clusterCount }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        return SearchResultSet(
            query: trimmed,
            results: results,
            possible: Array(possible),
            facets: facets
        )
    }

    // MARK: - Interpretation (constrained, high-confidence only)

    private enum TypeFilter { case link, comment }

    private struct QueryPlan {
        let terms: [String]
        let typeFilter: TypeFilter?
        let window: DateInterval?
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "i", "my", "me", "of", "in", "on", "at", "to",
        "from", "about", "for", "with", "that", "this", "it", "is", "was",
        "and", "or", "saved", "wrote"
    ]

    private static let monthNames = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5,
        "june": 6, "july": 7, "august": 8, "september": 9, "october": 10,
        "november": 11, "december": 12
    ]

    private static let seasonStartMonth = [
        "spring": 3, "summer": 6, "fall": 9, "autumn": 9, "winter": 12
    ]

    private static func interpret(query: String) -> QueryPlan {
        let allTokens = tokenize(fold(query)).map(\.text)
        let significant = allTokens.filter { !stopwords.contains($0) }
        // Nothing but stopwords: search the words as typed.
        let baseTerms = significant.isEmpty ? allTokens : significant

        var window: DateInterval?
        var typeFilter: TypeFilter?
        var consumed = Set<Int>()

        let calendar = Calendar.current
        let now = Date()

        var i = 0
        while i < baseTerms.count {
            let token = baseTerms[i]
            let next = i + 1 < baseTerms.count ? baseTerms[i + 1] : nil

            if window == nil {
                if token == "yesterday" {
                    let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: now)!)
                    window = DateInterval(start: start, duration: 86_400)
                    consumed.insert(i)
                } else if token == "last", let next {
                    var matched = true
                    switch next {
                    case "week":
                        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
                        window = DateInterval(start: thisWeek.start.addingTimeInterval(-7 * 86_400), end: thisWeek.start)
                    case "month":
                        let thisMonth = calendar.dateInterval(of: .month, for: now)!
                        let prev = calendar.date(byAdding: .month, value: -1, to: thisMonth.start)!
                        window = DateInterval(start: prev, end: thisMonth.start)
                    case "year":
                        let thisYear = calendar.dateInterval(of: .year, for: now)!
                        let prev = calendar.date(byAdding: .year, value: -1, to: thisYear.start)!
                        window = DateInterval(start: prev, end: thisYear.start)
                    default:
                        if let startMonth = seasonStartMonth[next] {
                            window = previousSeason(startMonth: startMonth, calendar: calendar, now: now)
                        } else {
                            matched = false
                        }
                    }
                    if matched {
                        consumed.insert(i)
                        consumed.insert(i + 1)
                        i += 1
                    }
                } else if let month = monthNames[token] {
                    window = mostRecentMonth(month, calendar: calendar, now: now)
                    consumed.insert(i)
                } else if let year = Int(token), (2000...2035).contains(year), token.count == 4 {
                    var comps = DateComponents(); comps.year = year
                    if let start = calendar.date(from: comps) {
                        let end = calendar.date(byAdding: .year, value: 1, to: start)!
                        window = DateInterval(start: start, end: end)
                        consumed.insert(i)
                    }
                }
            }

            if typeFilter == nil {
                if token == "link" || token == "links" {
                    typeFilter = .link
                    consumed.insert(i)
                } else if token == "comment" || token == "comments" {
                    typeFilter = .comment
                    consumed.insert(i)
                }
            }

            i += 1
        }

        let remaining = baseTerms.enumerated()
            .filter { !consumed.contains($0.offset) }
            .map(\.element)

        // High confidence requires terms left to actually search for;
        // otherwise treat every token as a normal word.
        guard !remaining.isEmpty, !consumed.isEmpty else {
            return QueryPlan(terms: baseTerms, typeFilter: nil, window: nil)
        }
        return QueryPlan(terms: remaining, typeFilter: typeFilter, window: window)
    }

    /// The most recent fully-or-partially elapsed occurrence of `month`.
    private static func mostRecentMonth(_ month: Int, calendar: Calendar, now: Date) -> DateInterval? {
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        let year = month <= currentMonth ? currentYear : currentYear - 1
        var comps = DateComponents(); comps.year = year; comps.month = month
        guard let start = calendar.date(from: comps),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// "Last <season>": the most recent completed occurrence of the season.
    private static func previousSeason(startMonth: Int, calendar: Calendar, now: Date) -> DateInterval? {
        let currentYear = calendar.component(.year, from: now)
        for yearOffset in 0...2 {
            var comps = DateComponents()
            comps.year = currentYear - yearOffset
            comps.month = startMonth
            guard let start = calendar.date(from: comps),
                  let end = calendar.date(byAdding: .month, value: 3, to: start) else { continue }
            if end <= now {
                return DateInterval(start: start, end: end)
            }
        }
        return nil
    }

    // MARK: - Matching primitives

    private static func tokenScore(term: String, token: String) -> Double {
        if token == term { return 100 }
        if token.hasPrefix(term) { return 60 }
        // Conservative typo tolerance: one edit, meaningful terms only.
        if term.count >= 5, abs(term.count - token.count) <= 1,
           withinOneEdit(term, token) {
            return 30
        }
        return 0
    }

    /// True when `a` and `b` are within Levenshtein distance 1.
    private static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aChars = Array(a), bChars = Array(b)
        if abs(aChars.count - bChars.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < aChars.count && j < bChars.count {
            if aChars[i] == bChars[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if aChars.count == bChars.count {
                i += 1; j += 1                       // substitution
            } else if aChars.count > bChars.count {
                i += 1                               // deletion from a
            } else {
                j += 1                               // insertion into a
            }
        }
        edits += (aChars.count - i) + (bChars.count - j)
        return edits <= 1
    }

    // MARK: - Text processing

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        var tokens: [Token] = []
        var offset = 0
        var lastIndex = text.startIndex
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { substring, range, _, _ in
            guard let substring else { return }
            // Incremental offset tracking keeps tokenization linear.
            offset += text.distance(from: lastIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            tokens.append(Token(text: fold(substring), start: offset, end: offset + length))
            offset += length
            lastIndex = range.upperBound
        }
        return tokens
    }

    // MARK: - Snippets

    /// Character budget for a snippet window. Vertical truncation beyond this
    /// is the view's lineLimit; the budget just bounds what we hand it.
    private static let snippetBudget = 280

    /// Builds the preview around the strongest matching phrase — never
    /// defaulting to the beginning of a long text — while PRESERVING the
    /// source's line structure. Lists, checklists, and paragraph breaks
    /// survive into the result; windows are cut at line boundaries, and only
    /// a single overlong prose line is character-windowed within itself.
    private static func makeSnippet(content: String, highlights: [Range<Int>]) -> SearchSnippet {
        let chars = Array(content)

        // Short content: show it whole, structure intact.
        guard chars.count > snippetBudget + 40 else {
            return SearchSnippet(text: content, highlights: highlights)
        }

        // Line ranges over the whole content (empty lines included — they
        // are the paragraph spacing we're preserving).
        var lines: [Range<Int>] = []
        var lineStart = 0
        for (index, char) in chars.enumerated() where char.isNewline {
            lines.append(lineStart..<index)
            lineStart = index + 1
        }
        lines.append(lineStart..<chars.count)

        guard let anchor = highlights.first else {
            // No in-content highlight (attachment or collection-signal
            // match): head of the content, line-preserving.
            return lineWindow(chars: chars, lines: lines, around: 0, highlights: highlights)
        }

        let matchLineIndex = lines.firstIndex {
            $0.lowerBound <= anchor.lowerBound && anchor.lowerBound <= $0.upperBound
        } ?? 0

        // A single overlong prose line: window characters within that line.
        if lines[matchLineIndex].count > snippetBudget {
            return characterWindow(
                chars: chars,
                line: lines[matchLineIndex],
                anchor: anchor,
                highlights: highlights
            )
        }

        return lineWindow(chars: chars, lines: lines, around: matchLineIndex, highlights: highlights)
    }

    /// Whole-line window: the match line, at most one line of lead-in above,
    /// then following lines until the budget runs out.
    private static func lineWindow(
        chars: [Character],
        lines: [Range<Int>],
        around matchLineIndex: Int,
        highlights: [Range<Int>]
    ) -> SearchSnippet {
        var startIndex = matchLineIndex
        var used = lines[matchLineIndex].count
        if matchLineIndex > 0, used + lines[matchLineIndex - 1].count + 1 <= snippetBudget {
            startIndex = matchLineIndex - 1
            used += lines[matchLineIndex - 1].count + 1
        }
        var endIndex = matchLineIndex
        while endIndex + 1 < lines.count, used + lines[endIndex + 1].count + 1 <= snippetBudget {
            used += lines[endIndex + 1].count + 1
            endIndex += 1
        }

        let windowStart = lines[startIndex].lowerBound
        let windowEnd = lines[endIndex].upperBound
        var text = String(chars[windowStart..<windowEnd])
        var local = clip(highlights, to: windowStart..<windowEnd, shiftBy: windowStart)

        if startIndex > 0 {
            text = "… " + text
            local = local.map { ($0.lowerBound + 2)..<($0.upperBound + 2) }
        }
        if endIndex < lines.count - 1 {
            text += " …"
        }
        return SearchSnippet(text: text, highlights: local)
    }

    /// Character window inside one overlong line, snapped to word boundaries.
    private static func characterWindow(
        chars: [Character],
        line: Range<Int>,
        anchor: Range<Int>,
        highlights: [Range<Int>]
    ) -> SearchSnippet {
        let windowSize = 160
        var start = max(line.lowerBound, anchor.lowerBound - 50)
        if start > line.lowerBound {
            var probe = start
            let limit = max(line.lowerBound, start - 12)
            while probe > limit, chars[probe - 1] != " " { probe -= 1 }
            start = probe
        }
        var end = min(line.upperBound, start + windowSize)
        if end < line.upperBound {
            var probe = end
            let limit = min(line.upperBound, end + 12)
            while probe < limit, chars[probe] != " " { probe += 1 }
            end = probe
        }

        var text = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
        let leadingTrim = String(chars[start..<end]).prefix { $0 == " " }.count
        let base = start + leadingTrim
        var local = clip(highlights, to: base..<(base + text.count), shiftBy: base)

        if base > 0 {
            text = "… " + text
            local = local.map { ($0.lowerBound + 2)..<($0.upperBound + 2) }
        }
        if end < chars.count {
            text += " …"
        }
        return SearchSnippet(text: text, highlights: local)
    }

    private static func clip(
        _ highlights: [Range<Int>],
        to window: Range<Int>,
        shiftBy offset: Int
    ) -> [Range<Int>] {
        highlights.compactMap { range in
            let lower = max(range.lowerBound, window.lowerBound) - offset
            let upper = min(range.upperBound, window.upperBound) - offset
            guard lower < upper else { return nil }
            return lower..<upper
        }
    }
}
