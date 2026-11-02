//
//  Markup.swift
//  kebab
//
//  The one reading of formatted thoughts. A thought stays ordinary plain text
//  with markdown markers (see Checklist.swift for why), and every surface —
//  feed, Entry screen, search, notifications, the editor's live styling —
//  asks this parser what those markers mean, so no surface can disagree.
//
//  Deliberately not `AttributedString(markdown:)`: that also reads links, code
//  spans, and backslash escapes, which would change how existing thoughts
//  look. The grammar here is small and explicit.
//
//  Hidden bodies are masked with `*` characters, so they must NEVER reach this
//  parser as if they were content: `document(of:)` is the gate for entries.
//

import Foundation

nonisolated enum Markup {

    /// Indent levels are 0, 1, and 2; deeper indents clamp for display.
    static let maxIndentLevel = 2
    static let spacesPerIndent = 2

    // MARK: - Blocks

    enum ListKind: Equatable, Sendable {
        case bullet
        case numbered(Int)
        case checklist(checked: Bool)
    }

    /// One line's structure. Lengths are UTF-16, so the editor can use them
    /// as NSRange offsets directly.
    struct Line: Equatable, Sendable {
        /// nil = paragraph.
        let kind: ListKind?
        /// Display level, clamped to `maxIndentLevel`. Always 0 on paragraphs.
        let level: Int
        /// Leading whitespace, on list lines only.
        let indentLength: Int
        /// Indent + list marker + its trailing space. 0 on paragraphs.
        let prefixLength: Int
        /// The line after the prefix.
        let content: String

        var isList: Bool { kind != nil }
    }

    static func parseLine(_ line: String) -> Line {
        let paragraph = Line(kind: nil, level: 0, indentLength: 0, prefixLength: 0, content: line)
        let scalars = Array(line.unicodeScalars)

        var index = 0
        var levels = 0
        var pendingSpaces = 0
        while index < scalars.count {
            if scalars[index] == " " {
                pendingSpaces += 1
                if pendingSpaces == spacesPerIndent {
                    levels += 1
                    pendingSpaces = 0
                }
            } else if scalars[index] == "\t" {
                levels += 1
                pendingSpaces = 0
            } else {
                break
            }
            index += 1
        }
        let indentLength = index
        let rest = scalars[index...]

        func matches(_ marker: String) -> Bool {
            rest.starts(with: marker.unicodeScalars)
        }

        var kind: ListKind?
        var markerLength = 0
        if matches("- [ ] ") {
            kind = .checklist(checked: false)
            markerLength = 6
        } else if matches("- [x] ") || matches("- [X] ") {
            kind = .checklist(checked: true)
            markerLength = 6
        } else if matches("- ") || matches("* ") || matches("• ") {
            kind = .bullet
            markerLength = 2
        } else {
            var digits = 0
            var number = 0
            for scalar in rest.prefix(4) {
                guard let value = scalar.properties.numericType == .decimal && scalar.isASCII
                    ? Int(String(scalar)) : nil
                else { break }
                number = number * 10 + value
                digits += 1
            }
            if (1...3).contains(digits) {
                let tail = rest.dropFirst(digits)
                if tail.starts(with: ". ".unicodeScalars) || tail.starts(with: ") ".unicodeScalars) {
                    kind = .numbered(number)
                    markerLength = digits + 2
                }
            }
        }
        guard let kind else { return paragraph }

        var content = String.UnicodeScalarView()
        content.append(contentsOf: rest.dropFirst(markerLength))
        return Line(
            kind: kind,
            level: min(levels, maxIndentLevel),
            indentLength: indentLength,
            // Every prefix scalar sits in the BMP, so scalars == UTF-16 units.
            prefixLength: indentLength + markerLength,
            content: String(content)
        )
    }

    enum Block: Identifiable, Equatable, Sendable {
        /// A run of consecutive non-list lines, joined with newlines.
        case paragraph(id: Int, text: String)
        /// `lineIndex` addresses the line in the content, for toggling.
        case item(id: Int, lineIndex: Int, level: Int, kind: ListKind, content: String)

        var id: Int {
            switch self {
            case .paragraph(let id, _): return id
            case .item(let id, _, _, _, _): return id
            }
        }

        /// How many hard lines this block spends of a collapse budget.
        var lineCount: Int {
            switch self {
            case .paragraph(_, let text): return text.components(separatedBy: "\n").count
            case .item: return 1
            }
        }
    }

    /// A parsed body. `numbered` kinds carry the number to DISPLAY, already
    /// counted up from the run's first number.
    struct Document: Equatable, Sendable {
        let blocks: [Block]
        let hasLists: Bool
        /// True when any paragraph carries an inline style.
        let hasInlineStyles: Bool
        var isPlain: Bool { !hasLists && !hasInlineStyles }
    }

    static func document(_ content: String) -> Document {
        var blocks: [Block] = []
        var pending: [String] = []
        var nextId = 0
        var hasLists = false
        var hasInlineStyles = false

        func flushParagraph() {
            let text = pending.joined(separator: "\n")
            pending = []
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(.paragraph(id: nextId, text: text))
            nextId += 1
        }

        let lines = content.components(separatedBy: "\n")
        let numbers = displayNumbers(for: lines)
        for (index, raw) in lines.enumerated() {
            let line = parseLine(raw)
            guard var kind = line.kind else {
                if !hasInlineStyles, !inline(raw).spans.isEmpty {
                    hasInlineStyles = true
                }
                pending.append(raw)
                continue
            }
            if let number = numbers[index] { kind = .numbered(number) }
            flushParagraph()
            hasLists = true
            blocks.append(.item(
                id: nextId,
                lineIndex: index,
                level: line.level,
                kind: kind,
                content: line.content
            ))
            nextId += 1
        }
        flushParagraph()
        return Document(blocks: blocks, hasLists: hasLists, hasInlineStyles: hasInlineStyles)
    }

    /// The gate for entries: a hidden body is masked text, never markup.
    /// nil means "render the masked string as is".
    static func document(of entry: Entry) -> Document? {
        entry.isContentHidden ? nil : document(entry.content)
    }

    /// The number each numbered line should show. A run is the numbered items
    /// at one indent, counted from its first number. Deeper lines nested
    /// inside don't break it; a paragraph, a blank line, a shallower line, or
    /// another list kind at the same indent do.
    static func displayNumbers(for lines: [String]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var counters: [Int: Int] = [:]
        for (index, raw) in lines.enumerated() {
            let line = parseLine(raw)
            guard let kind = line.kind else {
                counters.removeAll()
                continue
            }
            for level in counters.keys where level > line.level {
                counters[level] = nil
            }
            if case .numbered(let stored) = kind {
                let number = counters[line.level].map { $0 + 1 } ?? stored
                counters[line.level] = number
                result[index] = number
            } else {
                counters[line.level] = nil
            }
        }
        return result
    }

    // MARK: - Inline styles

    struct InlineStyle: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let bold = InlineStyle(rawValue: 1)
        static let italic = InlineStyle(rawValue: 2)
        static let strikethrough = InlineStyle(rawValue: 4)
    }

    struct InlineRun: Equatable, Sendable {
        let text: String
        let style: InlineStyle
        /// UTF-16 range in the source line.
        let range: Range<Int>
    }

    /// One matched marker pair. Ranges are UTF-16 offsets in the source line.
    struct InlineSpan: Equatable, Sendable {
        let style: InlineStyle
        let open: Range<Int>
        let close: Range<Int>
    }

    struct InlineLayout: Equatable, Sendable {
        /// The visible text in order, markers excluded.
        let runs: [InlineRun]
        let spans: [InlineSpan]
        var plainText: String { runs.map(\.text).joined() }
    }

    /// Parses one line's inline styles. Never spans a newline: callers hand
    /// over single lines, and a stray newline simply ends any search for a
    /// closing marker.
    static func inline(_ line: String) -> InlineLayout {
        let chars = Array(line)
        var offsets: [Int] = [0]
        offsets.reserveCapacity(chars.count + 1)
        for char in chars {
            offsets.append(offsets[offsets.count - 1] + char.utf16.count)
        }

        var runs: [InlineRun] = []
        var spans: [InlineSpan] = []

        func appendText(_ range: Range<Int>, _ style: InlineStyle) {
            guard !range.isEmpty else { return }
            let text = String(chars[range])
            let utf16 = offsets[range.lowerBound]..<offsets[range.upperBound]
            if let last = runs.last, last.style == style, last.range.upperBound == utf16.lowerBound {
                runs[runs.count - 1] = InlineRun(
                    text: last.text + text,
                    style: style,
                    range: last.range.lowerBound..<utf16.upperBound
                )
            } else {
                runs.append(InlineRun(text: text, style: style, range: utf16))
            }
        }

        func parse(_ bounds: Range<Int>, _ inherited: InlineStyle) {
            var index = bounds.lowerBound
            var textStart = index
            while index < bounds.upperBound {
                let char = chars[index]
                guard char == "*" || char == "~" else {
                    index += 1
                    continue
                }
                let run = runLength(of: char, at: index, limit: bounds.upperBound, in: chars)
                if let marker = marker(char: char, length: run),
                   isOpening(at: index, length: run, bounds: bounds, in: chars),
                   let close = closing(
                       of: char, length: run, after: index + run, bounds: bounds, in: chars
                   ) {
                    appendText(textStart..<index, inherited)
                    spans.append(InlineSpan(
                        style: marker,
                        open: offsets[index]..<offsets[index + run],
                        close: offsets[close]..<offsets[close + run]
                    ))
                    parse((index + run)..<close, inherited.union(marker))
                    index = close + run
                    textStart = index
                } else {
                    index += run
                }
            }
            appendText(textStart..<bounds.upperBound, inherited)
        }

        parse(0..<chars.count, [])
        return InlineLayout(runs: runs, spans: spans.sorted { $0.open.lowerBound < $1.open.lowerBound })
    }

    private static func runLength(of char: Character, at index: Int, limit: Int, in chars: [Character]) -> Int {
        var end = index
        while end < limit, chars[end] == char { end += 1 }
        return end - index
    }

    private static func marker(char: Character, length: Int) -> InlineStyle? {
        switch (char, length) {
        case ("*", 1): return .italic
        case ("*", 2): return .bold
        case ("*", 3): return [.bold, .italic]
        case ("~", 2): return .strikethrough
        default: return nil
        }
    }

    /// Anything that isn't a letter or digit may flank a marker.
    private static func isBoundary(_ char: Character) -> Bool {
        !char.isLetter && !char.isNumber
    }

    private static func isOpening(at index: Int, length: Int, bounds: Range<Int>, in chars: [Character]) -> Bool {
        if index > bounds.lowerBound, !isBoundary(chars[index - 1]) { return false }
        let next = index + length
        guard next < bounds.upperBound else { return false }
        return !chars[next].isWhitespace
    }

    /// The first run that can close `length` markers. A longer run closes with
    /// its last `length` characters only when the rest of it closes a style
    /// inside: `**bold *it***` nests, while the stray marker in `*a**` is not
    /// swallowed.
    private static func closing(
        of char: Character,
        length: Int,
        after start: Int,
        bounds: Range<Int>,
        in chars: [Character]
    ) -> Int? {
        var index = start
        while index < bounds.upperBound {
            if chars[index].isNewline { return nil }
            guard chars[index] == char else {
                index += 1
                continue
            }
            let run = runLength(of: char, at: index, limit: bounds.upperBound, in: chars)
            let end = index + run
            if index > start, run >= length, !chars[index - 1].isWhitespace,
               end == bounds.upperBound || isBoundary(chars[end]),
               run == length || closesInnerStyle(chars[start..<(end - length)], length: run - length) {
                return end - length
            }
            index = end
        }
        return nil
    }

    private static func closesInnerStyle(_ content: ArraySlice<Character>, length: Int) -> Bool {
        let text = String(content)
        return inline(text).spans.contains { span in
            span.close.upperBound == text.utf16.count && span.close.count == length
        }
    }

    // MARK: - Plain text

    static let plainUncheckedMarker = "☐ "
    static let plainCheckedMarker = "☑ "

    /// The thought without markup, line structure intact, for every surface
    /// that shows text without styling. Hidden bodies must not come here.
    static func plainText(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let numbers = displayNumbers(for: lines)
        return lines.enumerated().map { index, raw in
            let line = parseLine(raw)
            let text = inline(line.content).plainText
            switch line.kind {
            case nil: return text
            case .bullet: return "• " + text
            case .numbered: return "\(numbers[index] ?? 1). " + text
            case .checklist(let checked): return (checked ? plainCheckedMarker : plainUncheckedMarker) + text
            }
        }.joined(separator: "\n")
    }
}
