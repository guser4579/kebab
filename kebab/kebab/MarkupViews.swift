//
//  MarkupViews.swift
//  kebab
//
//  SwiftUI rendering of `Markup`: styled text and the list block renderer the
//  feed row and the Entry screen share. Checklist items are the reference look
//  for every other list kind.
//

import SwiftUI

/// Rows read a parsed body several times per evaluation; parse each body once.
enum MarkupCache {
    private final class Box {
        let document: Markup.Document
        init(_ document: Markup.Document) { self.document = document }
    }

    private static let documents: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()

    static func document(_ content: String) -> Markup.Document {
        if let cached = documents.object(forKey: content as NSString) {
            return cached.document
        }
        let document = Markup.document(content)
        documents.setObject(Box(document), forKey: content as NSString)
        return document
    }
}

enum MarkupText {

    /// Text carrying its inline styles, one source line at a time so a style
    /// can never cross a newline. Colour is left to the surrounding view.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            for run in Markup.inline(line).runs {
                var piece = AttributedString(run.text)
                if let weight = weight(for: run.style) {
                    piece.font = Style.Typography.face(16, weight)
                }
                if run.style.contains(.strikethrough) {
                    piece.strikethroughStyle = .single
                }
                result.append(piece)
            }
        }
        return result
    }

    static func weight(for style: Markup.InlineStyle) -> Style.Typography.FaceWeight? {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): return .semiboldItalic
        case (true, false): return .semibold
        case (false, true): return .italic
        case (false, false): return nil
        }
    }
}

/// A body containing list lines, laid out block by block. Text stays
/// hit-transparent so a host's navigation still works; only checklist items
/// intercept taps.
struct MarkupBlocksView: View {

    enum ChecklistHitArea {
        /// Only the checkbox and its label toggle; the rest of the row's width
        /// falls through to the host (the feed row's open-detail behaviour).
        case label
        /// The whole row toggles (the Entry screen).
        case fullRow
    }

    let blocks: [Markup.Block]
    var checklistHitArea: ChecklistHitArea = .fullRow
    var allowsChecklistToggle: Bool = true
    let onToggleChecklistItem: (Int) -> Void

    private static let indentPerLevel: CGFloat = 24
    private static let bulletColumnWidth: CGFloat = 17

    /// Wide enough for the longest number in this body, so `9.` and `10.`
    /// line up.
    private var numberColumnWidth: CGFloat {
        let longest = blocks.reduce(0) { current, block in
            if case .item(_, _, _, .numbered(let number), _) = block {
                return max(current, String(number).count)
            }
            return current
        }
        return longest > 2 ? 36 : 26
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.Spacing.x2) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(_, let text):
                    Text(MarkupText.attributed(text))
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.primaryText)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                case .item(_, let lineIndex, let level, let kind, let content):
                    item(lineIndex: lineIndex, kind: kind, content: content)
                        .padding(.leading, CGFloat(level) * Self.indentPerLevel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func item(lineIndex: Int, kind: Markup.ListKind, content: String) -> some View {
        switch kind {
        case .checklist(let checked):
            checklistItem(lineIndex: lineIndex, checked: checked, content: content)
        case .bullet:
            textItem(content: content) {
                Text("•")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.secondary)
                    .frame(width: Self.bulletColumnWidth, alignment: .center)
            }
        case .numbered(let number):
            textItem(content: content, spacing: Style.Spacing.x2) {
                Text("\(number).")
                    .font(Style.Typography.body())
                    .monospacedDigit()
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)
                    .frame(width: numberColumnWidth, alignment: .trailing)
            }
        }
    }

    private func textItem<Marker: View>(
        content: String,
        spacing: CGFloat = Style.Spacing.x3,
        @ViewBuilder marker: () -> Marker
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            marker()

            Text(MarkupText.attributed(content))
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func checklistItem(lineIndex: Int, checked: Bool, content: String) -> some View {
        switch checklistHitArea {
        case .label:
            HStack(spacing: 0) {
                checklistButton(lineIndex: lineIndex, checked: checked, content: content, fillsRow: false)
                Spacer(minLength: 0)
            }
        case .fullRow:
            checklistButton(lineIndex: lineIndex, checked: checked, content: content, fillsRow: true)
        }
    }

    private func checklistButton(lineIndex: Int, checked: Bool, content: String, fillsRow: Bool) -> some View {
        Button {
            onToggleChecklistItem(lineIndex)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Style.Spacing.x3) {
                Image(systemName: checked ? "checkmark.square" : "square")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(checked ? Style.Color.secondary : Style.Color.primaryText)

                Text(MarkupText.attributed(content))
                    .font(Style.Typography.body())
                    .foregroundColor(checked ? Style.Color.secondary : Style.Color.primaryText)
                    .strikethrough(checked, color: Style.Color.secondary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)

                if fillsRow {
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(allowsChecklistToggle)
    }
}
