//
//  MarkupEditing.swift
//  kebab
//
//  Every formatting operation in the full-screen editor, as a pure function
//  of (text, selection). No UIKit: the editor applies the results through its
//  undo-registering path, and the tests run them directly. Offsets are UTF-16,
//  matching NSRange and UITextView.
//

import Foundation

nonisolated struct EditState: Equatable, Sendable {
    var text: String
    var selection: NSRange

    init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }
}

nonisolated enum MarkupEditing {

    enum ListAction: Sendable {
        case checklist, bullet, numbered

        fileprivate func matches(_ kind: Markup.ListKind?) -> Bool {
            switch (self, kind) {
            case (.checklist, .checklist), (.bullet, .bullet), (.numbered, .numbered): return true
            default: return false
            }
        }

        fileprivate var newMarker: String {
            switch self {
            case .checklist: return Checklist.uncheckedMarker
            case .bullet: return "- "
            case .numbered: return "1. "
            }
        }
    }

    enum InlineAction: Sendable {
        case bold, italic, strikethrough

        fileprivate var marker: String {
            switch self {
            case .bold: return "**"
            case .italic: return "*"
            case .strikethrough: return "~~"
            }
        }

        fileprivate var style: Markup.InlineStyle {
            switch self {
            case .bold: return .bold
            case .italic: return .italic
            case .strikethrough: return .strikethrough
            }
        }

        /// Whether `count` adjacent marker characters carry this style. `*`
        /// is shared: two are bold, one is italic, three are both.
        fileprivate func isCarried(byRunOf count: Int) -> Bool {
            switch self {
            case .bold, .strikethrough: return count >= 2
            case .italic: return count == 1 || count == 3
            }
        }
    }

    /// What the formatting bar shows for a selection.
    struct ActiveFormats: Equatable, Sendable {
        var checklist = false
        var bullet = false
        var numbered = false
        var bold = false
        var italic = false
        var strikethrough = false
        /// Indent and Outdent work on list lines only.
        var canIndent = false
    }

    // MARK: - Lines

    private struct LineSpan {
        let index: Int
        let start: Int
        let text: String
        var length: Int { text.utf16.count }
        var end: Int { start + length }
    }

    private static func lineSpans(_ text: String) -> [LineSpan] {
        var spans: [LineSpan] = []
        var start = 0
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let span = LineSpan(index: index, start: start, text: line)
            spans.append(span)
            start = span.end + 1
        }
        return spans
    }

    private static func line(at offset: Int, in spans: [LineSpan]) -> LineSpan {
        spans.last { $0.start <= offset } ?? spans[0]
    }

    /// Lines the selection touches. A selection ending right at a line's start
    /// doesn't touch that line.
    private static func touchedLines(_ state: EditState, _ spans: [LineSpan]) -> [LineSpan] {
        let first = line(at: state.selection.location, in: spans)
        guard state.selection.length > 0 else { return [first] }
        let end = state.selection.location + state.selection.length
        return spans.filter { ($0.index == first.index) || ($0.index > first.index && $0.start < end) }
    }

    /// The characters a prefix rewrite replaces: the list prefix, or a plain
    /// line's own leading whitespace.
    private static func rewritablePrefixLength(_ raw: String, _ parsed: Markup.Line) -> Int {
        if parsed.isList { return parsed.prefixLength }
        return raw.utf16.prefix { $0 == 32 || $0 == 9 }.count
    }

    private static func indentString(_ raw: String, _ parsed: Markup.Line) -> String {
        String(raw.unicodeScalars.prefix(parsed.indentLength))
    }

    private static func markerString(_ raw: String, _ parsed: Markup.Line) -> String {
        String(raw.unicodeScalars.dropFirst(parsed.indentLength).prefix(parsed.prefixLength - parsed.indentLength))
    }

    /// Replaces line prefixes, carrying the selection along: a position in a
    /// line's content keeps its place in that content, and a position inside a
    /// replaced prefix lands right after the new one.
    private static func rewritingPrefixes(_ state: EditState, _ newPrefixes: [Int: String]) -> EditState {
        guard !newPrefixes.isEmpty else { return state }
        let spans = lineSpans(state.text)

        var output: [String] = []
        var edits: [(start: Int, oldLength: Int, newLength: Int)] = []
        for span in spans {
            guard let prefix = newPrefixes[span.index] else {
                output.append(span.text)
                continue
            }
            let oldLength = rewritablePrefixLength(span.text, Markup.parseLine(span.text))
            let rest = String(decoding: Array(span.text.utf16.dropFirst(oldLength)), as: UTF16.self)
            output.append(prefix + rest)
            edits.append((span.start, oldLength, prefix.utf16.count))
        }

        func mapped(_ offset: Int, keepsLineStart: Bool) -> Int {
            var delta = 0
            for edit in edits {
                if offset < edit.start { break }
                if offset == edit.start, keepsLineStart { break }
                if offset < edit.start + edit.oldLength {
                    return edit.start + delta + edit.newLength
                }
                delta += edit.newLength - edit.oldLength
            }
            return offset + delta
        }

        let hasRange = state.selection.length > 0
        let lower = mapped(state.selection.location, keepsLineStart: hasRange)
        let upper = mapped(state.selection.location + state.selection.length, keepsLineStart: true)
        return EditState(
            text: output.joined(separator: "\n"),
            selection: NSRange(location: lower, length: hasRange ? max(0, upper - lower) : 0)
        )
    }

    // MARK: - Renumbering

    /// Rewrites stored numbers so each numbered run counts up from its first
    /// number, keeping stored and displayed numbers the same.
    static func renumbered(_ state: EditState) -> EditState {
        let lines = state.text.components(separatedBy: "\n")
        var newPrefixes: [Int: String] = [:]
        for (index, number) in Markup.displayNumbers(for: lines) {
            let parsed = Markup.parseLine(lines[index])
            guard case .numbered(let stored) = parsed.kind, stored != number else { continue }
            newPrefixes[index] = indentString(lines[index], parsed) + "\(number)"
                + markerString(lines[index], parsed).drop { $0.isNumber }
        }
        return rewritingPrefixes(state, newPrefixes)
    }

    // MARK: - List buttons

    /// Every line the selection touches becomes this kind; if they all already
    /// are, the markers come off. Blank lines inside a selection are left be.
    static func toggleList(_ action: ListAction, _ state: EditState) -> EditState {
        let spans = lineSpans(state.text)
        let touched = touchedLines(state, spans)
        var targets = touched.filter { span in
            Markup.parseLine(span.text).isList
                || !span.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if targets.isEmpty { targets = touched }

        let parsed = targets.map { (span: $0, line: Markup.parseLine($0.text)) }
        let removing = parsed.allSatisfy { action.matches($0.line.kind) }

        var newPrefixes: [Int: String] = [:]
        for (span, line) in parsed {
            if removing {
                newPrefixes[span.index] = ""
            } else if !action.matches(line.kind) {
                newPrefixes[span.index] = indentString(span.text, line) + action.newMarker
            }
        }
        return renumbered(rewritingPrefixes(state, newPrefixes))
    }

    // MARK: - Indent

    static func indent(_ state: EditState) -> EditState {
        shiftingLevel(by: 1, state)
    }

    static func outdent(_ state: EditState) -> EditState {
        shiftingLevel(by: -1, state)
    }

    private static func shiftingLevel(by delta: Int, _ state: EditState) -> EditState {
        var newPrefixes: [Int: String] = [:]
        for span in touchedLines(state, lineSpans(state.text)) {
            let line = Markup.parseLine(span.text)
            guard line.isList else { continue }
            let level = min(max(0, line.level + delta), Markup.maxIndentLevel)
            guard level != line.level else { continue }
            newPrefixes[span.index] = indentation(level) + movedMarker(span.text, line)
        }
        return renumbered(rewritingPrefixes(state, newPrefixes))
    }

    private static func indentation(_ level: Int) -> String {
        String(repeating: " ", count: level * Markup.spacesPerIndent)
    }

    /// A numbered line changing level starts from 1: renumbering then either
    /// continues the run it joined or leaves it heading a new one.
    private static func movedMarker(_ raw: String, _ line: Markup.Line) -> String {
        let marker = markerString(raw, line)
        guard case .numbered = line.kind else { return marker }
        return "1" + marker.drop { $0.isNumber }
    }

    // MARK: - Return

    /// Return on a list line. nil means the line isn't a list (or the caret is
    /// inside its marker), so the editor should insert a normal newline.
    static func insertReturn(_ state: EditState) -> EditState? {
        let collapsed = removingSelection(state)
        let spans = lineSpans(collapsed.text)
        let caret = collapsed.selection.location
        let span = line(at: caret, in: spans)
        let parsed = Markup.parseLine(span.text)
        guard parsed.isList, caret - span.start >= parsed.prefixLength else { return nil }

        if parsed.content.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item outdents one level, or ends the list at level 0.
            let prefix = parsed.level > 0
                ? indentation(parsed.level - 1) + movedMarker(span.text, parsed)
                : ""
            let rewritten = rewritingPrefixes(
                EditState(text: collapsed.text, selection: NSRange(location: span.start + parsed.prefixLength, length: 0)),
                [span.index: prefix]
            )
            return renumbered(rewritten)
        }

        let marker: String
        switch parsed.kind {
        case .checklist: marker = Checklist.uncheckedMarker
        case .numbered(let number):
            let stored = markerString(span.text, parsed)
            marker = "\(number + 1)" + stored.drop { $0.isNumber }
        default: marker = "- "
        }
        let insertion = "\n" + indentString(span.text, parsed) + marker
        let inserted = EditState(
            text: (collapsed.text as NSString).replacingCharacters(
                in: NSRange(location: caret, length: 0),
                with: insertion
            ),
            selection: NSRange(location: caret + insertion.utf16.count, length: 0)
        )
        return renumbered(inserted)
    }

    private static func removingSelection(_ state: EditState) -> EditState {
        guard state.selection.length > 0 else { return state }
        return EditState(
            text: (state.text as NSString).replacingCharacters(in: state.selection, with: ""),
            selection: NSRange(location: state.selection.location, length: 0)
        )
    }

    // MARK: - Backspace

    /// Backspace with the caret right after a list marker: the line becomes
    /// plain text. nil means a normal backspace.
    static func backspace(_ state: EditState) -> EditState? {
        guard state.selection.length == 0 else { return nil }
        let span = line(at: state.selection.location, in: lineSpans(state.text))
        let parsed = Markup.parseLine(span.text)
        guard parsed.isList, state.selection.location - span.start == parsed.prefixLength else { return nil }
        return renumbered(rewritingPrefixes(state, [span.index: ""]))
    }

    // MARK: - Checkboxes

    /// The `[ ]` / `[x]` of a checklist line, as an offset range in that line.
    static func checkboxRange(inLine line: String) -> NSRange? {
        let parsed = Markup.parseLine(line)
        guard case .checklist = parsed.kind else { return nil }
        return NSRange(location: parsed.indentLength + 2, length: 3)
    }

    /// The checkbox under `offset` in the full text, if there is one.
    static func checkboxLine(at offset: Int, in text: String) -> (lineIndex: Int, range: NSRange)? {
        let span = line(at: offset, in: lineSpans(text))
        guard let local = checkboxRange(inLine: span.text) else { return nil }
        let range = NSRange(location: span.start + local.location, length: local.length)
        guard offset >= range.location, offset <= range.location + range.length else { return nil }
        return (span.index, range)
    }

    /// Toggles in place: the text length doesn't change and neither does the
    /// selection.
    static func toggleCheckbox(lineIndex: Int, _ state: EditState) -> EditState {
        EditState(text: Checklist.toggling(state.text, lineIndex: lineIndex), selection: state.selection)
    }

    // MARK: - Inline styles

    static func toggleInline(_ action: InlineAction, _ state: EditState) -> EditState {
        state.selection.length > 0
            ? togglingSelection(action, state)
            : togglingAtCaret(action, state)
    }

    private static func togglingAtCaret(_ action: InlineAction, _ state: EditState) -> EditState {
        let spans = lineSpans(state.text)
        let span = line(at: state.selection.location, in: spans)
        let parsed = Markup.parseLine(span.text)
        let contentStart = span.start + parsed.prefixLength
        let caret = max(state.selection.location, contentStart)
        let local = caret - contentStart

        // Inside the style: step out past its closing marker.
        for inlineSpan in Markup.inline(parsed.content).spans where inlineSpan.style.contains(action.style) {
            if inlineSpan.open.upperBound <= local, local <= inlineSpan.close.lowerBound {
                return EditState(
                    text: state.text,
                    selection: NSRange(location: contentStart + inlineSpan.close.upperBound, length: 0)
                )
            }
        }

        let ns = state.text as NSString
        let marker = action.marker
        let length = marker.utf16.count

        // Between an empty pair: pressing again takes the pair back out.
        if caret >= contentStart + length, caret + length <= span.end,
           ns.substring(with: NSRange(location: caret - length, length: length)) == marker,
           ns.substring(with: NSRange(location: caret, length: length)) == marker,
           action.isCarried(byRunOf: run(of: marker, before: caret, floor: contentStart, in: ns)) {
            return EditState(
                text: ns.replacingCharacters(in: NSRange(location: caret - length, length: length * 2), with: ""),
                selection: NSRange(location: caret - length, length: 0)
            )
        }

        return EditState(
            text: ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: marker + marker),
            selection: NSRange(location: caret + length, length: 0)
        )
    }

    private static func togglingSelection(_ action: InlineAction, _ state: EditState) -> EditState {
        let ns = state.text as NSString
        let spans = lineSpans(state.text)
        let selectionEnd = state.selection.location + state.selection.length

        // Each line's selected content, without its marker or outer spaces.
        var parts: [(range: NSRange, line: LineSpan, contentStart: Int)] = []
        for span in touchedLines(state, spans) {
            let parsed = Markup.parseLine(span.text)
            let contentStart = span.start + parsed.prefixLength
            var lower = max(state.selection.location, contentStart)
            var upper = min(selectionEnd, span.end)
            while lower < upper, isSpace(ns.character(at: lower)) { lower += 1 }
            while upper > lower, isSpace(ns.character(at: upper - 1)) { upper -= 1 }
            if lower < upper {
                parts.append((NSRange(location: lower, length: upper - lower), span, contentStart))
            }
        }
        guard !parts.isEmpty else { return state }

        let wrappings = parts.map { wrapping(of: $0.range, floor: $0.contentStart, ceiling: $0.line.end, action, ns) }
        let unwrapping = wrappings.allSatisfy { $0 != nil }

        let result = NSMutableString(string: state.text)
        let length = action.marker.utf16.count
        var delta = 0
        var firstInner = 0
        var lastInnerEnd = 0

        for (index, part) in parts.enumerated() {
            let lower: Int
            let upper: Int
            if unwrapping, let wrap = wrappings[index] {
                result.replaceCharacters(in: NSRange(location: wrap.lowerMarker + delta, length: length), with: "")
                delta -= length
                lower = wrap.lowerMarker + delta + length
                result.replaceCharacters(in: NSRange(location: wrap.upperMarker + delta, length: length), with: "")
                upper = wrap.upperMarker + delta
                delta -= length
            } else if wrappings[index] != nil {
                // Already styled, in a selection where others aren't: leave it.
                lower = part.range.location + delta
                upper = lower + part.range.length
            } else {
                result.insert(action.marker, at: part.range.location + delta)
                delta += length
                lower = part.range.location + delta
                upper = lower + part.range.length
                result.insert(action.marker, at: upper)
                delta += length
            }
            if index == 0 { firstInner = lower }
            lastInnerEnd = upper
        }

        return EditState(
            text: result as String,
            selection: NSRange(location: firstInner, length: lastInnerEnd - firstInner)
        )
    }

    /// Where this style's markers sit, if `range` is exactly wrapped by them —
    /// markers just outside the selection, or as the selection's own edges.
    /// Each location is the marker nearest the text.
    private static func wrapping(
        of range: NSRange,
        floor: Int,
        ceiling: Int,
        _ action: InlineAction,
        _ ns: NSString
    ) -> (lowerMarker: Int, upperMarker: Int)? {
        let marker = action.marker
        let length = marker.utf16.count
        let lower = range.location
        let upper = range.location + range.length

        let outside = min(
            run(of: marker, before: lower, floor: floor, in: ns),
            run(of: marker, after: upper, ceiling: ceiling, in: ns)
        )
        if action.isCarried(byRunOf: outside) {
            return (lower - length, upper)
        }

        let inner = min(
            run(of: marker, after: lower, ceiling: upper, in: ns),
            run(of: marker, before: upper, floor: lower, in: ns)
        )
        if inner * 2 < range.length, action.isCarried(byRunOf: inner) {
            return (lower + inner - length, upper - inner)
        }
        return nil
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9
    }

    private static func run(of marker: String, before offset: Int, floor: Int, in ns: NSString) -> Int {
        guard let unit = marker.utf16.first else { return 0 }
        var index = offset
        while index > floor, ns.character(at: index - 1) == unit { index -= 1 }
        return offset - index
    }

    private static func run(of marker: String, after offset: Int, ceiling: Int, in ns: NSString) -> Int {
        guard let unit = marker.utf16.first else { return 0 }
        var index = offset
        while index < ceiling, ns.character(at: index) == unit { index += 1 }
        return index - offset
    }

    // MARK: - Active state

    static func activeFormats(_ state: EditState) -> ActiveFormats {
        let spans = lineSpans(state.text)
        let touched = touchedLines(state, spans)
        let lines = touched.map { Markup.parseLine($0.text) }
        let meaningful = zip(touched, lines).filter { span, line in
            line.isList || !span.text.trimmingCharacters(in: .whitespaces).isEmpty
        }.map(\.1)
        let considered = meaningful.isEmpty ? lines : meaningful

        var active = ActiveFormats()
        active.checklist = considered.allSatisfy { ListAction.checklist.matches($0.kind) }
        active.bullet = considered.allSatisfy { ListAction.bullet.matches($0.kind) }
        active.numbered = considered.allSatisfy { ListAction.numbered.matches($0.kind) }
        active.canIndent = lines.contains(where: \.isList)

        // Inline state reads a selection within one line.
        guard touched.count == 1, let span = touched.first, let parsed = lines.first else { return active }
        let contentStart = span.start + parsed.prefixLength
        let lower = state.selection.location - contentStart
        let upper = lower + state.selection.length
        for inlineSpan in Markup.inline(parsed.content).spans
        where inlineSpan.open.lowerBound <= lower && upper <= inlineSpan.close.upperBound {
            if state.selection.length == 0,
               lower < inlineSpan.open.upperBound || lower > inlineSpan.close.lowerBound {
                continue
            }
            if inlineSpan.style.contains(.bold) { active.bold = true }
            if inlineSpan.style.contains(.italic) { active.italic = true }
            if inlineSpan.style.contains(.strikethrough) { active.strikethrough = true }
        }
        return active
    }

    // MARK: - Applying

    /// The single contiguous replacement turning `old` into `new`, so the
    /// editor can apply any operation as one undoable edit. Never splits a
    /// surrogate pair.
    static func replacement(from old: String, to new: String) -> (range: NSRange, text: String)? {
        guard old != new else { return nil }
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)

        var prefix = 0
        let limit = min(oldUnits.count, newUnits.count)
        while prefix < limit, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(oldUnits[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        while suffix < limit - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(oldUnits[oldUnits.count - suffix]) { suffix -= 1 }

        let inserted = newUnits[prefix..<(newUnits.count - suffix)]
        return (
            NSRange(location: prefix, length: oldUnits.count - suffix - prefix),
            String(decoding: inserted, as: UTF16.self)
        )
    }
}
