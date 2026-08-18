//
//  ImageStorageRepository.swift
//  kebab
//

import Foundation
import UIKit
import Supabase

/// Uploads entry images to the public `entry-images` Supabase Storage bucket.
///
/// Paths are unguessable — `{userId}/{UUID}.jpg` — which is the privacy model
/// for the public bucket: objects are only reachable with the exact URL stored
/// on the entry. Images are resized to max 2048pt and JPEG-compressed before
/// upload so a 48MP photo doesn't burn user bandwidth or storage quota.
final class ImageStorageRepository {

    static let bucket = "entry-images"

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    /// Uploads already-encoded JPEG payloads sequentially (max 4 per entry)
    /// and returns image attachments with their public URLs, in the order
    /// given. The outbox stages bytes in exactly this format, so there is no
    /// second decode/encode (and no second lossy generation) at upload time.
    func uploadImageData(_ payloads: [Data], userId: UUID) async throws -> [EntryAttachment] {
        var attachments: [EntryAttachment] = []
        for data in payloads {
            // Lowercased to match the RLS folder check: Swift renders UUIDs
            // uppercase but Postgres's auth.uid()::text is lowercase.
            let path = "\(userId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
            _ = try await supabase.storage
                .from(Self.bucket)
                .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
            let url = try supabase.storage
                .from(Self.bucket)
                .getPublicURL(path: path)
            attachments.append(EntryAttachment(
                type: "image",
                url: url.absoluteString,
                title: nil,
                favicon_url: nil,
                image_url: nil
            ))
        }
        return attachments
    }

    nonisolated static func jpegData(
        from image: UIImage,
        maxDimension: CGFloat = 2048,
        quality: CGFloat = 0.8
    ) throws -> Data {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let resized: UIImage
        if scale < 1 {
            let target = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: target)
            resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        } else {
            resized = image
        }
        guard let data = resized.jpegData(compressionQuality: quality) else {
            throw NSError(
                domain: "ImageStorage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't encode image."]
            )
        }
        return data
    }
}
