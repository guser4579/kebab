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

enum Checklist {

    static let uncheckedMarker = "- [ ] "
    static let checkedMarker   = "- [x] "

    /// The marker prefix of `line`, or nil when it isn't a checklist line.
    static func marker(of line: String) -> String? {
        if line.hasPrefix(uncheckedMarker) { return uncheckedMarker }
        if line.hasPrefix(checkedMarker) { return checkedMarker }
        return nil
    }

    static func hasChecklist(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains { marker(of: $0) != nil }
    }

    /// One rendered segment of checklist-aware content: either a run of
    /// plain-text lines or a single interactive checklist item.
    enum Segment: Identifiable {
        case text(id: Int, String)
        case item(id: Int, lineIndex: Int, text: String, checked: Bool)

        var id: Int {
            switch self {
            case .text(let id, _): return id
            case .item(let id, _, _, _): return id
            }
        }
    }

    /// Splits content into plain-text runs and checklist items, preserving
    /// order. `lineIndex` addresses the original line for toggling.
    static func segments(of content: String) -> [Segment] {
        var segments: [Segment] = []
        var pendingText: [String] = []
        var nextId = 0

        func flushText() {
            let block = pendingText.joined(separator: "\n")
            if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(id: nextId, block))
                nextId += 1
            }
            pendingText = []
        }

        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            if let marker = marker(of: line) {
                flushText()
                segments.append(.item(
                    id: nextId,
                    lineIndex: index,
                    text: String(line.dropFirst(marker.count)),
                    checked: marker == checkedMarker
                ))
                nextId += 1
            } else {
                pendingText.append(line)
            }
        }
        flushText()
        return segments
    }

    /// Returns content with the checklist line at `lineIndex` toggled.
    /// Content is returned unchanged when the line no longer carries a marker
    /// (e.g. the entry was edited concurrently).
    static func toggling(_ content: String, lineIndex: Int) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex),
              let marker = marker(of: lines[lineIndex])
        else { return content }

        let item = lines[lineIndex].dropFirst(marker.count)
        lines[lineIndex] = (marker == uncheckedMarker ? checkedMarker : uncheckedMarker) + item
        return lines.joined(separator: "\n")
    }
}
