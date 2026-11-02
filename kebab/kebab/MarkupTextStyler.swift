//
//  MarkupTextStyler.swift
//  kebab
//
//  The editor's "Notes-lite" look: real styling, with every marker left in
//  place and dimmed. Attributes only ever change here, and only ever on
//  `Markup`'s reading of the text, so what's shown while typing matches what
//  the feed will render. The stored text stays plain.
//

import UIKit

enum MarkupTextStyler {

    private static let bodyFont = Style.Typography.faceUIFont(16)

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: Style.Color.primaryTextUIColor]
    }

    static func styleAll(_ storage: NSTextStorage) {
        style(storage, paragraphsIn: NSRange(location: 0, length: storage.length))
    }

    /// Restyles the paragraphs an edit touched, and nothing else.
    static func style(_ storage: NSTextStorage, around edited: NSRange) {
        let location = min(edited.location, storage.length)
        let length = min(edited.length, storage.length - location)
        style(storage, paragraphsIn: NSRange(location: location, length: length))
    }

    private static func style(_ storage: NSTextStorage, paragraphsIn range: NSRange) {
        let ns = storage.string as NSString
        let whole = ns.paragraphRange(for: range)
        storage.beginEditing()
        ns.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, enclosing, _ in
            styleParagraph(storage, ns.substring(with: paragraph), at: paragraph.location, enclosing: enclosing)
        }
        storage.endEditing()
    }

    private static func styleParagraph(
        _ storage: NSTextStorage,
        _ text: String,
        at start: Int,
        enclosing: NSRange
    ) {
        let line = Markup.parseLine(text)
        var base = bodyAttributes
        if line.isList {
            let prefix = (text as NSString).substring(to: line.prefixLength)
            let style = NSMutableParagraphStyle()
            style.headIndent = ceil((prefix as NSString).size(withAttributes: [.font: bodyFont]).width)
            base[.paragraphStyle] = style
        }
        storage.setAttributes(base, range: enclosing)

        let secondary = Style.Color.secondaryUIColor
        if line.prefixLength > 0 {
            storage.addAttribute(
                .foregroundColor,
                value: secondary,
                range: NSRange(location: start, length: line.prefixLength)
            )
        }

        let contentStart = start + line.prefixLength
        let contentLength = (text as NSString).length - line.prefixLength
        if case .checklist(checked: true) = line.kind, contentLength > 0 {
            let content = NSRange(location: contentStart, length: contentLength)
            storage.addAttribute(.foregroundColor, value: secondary, range: content)
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
        }

        let layout = Markup.inline(line.content)
        for run in layout.runs where !run.style.isEmpty {
            let range = NSRange(location: contentStart + run.range.lowerBound, length: run.range.count)
            if let weight = MarkupText.weight(for: run.style) {
                storage.addAttribute(.font, value: Style.Typography.faceUIFont(16, weight), range: range)
            }
            if run.style.contains(.strikethrough) {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        for span in layout.spans {
            for marker in [span.open, span.close] {
                storage.addAttribute(
                    .foregroundColor,
                    value: secondary,
                    range: NSRange(location: contentStart + marker.lowerBound, length: marker.count)
                )
            }
        }
    }
}
