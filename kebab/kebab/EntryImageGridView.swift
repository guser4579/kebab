//
//  EntryImageGridView.swift
//  kebab
//

import SwiftUI

/// Renders an entry's image attachments: one image full-width, two side by
/// side, three or four in a two-column grid. Tapping any image opens a
/// full-screen pager.
struct EntryImageGridView: View {

    let attachments: [EntryAttachment]

    private struct ViewerState: Identifiable {
        let id: Int
    }

    @State private var viewer: ViewerState?

    private let cornerRadius: CGFloat = 12
    private let gridSpacing: CGFloat = 4

    var body: some View {
        Group {
            switch attachments.count {
            case 1:
                cell(0, height: 280)
            case 2:
                HStack(spacing: gridSpacing) {
                    cell(0, height: 180)
                    cell(1, height: 180)
                }
            default:
                VStack(spacing: gridSpacing) {
                    HStack(spacing: gridSpacing) {
                        cell(0, height: 140)
                        cell(1, height: 140)
                    }
                    HStack(spacing: gridSpacing) {
                        cell(2, height: 140)
                        if attachments.count > 3 {
                            cell(3, height: 140)
                        } else {
                            Color.clear.frame(height: 140)
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: $viewer) { state in
            ImageViewerView(attachments: attachments, initialIndex: state.id)
        }
    }

    private func cell(_ index: Int, height: CGFloat) -> some View {
        Button {
            Haptics.lightTap()
            viewer = ViewerState(id: index)
        } label: {
            Rectangle()
                .fill(Style.Color.separator)
                .overlay {
                    AsyncImage(url: URL(string: attachments[index].url)) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
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
                    AsyncImage(url: URL(string: attachment.url)) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFit()
                        } else {
                            ProgressView()
                                .tint(Style.Color.secondary)
                        }
                    }
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
