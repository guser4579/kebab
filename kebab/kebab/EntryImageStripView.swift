//
//  EntryImageGridView.swift
//  kebab
//

import SwiftUI

/// Renders an entry's image attachments as a horizontal strip of uniform
/// cards (never a grid), scrolling sideways when they overflow the row.
/// Tapping any image opens a full-screen pager.
struct EntryImageStripView: View {

    let attachments: [EntryAttachment]

    private struct ViewerState: Identifiable {
        let id: Int
    }

    @State private var viewer: ViewerState?

    private let cornerRadius: CGFloat = 12
    private let cellSpacing: CGFloat = 8
    // The old 2x2 grid cell (~177x140) scaled by 1.25 - every image renders
    // at this size regardless of count.
    private let cellWidth: CGFloat = 221
    private let cellHeight: CGFloat = 175

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: cellSpacing) {
                ForEach(attachments.indices, id: \.self) { index in
                    cell(index)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
        .frame(height: cellHeight)
        .fullScreenCover(item: $viewer) { state in
            ImageViewerView(attachments: attachments, initialIndex: state.id)
        }
    }

    private func cell(_ index: Int) -> some View {
        Button {
            viewer = ViewerState(id: index)
        } label: {
            Rectangle()
                .fill(Style.Color.separator)
                .overlay {
                    CachedAsyncImage(url: URL(string: attachments[index].url))
                }
                .frame(width: cellWidth, height: cellHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Style.Color.separator, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Full-screen viewer

private struct ImageViewerView: View {

    let attachments: [EntryAttachment]
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int

    init(attachments: [EntryAttachment], initialIndex: Int) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    CachedAsyncImage(
                        url: URL(string: attachment.url),
                        contentMode: .fit,
                        showsSpinner: true
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: attachments.count > 1 ? .automatic : .never))

            Button {
                dismiss()
            } label: {
                Icon("close")
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.tint(.black.opacity(0.4)), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, Style.Spacing.x4)
        }
    }
}
