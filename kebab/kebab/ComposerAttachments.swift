//
//  ComposerAttachments.swift
//  kebab
//

import SwiftUI
import UIKit

/// An image staged in the composer, not yet uploaded. Uploads happen on send.
struct PendingImage: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage
}

/// A URL staged in the composer as a compact chip. The full URL is preserved
/// underneath; only the root domain (and favicon when available) shows.
extension URL {
    /// "www.nytimes.com" → "nytimes.com"
    var rootDomainDisplay: String {
        guard let host else { return absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Best-effort favicon location — an enhancement, never a dependency.
    var faviconURL: URL? {
        guard let host, let scheme else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}

/// Compact staged-link chip: favicon (falling back to the link glyph), root
/// domain, and a removal ×. Shared between the inline composer and the
/// full-screen composer. Removing the link never touches written context.
struct ComposerLinkChip: View {

    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Icon("link-02", glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.secondary)
                CachedAsyncImage(url: url.faviconURL, contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(width: 16, height: 16)

            Text(url.rootDomainDisplay)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.primaryText)
                .lineLimit(1)

            Button {
                Haptics.lightTap()
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Style.Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(
            Capsule()
                .fill(Style.Color.composerBackground)
                .overlay(Capsule().stroke(Style.Color.separator, lineWidth: 1))
        )
    }
}

/// Staged image thumbnails with per-image remove — shared between the inline
/// composer and the full-screen composer so attachment state and order look
/// identical in both. Scrolls horizontally rather than growing vertically.
struct ComposerThumbnailStrip: View {

    @Binding var images: [PendingImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { pending in
                    Image(uiImage: pending.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                Haptics.lightTap()
                                images.removeAll { $0.id == pending.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .padding(2)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                }
            }
        }
        // Horizontal ScrollViews claim all offered height; pin to content.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Minimal camera capture wrapper. Photos and Files use native SwiftUI
/// pickers; UIImagePickerController remains the simplest camera path.
struct CameraPicker: UIViewControllerRepresentable {

    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
