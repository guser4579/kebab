//
//  ComposerAttachments.swift
//  kebab
//

import SwiftUI
import UIKit

/// An image staged in the composer, not yet uploaded. Uploads happen on send.
///
/// Staging is where ALL expensive image work happens: the upload-ceiling
/// downscale and the JPEG encode both run off the main actor at attach time,
/// so full-resolution camera originals never survive past this point and the
/// send tap never pays for resize/encode/decode work.
struct PendingImage: Identifiable, Equatable {
    let id = UUID()
    /// Display + upload-source image, already ≤ the 2048pt upload ceiling.
    let image: UIImage
    /// Upload-ready JPEG bytes — the exact payload the outbox stages and the
    /// flush uploads, encoded once.
    let jpegData: Data

    /// Stages raw picked/imported bytes (Photos picker, Files, image paste
    /// data): downsampled decode + JPEG encode, off the main actor.
    static func staged(fromData data: Data) async -> PendingImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = ImageDecode.downsampled(data),
                  let jpeg = try? ImageStorageRepository.jpegData(from: image)
            else { return nil }
            return PendingImage(image: image, jpegData: jpeg)
        }.value
    }

    /// Stages an in-memory capture (camera, pasted UIImage) the same way.
    static func staged(fromImage source: UIImage) async -> PendingImage? {
        await Task.detached(priority: .userInitiated) {
            guard let jpeg = try? ImageStorageRepository.jpegData(from: source),
                  let image = ImageDecode.downsampled(jpeg)
            else { return nil }
            return PendingImage(image: image, jpegData: jpeg)
        }.value
    }
}

/// One place that decides whether pasteboard content is a link, shared by the
/// Paste affordance and the text views' paste interception — both routes
/// produce the same staged-link attachment, never two representations.
enum PastedLink {

    /// The URL the pasteboard is currently offering, or nil when its content
    /// isn't a bare URL. Prose that merely *contains* a URL deliberately
    /// returns nil: that pastes as ordinary text and is still parsed at send.
    /// Reads the pasteboard — only for paths where the system already
    /// mediated the paste (the text views' edit-menu paste overrides); the
    /// Paste chip routes system-provided payloads through `from(string:)`.
    static func current() -> URL? {
        let pasteboard = UIPasteboard.general
        if let string = pasteboard.string {
            return from(string: string)
        }
        return pasteboard.url
    }

    /// Link-shape decision for a pasted string, wherever it came from —
    /// identical normalization for the pasteboard path and the system
    /// paste-control payload path.
    static func from(string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace })
        else { return nil }

        if let direct = URL(string: trimmed), direct.scheme != nil {
            return direct
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let match = detector.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let detected = match.url {
            return detected
        }
        // Bare host ("nytimes.com") — only when it looks like a domain.
        if trimmed.contains("."), let assumed = URL(string: "https://" + trimmed) {
            return assumed
        }
        return nil
    }
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
