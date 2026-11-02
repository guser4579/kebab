//
//  Checklist.swift
//  kebab
//
//  Checklist items are encoded as marker lines inside ordinary entry content
//  ("- [ ] item" / "- [x] item"). A List is therefore a completely ordinary
//  entry — one identity, one text field — so drafts, the outbox, offline
//  sync, editing, search, comments, and collection filing all work unchanged.
//

import Foundation

nonisolated enum Checklist {

    static let uncheckedMarker = "- [ ] "
    static let checkedMarker   = "- [x] "

    /// The marker prefix of an unindented `line`, or nil when it isn't a
    /// checklist line. The comment editor's continuation reads this; everything
    /// else reads `Markup`.
    static func marker(of line: String) -> String? {
        if line.hasPrefix(uncheckedMarker) { return uncheckedMarker }
        if line.hasPrefix(checkedMarker) { return checkedMarker }
        return nil
    }

    /// Any checklist line, at any indent.
    static func hasChecklist(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains { line in
            if case .checklist = Markup.parseLine(line).kind { return true }
            return false
        }
    }

    /// How many items are still unchecked, at any indent.
    static func openItemCount(_ content: String) -> Int {
        content.components(separatedBy: "\n").filter { line in
            if case .checklist(checked: false) = Markup.parseLine(line).kind { return true }
            return false
        }.count
    }

    /// Returns content with the checklist line at `lineIndex` toggled.
    /// `lineIndex` is the line's index in the content. Content is returned
    /// unchanged when the line no longer carries a marker (e.g. the entry was
    /// edited concurrently).
    static func toggling(_ content: String, lineIndex: Int) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return content }
        let line = Markup.parseLine(lines[lineIndex])
        guard case .checklist(let checked) = line.kind else { return content }

        let indent = String(lines[lineIndex].unicodeScalars.prefix(line.indentLength))
        lines[lineIndex] = indent + (checked ? uncheckedMarker : checkedMarker) + line.content
        return lines.joined(separator: "\n")
    }
}
