//
//  MarkupEditingTests.swift
//  kebabTests
//
//  The full-screen editor's formatting operations, as the pure functions they
//  are. States are written with `|` for the caret and `«»` around a selection,
//  so each test reads as before → after.
//

import Foundation
import Testing
@testable import kebab

struct MarkupEditingTests {

    private func state(_ marked: String) -> EditState {
        let ns = marked as NSString
        let caret = ns.range(of: "|")
        if caret.location != NSNotFound {
            return EditState(
                text: ns.replacingCharacters(in: caret, with: ""),
                selection: NSRange(location: caret.location, length: 0)
            )
        }
        let open = ns.range(of: "«")
        let close = ns.range(of: "»")
        precondition(open.location != NSNotFound && close.location != NSNotFound)
        let text = (marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""))
        return EditState(
            text: text,
            selection: NSRange(location: open.location, length: close.location - open.location - 1)
        )
    }

    private func written(_ state: EditState) -> String {
        let ns = state.text as NSString
        if state.selection.length == 0 {
            return ns.replacingCharacters(in: state.selection, with: "|")
        }
        return ns.replacingCharacters(
            in: state.selection,
            with: "«" + ns.substring(with: state.selection) + "»"
        )
    }

    // MARK: - List buttons

    @Test(arguments: [
        ("hel|lo", MarkupEditing.ListAction.checklist, "- [ ] hel|lo"),
        ("hel|lo", MarkupEditing.ListAction.bullet, "- hel|lo"),
        ("hel|lo", MarkupEditing.ListAction.numbered, "1. hel|lo"),
        ("- [ ] hel|lo", MarkupEditing.ListAction.checklist, "hel|lo"),
        ("- hel|lo", MarkupEditing.ListAction.bullet, "hel|lo"),
        ("1. hel|lo", MarkupEditing.ListAction.numbered, "hel|lo"),
        ("- hel|lo", MarkupEditing.ListAction.numbered, "1. hel|lo"),
        ("1. hel|lo", MarkupEditing.ListAction.checklist, "- [ ] hel|lo"),
        ("- [x] hel|lo", MarkupEditing.ListAction.bullet, "- hel|lo"),
        ("  - hel|lo", MarkupEditing.ListAction.numbered, "  1. hel|lo"),
        ("|", MarkupEditing.ListAction.bullet, "- |")
    ])
    func singleLineListToggle(before: String, action: MarkupEditing.ListAction, after: String) {
        #expect(written(MarkupEditing.toggleList(action, state(before))) == after)
    }

    @Test("A list button sets every selected line, numbered ones counting up")
    func multiLineList() {
        #expect(written(MarkupEditing.toggleList(.numbered, state("«a\nb\nc»")))
            == "«1. a\n2. b\n3. c»")
        #expect(written(MarkupEditing.toggleList(.bullet, state("«a\n1. b\n- [ ] c»")))
            == "«- a\n- b\n- c»")
    }

    @Test("When every selected line already has the kind, the markers come off")
    func multiLineToggleOff() {
        #expect(written(MarkupEditing.toggleList(.bullet, state("«- a\n- b»"))) == "«a\nb»")
    }

    @Test("A mixed selection converts rather than toggles, keeping what already matches")
    func mixedSelectionConverts() {
        #expect(written(MarkupEditing.toggleList(.checklist, state("«- [x] a\nb»")))
            == "«- [x] a\n- [ ] b»")
    }

    @Test("A selection ending at a line's start doesn't touch that line")
    func selectionEndingAtLineStart() {
        #expect(written(MarkupEditing.toggleList(.bullet, state("«a\n»b"))) == "«- a\n»b")
    }

    @Test("Blank lines inside a selection stay blank")
    func blankLinesSkipped() {
        #expect(written(MarkupEditing.toggleList(.bullet, state("«a\n\nb»"))) == "«- a\n\n- b»")
    }

    // MARK: - Indent

    @Test("Indent and outdent move list lines, clamped to levels 0–2")
    func indentClamps() {
        #expect(written(MarkupEditing.indent(state("- a|"))) == "  - a|")
        #expect(written(MarkupEditing.indent(state("  - a|"))) == "    - a|")
        #expect(written(MarkupEditing.indent(state("    - a|"))) == "    - a|")
        #expect(written(MarkupEditing.outdent(state("    - a|"))) == "  - a|")
        #expect(written(MarkupEditing.outdent(state("- a|"))) == "- a|")
    }

    @Test("Indent leaves paragraphs alone")
    func indentIgnoresParagraphs() {
        #expect(written(MarkupEditing.indent(state("a|"))) == "a|")
        #expect(written(MarkupEditing.indent(state("«a\n- b»"))) == "«a\n  - b»")
    }

    @Test("A tab indent normalizes to spaces when moved")
    func indentNormalizesTabs() {
        #expect(written(MarkupEditing.indent(state("\t- a|"))) == "    - a|")
    }

    @Test("Indenting a numbered line renumbers both runs; outdenting restores them")
    func indentRenumbers() {
        let indented = MarkupEditing.indent(state("1. a\n2. b|\n3. c"))
        #expect(written(indented) == "1. a\n  1. b|\n2. c")
        #expect(written(MarkupEditing.outdent(indented)) == "1. a\n2. b|\n3. c")
    }

    @Test("A second nested line continues the nested run")
    func indentJoinsRun() {
        #expect(written(MarkupEditing.indent(state("1. a\n  1. b\n2. c|")))
            == "1. a\n  1. b\n  2. c|")
    }

    // MARK: - Return

    @Test(arguments: [
        ("- a|", "- a\n- |"),
        ("- [x] a|", "- [x] a\n- [ ] |"),
        ("1. a|", "1. a\n2. |"),
        ("  - a|", "  - a\n  - |"),
        ("    1. a|", "    1. a\n    2. |"),
        ("* a|", "* a\n- |"),
        ("- a|b", "- a\n- |b")
    ])
    func returnContinues(before: String, after: String) {
        #expect(MarkupEditing.insertReturn(state(before)).map(written) == after)
    }

    @Test("Return renumbers the rest of the run")
    func returnRenumbers() {
        #expect(MarkupEditing.insertReturn(state("1. a|\n2. b\n3. c")).map(written)
            == "1. a\n2. |\n3. b\n4. c")
    }

    @Test("Return on an empty item outdents, then ends the list")
    func returnOnEmptyItem() {
        #expect(MarkupEditing.insertReturn(state("    - |")).map(written) == "  - |")
        #expect(MarkupEditing.insertReturn(state("  - |")).map(written) == "- |")
        #expect(MarkupEditing.insertReturn(state("- |")).map(written) == "|")
        #expect(MarkupEditing.insertReturn(state("- a\n- [ ] |")).map(written) == "- a\n|")
        #expect(MarkupEditing.insertReturn(state("1. a\n2. |")).map(written) == "1. a\n|")
    }

    @Test("Return on a plain line, or inside a marker, is an ordinary newline")
    func returnFallsThrough() {
        #expect(MarkupEditing.insertReturn(state("plain|")) == nil)
        #expect(MarkupEditing.insertReturn(state("-| a")) == nil)
    }

    @Test("Return replaces a selection, like any typing")
    func returnOverSelection() {
        #expect(MarkupEditing.insertReturn(state("- a«xyz»b")).map(written) == "- a\n- |b")
    }

    // MARK: - Backspace

    @Test("Backspace right after a marker turns the line into plain text")
    func backspaceRemovesMarker() {
        #expect(MarkupEditing.backspace(state("- |a")).map(written) == "|a")
        #expect(MarkupEditing.backspace(state("    - [x] |a")).map(written) == "|a")
        #expect(MarkupEditing.backspace(state("x\n1. |a")).map(written) == "x\n|a")
    }

    @Test("Backspace anywhere else is normal")
    func backspaceElsewhere() {
        #expect(MarkupEditing.backspace(state("- a|")) == nil)
        #expect(MarkupEditing.backspace(state("|- a")) == nil)
        #expect(MarkupEditing.backspace(state("plain|")) == nil)
        #expect(MarkupEditing.backspace(state("«- »a")) == nil)
    }

    @Test("Removing a numbered line's marker splits the run; the rest keeps its numbers")
    func backspaceSplitsRun() {
        #expect(MarkupEditing.backspace(state("1. a\n2. |b\n3. c")).map(written) == "1. a\n|b\n3. c")
    }

    // MARK: - Renumbering

    @Test("Renumbering counts from the run's first number and keeps the caret in place")
    func renumbering() {
        #expect(written(MarkupEditing.renumbered(state("3. a\n3. b|\n3. c"))) == "3. a\n4. b|\n5. c")
        #expect(written(MarkupEditing.renumbered(state("1) a\n1) b|"))) == "1) a\n2) b|")
    }

    @Test("Renumbering across a width change moves the caret with its text")
    func renumberingWidthChange() {
        let lines = (0..<10).map { _ in "1. x" }.joined(separator: "\n") + "|"
        let result = written(MarkupEditing.renumbered(state(lines)))
        #expect(result.hasSuffix("10. x|"))
    }

    @Test("Text that already counts correctly is untouched")
    func renumberingNoOp() {
        let before = state("1. a\n2. b|\n\n1. c")
        #expect(MarkupEditing.renumbered(before) == before)
    }

    // MARK: - Inline: selection

    @Test(arguments: [
        ("a «word» b", MarkupEditing.InlineAction.bold, "a **«word»** b"),
        ("a «word» b", MarkupEditing.InlineAction.italic, "a *«word»* b"),
        ("a «word» b", MarkupEditing.InlineAction.strikethrough, "a ~~«word»~~ b"),
        ("a **«word»** b", MarkupEditing.InlineAction.bold, "a «word» b"),
        ("a *«word»* b", MarkupEditing.InlineAction.italic, "a «word» b"),
        ("a ~~«word»~~ b", MarkupEditing.InlineAction.strikethrough, "a «word» b"),
        ("a «**word**» b", MarkupEditing.InlineAction.bold, "a «word» b"),
        ("a «~~word~~» b", MarkupEditing.InlineAction.strikethrough, "a «word» b"),
        ("a **«word»** b", MarkupEditing.InlineAction.italic, "a ***«word»*** b"),
        ("a *«word»* b", MarkupEditing.InlineAction.bold, "a ***«word»*** b"),
        ("a ***«word»*** b", MarkupEditing.InlineAction.bold, "a *«word»* b"),
        ("a ***«word»*** b", MarkupEditing.InlineAction.italic, "a **«word»** b")
    ])
    func inlineSelection(before: String, action: MarkupEditing.InlineAction, after: String) {
        #expect(written(MarkupEditing.toggleInline(action, state(before))) == after)
    }

    @Test("Selected outer spaces stay outside the markers")
    func inlineTrimsSpaces() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("a« word »b"))) == "a **«word»** b")
    }

    @Test("A multi-line selection wraps each line's non-empty part")
    func inlineMultiLine() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("«one\n\ntwo»")))
            == "**«one**\n\n**two»**")
    }

    @Test("Wrapping leaves list markers outside")
    func inlineSkipsListMarkers() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("«- one\n- two»")))
            == "- **«one**\n- **two»**")
    }

    @Test("A wrapped selection really does parse as styled")
    func inlineWrapParses() {
        let result = MarkupEditing.toggleInline(.italic, state("a «word» b"))
        #expect(Markup.inline(result.text).spans.map(\.style) == [.italic])
    }

    // MARK: - Inline: caret

    @Test("With no selection a press inserts a pair with the caret between")
    func inlineInsertsPair() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("a |"))) == "a **|**")
        #expect(written(MarkupEditing.toggleInline(.italic, state("|"))) == "*|*")
        #expect(written(MarkupEditing.toggleInline(.strikethrough, state("- |"))) == "- ~~|~~")
    }

    @Test("Right after a letter or digit a press adds a space first, so the pair renders")
    func inlineAfterWord() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("line|"))) == "line **|**")
        #expect(written(MarkupEditing.toggleInline(.italic, state("line|"))) == "line *|*")
        #expect(written(MarkupEditing.toggleInline(.strikethrough, state("line|"))) == "line ~~|~~")
        #expect(written(MarkupEditing.toggleInline(.bold, state("route 66|"))) == "route 66 **|**")
        #expect(written(MarkupEditing.toggleInline(.italic, state("- café|"))) == "- café *|*")

        let typed = MarkupEditing.toggleInline(.italic, state("line|")).text
            .replacingOccurrences(of: "**", with: "*x*")
        #expect(Markup.inline(typed).spans.contains { $0.style.contains(.italic) })
    }

    @Test("After punctuation, or with a selection, nothing extra goes in")
    func inlineAfterWordUnchanged() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("(|"))) == "(**|**")
        #expect(written(MarkupEditing.toggleInline(.bold, state("- |"))) == "- **|**")
        #expect(written(MarkupEditing.toggleInline(.bold, state("line«word»"))) == "line**«word»**")
    }

    @Test("Inside the style a press steps out past the closing marker")
    func inlineStepsOut() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("**wo|rd** x"))) == "**word**| x")
        #expect(written(MarkupEditing.toggleInline(.bold, state("**word|** x"))) == "**word**| x")
        #expect(written(MarkupEditing.toggleInline(.italic, state("*word|*"))) == "*word*|")
        #expect(written(MarkupEditing.toggleInline(.bold, state("- **wo|rd**"))) == "- **word**|")
    }

    @Test("Pressing again on an empty pair takes it back out")
    func inlineRemovesEmptyPair() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("a **|**"))) == "a |")
        #expect(written(MarkupEditing.toggleInline(.strikethrough, state("~~|~~"))) == "|")
    }

    @Test("A caret in a list marker inserts in the content, never the marker")
    func inlineCaretInMarker() {
        #expect(written(MarkupEditing.toggleInline(.bold, state("-| a"))) == "- **|**a")
    }

    // MARK: - Checkboxes

    @Test("Toggling a checkbox flips it and keeps the selection")
    func checkboxToggle() {
        let before = state("x|\n  - [ ] y")
        #expect(written(MarkupEditing.toggleCheckbox(lineIndex: 1, before)) == "x|\n  - [x] y")
    }

    @Test("Only offsets on the brackets count as the checkbox")
    func checkboxHit() {
        let text = "x\n  - [ ] y"
        #expect(MarkupEditing.checkboxLine(at: 6, in: text)?.lineIndex == 1)
        #expect(MarkupEditing.checkboxLine(at: 6, in: text)?.range == NSRange(location: 6, length: 3))
        #expect(MarkupEditing.checkboxLine(at: 8, in: text)?.lineIndex == 1)
        #expect(MarkupEditing.checkboxLine(at: 10, in: text) == nil)
        #expect(MarkupEditing.checkboxLine(at: 0, in: text) == nil)
    }

    // MARK: - Active state

    @Test("Active state follows the caret's line and inline style")
    func activeFormats() {
        let bullet = MarkupEditing.activeFormats(state("- a|"))
        #expect(bullet.bullet && !bullet.numbered && !bullet.checklist && bullet.canIndent)

        let plain = MarkupEditing.activeFormats(state("a|"))
        #expect(!plain.bullet && !plain.canIndent)

        let bold = MarkupEditing.activeFormats(state("**a|b** c"))
        #expect(bold.bold && !bold.italic)

        #expect(!MarkupEditing.activeFormats(state("**ab**| c")).bold)
        #expect(MarkupEditing.activeFormats(state("***a|b***")).italic)
        #expect(MarkupEditing.activeFormats(state("~~«ab»~~")).strikethrough)
        #expect(MarkupEditing.activeFormats(state("«- a\n- b»")).bullet)
        #expect(!MarkupEditing.activeFormats(state("«- a\nb»")).bullet)
    }

    // MARK: - Applying

    @Test("Any change reduces to one replacement that reproduces it")
    func replacementRoundTrip() {
        let cases = [
            ("abc", "abXc"), ("abc", "ac"), ("abc", "xyz"), ("", "a"), ("a", ""),
            ("aaa", "aaaa"), ("😀a", "😁a"), ("a😀", "a😁"), ("1. a\n2. b", "1. a\n  1. b")
        ]
        for (old, new) in cases {
            let edit = try! #require(MarkupEditing.replacement(from: old, to: new))
            #expect((old as NSString).replacingCharacters(in: edit.range, with: edit.text) == new)
        }
        #expect(MarkupEditing.replacement(from: "same", to: "same") == nil)
    }

    @Test("A replacement never splits an emoji")
    func replacementKeepsSurrogates() {
        let edit = try! #require(MarkupEditing.replacement(from: "😀", to: "😁"))
        #expect(edit.range == NSRange(location: 0, length: 2))
        #expect(edit.text == "😁")
    }
}
