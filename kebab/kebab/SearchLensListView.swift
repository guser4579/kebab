//
//  SearchLensListView.swift
//  kebab
//

import SwiftUI

/// Every thought in one Explore lens, in the lens's order. A snapshot taken
/// when the list opens — it never reshuffles under the user. Each row's meta
/// line says why the thought is here ("Fired 4 times · 21d").
struct SearchLensListView: View {

    let tile: SearchTile
    let workspace: SearchWorkspace
    let feedViewModel: FeedViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]

    private struct Row: Identifiable {
        let member: SearchLensMember
        let entry: Entry
        var id: UUID { entry.id }
    }

    init(tile: SearchTile, workspace: SearchWorkspace, feedViewModel: FeedViewModel) {
        self.tile = tile
        self.workspace = workspace
        self.feedViewModel = feedViewModel
        _rows = State(initialValue: tile.members.compactMap { member in
            workspace.corpus.indexedEntry(id: member.entryId).map { Row(member: member, entry: $0) }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchHeaderBar(onBack: { dismiss() }) {
                Text(tile.title)
                    .font(Style.Typography.headerTitle())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        SearchMetaRow(
                            meta: "\(row.member.reason) · \(Style.Timestamp.relative(for: row.member.date))",
                            entry: row.entry,
                            destination: EntryDetailView(
                                entry: row.entry,
                                feedViewModel: feedViewModel,
                                highlightOnArrival: true
                            ),
                            onOpen: { workspace.noteOpened(entryId: row.entry.id) }
                        )
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.Color.background)
        .foregroundColor(Style.Color.primaryText)
        .ignoresSafeArea(edges: .top)
        .background(Style.Color.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .enablesSwipeBack()
    }
}
