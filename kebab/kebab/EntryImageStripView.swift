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

/// Photos-style pager: each page zooms (pinch, double-tap) and a vertical
/// drag at 1× swipes the viewer away. The cover's own background is clear —
/// the black is drawn here so it can fade during that drag and let the entry
/// underneath show through.
private struct ImageViewerView: View {

    let attachments: [EntryAttachment]
    let initialIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    /// 0 at rest → 1 when the background and close button have faded out.
    @State private var dismissProgress: CGFloat = 0

    init(attachments: [EntryAttachment], initialIndex: Int) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .opacity(1 - dismissProgress)
                .ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    ZoomableImagePage(
                        url: URL(string: attachment.url),
                        isCurrent: index == currentIndex,
                        onDismissDrag: handleDismissDrag
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: attachments.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

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
            .accessibilityLabel("Close")
            .padding(.trailing, Style.Spacing.x4)
            .opacity(1 - dismissProgress)
        }
        .presentationBackground(.clear)
    }

    private func handleDismissDrag(_ event: DismissDragEvent) {
        switch event {
        case .changed(let progress):
            dismissProgress = progress
        case .cancelled:
            withAnimation(.spring(duration: 0.35)) { dismissProgress = 0 }
        case .committed(let duration):
            withAnimation(.easeOut(duration: duration)) { dismissProgress = 1 }
        case .finished:
            // The image already left; the cover must go without its own
            // slide-down stacked on top.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}

/// Loads one page's image through the shared cache-through fetch (the cached
/// image is already the full 2048px upload), then hands it to the zoomable
/// scroll view.
private struct ZoomableImagePage: View {

    let url: URL?
    let isCurrent: Bool
    let onDismissDrag: (DismissDragEvent) -> Void

    @State private var image: UIImage?

    init(url: URL?, isCurrent: Bool, onDismissDrag: @escaping (DismissDragEvent) -> Void) {
        self.url = url
        self.isCurrent = isCurrent
        self.onDismissDrag = onDismissDrag
        _image = State(initialValue: url.flatMap { ImageCache.shared.object(forKey: $0 as NSURL) })
    }

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image, isCurrent: isCurrent, onDismissDrag: onDismissDrag)
            } else {
                ProgressView()
                    .tint(Style.Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            if let loaded = await CachedAsyncImage.fetch(url) {
                image = loaded
            }
        }
    }
}
