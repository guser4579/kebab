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
