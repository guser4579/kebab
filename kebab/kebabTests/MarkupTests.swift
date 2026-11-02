//
//  MarkupTests.swift
//  kebabTests
//
//  The one reading of formatted thoughts. Above all these tests protect
//  existing text: anything that isn't deliberately markup must render exactly
//  as typed, and a masked hidden body must never read as markup at all.
//

import Foundation
import Testing
@testable import kebab

struct MarkupTests {

    // MARK: - Blocks

    @Test(arguments: [
        ("- [ ] a", Markup.ListKind.checklist(checked: false)),
        ("- [x] a", Markup.ListKind.checklist(checked: true)),
        ("- [X] a", Markup.ListKind.checklist(checked: true)),
        ("- a", Markup.ListKind.bullet),
        ("* a", Markup.ListKind.bullet),
        ("• a", Markup.ListKind.bullet),
        ("1. a", Markup.ListKind.numbered(1)),
        ("12) a", Markup.ListKind.numbered(12)),
        ("123. a", Markup.ListKind.numbered(123))
    ])
    func listMarkers(line: String, kind: Markup.ListKind) {
        let parsed = Markup.parseLine(line)
        #expect(parsed.kind == kind)
        #expect(parsed.content == "a")
        #expect(parsed.level == 0)
    }

    @Test(arguments: ["plain", "-nope", "1.nope", "1234. four digits", "a. letter", "-", "", "   ", "*bold*", "**bold**"])
    func paragraphs(line: String) {
        let parsed = Markup.parseLine(line)
        #expect(parsed.kind == nil)
        #expect(parsed.content == line)
        #expect(parsed.prefixLength == 0)
    }

    @Test("Indent is two spaces or one tab a level, clamped to level 2")
    func indentLevels() {
        #expect(Markup.parseLine("  - a").level == 1)
        #expect(Markup.parseLine("    - a").level == 2)
        #expect(Markup.parseLine("          - a").level == 2)
        #expect(Markup.parseLine("\t- a").level == 1)
        #expect(Markup.parseLine("\t\t1. a").level == 2)
        #expect(Markup.parseLine(" - a").level == 0)
        #expect(Markup.parseLine("    - a").prefixLength == 6)
        #expect(Markup.parseLine("    - a").indentLength == 4)
    }

    @Test("Indent means nothing on a paragraph")
    func indentedParagraph() {
        let parsed = Markup.parseLine("    text")
        #expect(parsed.kind == nil)
        #expect(parsed.level == 0)
        #expect(parsed.content == "    text")
    }

    @Test("Numbered runs count up from their first number")
    func numberingRuns() {
        #expect(Markup.displayNumbers(for: ["1. a", "1. b", "1. c"]) == [0: 1, 1: 2, 2: 3])
        #expect(Markup.displayNumbers(for: ["5. a", "9. b"]) == [0: 5, 1: 6])
    }

    @Test("A paragraph, a blank line, or another kind ends a run; deeper lines don't")
    func numberingRunBoundaries() {
        #expect(Markup.displayNumbers(for: ["1. a", "text", "1. b"]) == [0: 1, 2: 1])
        #expect(Markup.displayNumbers(for: ["1. a", "", "1. b"]) == [0: 1, 2: 1])
        #expect(Markup.displayNumbers(for: ["1. a", "- b", "1. c"]) == [0: 1, 2: 1])
        #expect(Markup.displayNumbers(for: ["1. a", "  1. b", "  1. c", "1. d"]) == [0: 1, 1: 1, 2: 2, 3: 2])
        #expect(Markup.displayNumbers(for: ["1. a", "  - b", "1. c"]) == [0: 1, 2: 2])
    }

    @Test("Consecutive plain lines stay one paragraph, and line indexes stay content indexes")
    func documentBlocks() {
        let document = Markup.document("one\ntwo\n- [ ] item\n\n  3. num")
        #expect(document.hasLists)
        #expect(document.blocks == [
            .paragraph(id: 0, text: "one\ntwo"),
            .item(id: 1, lineIndex: 2, level: 0, kind: .checklist(checked: false), content: "item"),
            .item(id: 2, lineIndex: 4, level: 1, kind: .numbered(3), content: "num")
        ])
    }

    @Test("A thought with no markup is plain")
    func plainDocument() {
        let content = "just a thought\n\nwith a second paragraph, 5*3*2 and file_name"
        let document = Markup.document(content)
        #expect(document.isPlain)
        #expect(document.blocks == [.paragraph(id: 0, text: content)])
    }

    // MARK: - Inline

    private func spans(_ line: String) -> [Markup.InlineStyle] {
        Markup.inline(line).spans.map(\.style)
    }

    @Test(arguments: [
        "5*3*2", "a * b", "**", "*", "***", "****", "~~", "~", "file_name",
        "un*styled*word", "un**styled**word", "* a *", "** a **", "~~ a ~~",
        "*unmatched", "unmatched*", "**unmatched", "unmatched**", "~~unmatched",
        "*a**", "2*3 and 4*5", "~one~"
    ])
    func rendersAsTyped(line: String) {
        let layout = Markup.inline(line)
        #expect(layout.spans.isEmpty)
        #expect(layout.plainText == line)
    }

    @Test("Each style parses and drops its markers")
    func styles() {
        #expect(spans("**a**") == [.bold])
        #expect(spans("*a*") == [.italic])
        #expect(spans("***a***") == [[.bold, .italic]])
        #expect(spans("~~a~~") == [.strikethrough])
        #expect(Markup.inline("x **a b** y").plainText == "x a b y")
        #expect(Markup.inline("x **a b** y").runs.map(\.style) == [[], .bold, []])
    }

    @Test("Markers may sit against punctuation")
    func punctuationFlanking() {
        #expect(spans("(**a**).") == [.bold])
        #expect(spans("\"*a*\"") == [.italic])
        #expect(spans("~~a~~!") == [.strikethrough])
    }

    @Test("Styles nest, including a shared closing run")
    func nesting() {
        let layout = Markup.inline("**bold *it***")
        #expect(layout.plainText == "bold it")
        #expect(layout.runs.map(\.style) == [.bold, [.bold, .italic]])
        #expect(Markup.inline("~~**a**~~").runs.map(\.style) == [[.bold, .strikethrough]])
    }

    @Test("Styles never cross a newline")
    func noStyleAcrossNewline() {
        #expect(Markup.inline("**a\nb**").spans.isEmpty)
        #expect(Markup.document("**a\nb**").hasInlineStyles == false)
    }

    @Test("Offsets are UTF-16, so emoji can't throw them off")
    func utf16Offsets() {
        let layout = Markup.inline("😀 **a**")
        let span = layout.spans[0]
        #expect(span.open == 3..<5)
        #expect(span.close == 6..<8)
        #expect(layout.runs.last?.range == 5..<6)
    }

    @Test("Styles apply inside list items")
    func stylesInsideItems() {
        let line = Markup.parseLine("- **a**")
        #expect(Markup.inline(line.content).runs.map(\.style) == [.bold])
    }

    // MARK: - Plain text

    @Test("plainText strips markers and normalizes list markers")
    func plainText() {
        let content = "**Bold** and *it*\n- one\n  * two\n3. x\n3. y\n- [ ] open\n- [x] ~~done~~"
        #expect(Markup.plainText(content) == "Bold and it\n• one\n• two\n3. x\n4. y\n☐ open\n☑ done")
    }

    @Test("plainText leaves unstyled text alone")
    func plainTextUntouched() {
        let content = "5*3*2 is 30\n\n    indented file_name"
        #expect(Markup.plainText(content) == content)
    }

    // MARK: - Hidden content

    private static func entry(_ content: String, hidden: Bool) -> Entry {
        Entry(
            id: UUID(), user_id: UUID(), parent_id: nil, root_id: nil, depth: 0,
            content: content, created_at: Date(), pinned_at: nil, isContentHidden: hidden,
            comment_count: nil, resurface_count: 0, fire_count: 0, attachments: nil,
            collection_id: nil, collection_name: nil, collection_parent_id: nil,
            collection_parent_name: nil
        )
    }

    @Test("A hidden entry never reads as markup, even though its mask would parse")
    func hiddenNeverParsed() {
        let content = "- secret\n**bold**"
        #expect(Markup.document(of: Self.entry(content, hidden: true)) == nil)
        #expect(Markup.document(of: Self.entry(content, hidden: false))?.hasLists == true)
    }

    @Test("A hidden entry's preview is only asterisks")
    func hiddenPreviewMasked() {
        let preview = SearchDisplay.previewText(for: Self.entry("- secret **x**", hidden: true))
        #expect(preview == "* ****** *****")
    }

    @Test("A visible entry's preview is clean")
    func previewClean() {
        #expect(SearchDisplay.previewText(for: Self.entry("- **x** ~~y~~", hidden: false)) == "• x y")
    }

    // MARK: - Checklist compatibility

    @Test("Unindented content toggles exactly as before")
    func checklistToggleUnindented() {
        let content = "intro\n- [ ] a\n- [x] b"
        #expect(Checklist.toggling(content, lineIndex: 1) == "intro\n- [x] a\n- [x] b")
        #expect(Checklist.toggling(content, lineIndex: 2) == "intro\n- [ ] a\n- [ ] b")
        #expect(Checklist.toggling(content, lineIndex: 0) == content)
        #expect(Checklist.toggling(content, lineIndex: 9) == content)
    }

    @Test("Indented checklist lines toggle the right line, keeping indent")
    func checklistToggleIndented() {
        let content = "- [ ] a\n  - [ ] b\n    - [X] c"
        #expect(Checklist.toggling(content, lineIndex: 1) == "- [ ] a\n  - [x] b\n    - [X] c")
        #expect(Checklist.toggling(content, lineIndex: 2) == "- [ ] a\n  - [ ] b\n    - [ ] c")
    }

    @Test("Checklist helpers see every indent")
    func checklistHelpersIndented() {
        #expect(Checklist.hasChecklist("  - [ ] a"))
        #expect(!Checklist.hasChecklist("- a\n1. b"))
        #expect(Checklist.openItemCount("- [ ] a\n  - [ ] b\n- [x] c") == 2)
    }

    // MARK: - Search

    private static func searched(_ content: String, query: String) async -> SearchResultItem? {
        let engine = SearchEngine()
        await engine.update(snapshot: SearchCorpusSnapshot(
            entries: [entry(content, hidden: false)],
            membership: [:],
            collectionNames: [:]
        ))
        return await engine.search(rawQuery: query, recentActivityRoots: []).results.first
    }

    private func highlighted(_ snippet: SearchSnippet) -> [String] {
        let chars = Array(snippet.text)
        return snippet.highlights.map { String(chars[$0]) }
    }

    @Test("A formatted word is found, and its highlight lands on it")
    func searchFormattedWord() async throws {
        let item = try #require(await Self.searched("before **pineapple** after", query: "pineapple"))
        #expect(item.snippet.text == "before pineapple after")
        #expect(highlighted(item.snippet) == ["pineapple"])
    }

    @Test("Highlights stay right after a stripped list marker")
    func searchInsideList() async throws {
        let item = try #require(await Self.searched("- [ ] first\n- [x] ~~second~~ *third*", query: "third"))
        #expect(item.snippet.text == "☐ first\n☑ second third")
        #expect(highlighted(item.snippet) == ["third"])
    }

    @Test("A phrase spanning formatting still matches as a phrase")
    func searchPhraseAcrossMarkers() async throws {
        let item = try #require(await Self.searched("say **hello** there", query: "hello there"))
        #expect(item.snippet.text == "say hello there")
        #expect(highlighted(item.snippet) == ["hello there"])
    }

    @Test("Highlights survive windowing a long formatted body")
    func searchLongBody() async throws {
        let padding = (0..<40).map { "- filler line \($0)" }.joined(separator: "\n")
        let item = try #require(await Self.searched(padding + "\n- **needle** here", query: "needle"))
        #expect(highlighted(item.snippet) == ["needle"])
        #expect(!item.snippet.text.contains("**"))
    }
}
