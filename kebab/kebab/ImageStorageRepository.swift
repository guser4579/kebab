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

    /// Physically removes the Storage objects behind a set of image
    /// attachments. Call this ONLY once the database rows that referenced them
    /// are confirmed deleted — the bytes are the last copy, and a row that
    /// still exists must always resolve to a live object.
    ///
    /// Best-effort by design: the database is the source of truth, so a bucket
    /// failure here leaves an unreachable orphan (the path is unguessable)
    /// rather than resurrecting content the user already deleted. Failures are
    /// logged, never thrown. Non-image attachments are ignored, and link
    /// preview images live on remote hosts, so `storagePath(fromPublicUrl:)`
    /// returns nil for them — nothing outside this bucket can be touched.
    func removeImageObjects(for attachments: [EntryAttachment]) async {
        let paths = attachments
            .filter { $0.attachmentType == .image }
            .compactMap { Self.storagePath(fromPublicUrl: $0.url) }
        guard !paths.isEmpty else { return }
        do {
            // An entry carries at most 4 images, so this is always one small
            // request — no batching needed (unlike the account-wide purge).
            let removed = try await supabase.storage
                .from(Self.bucket)
                .remove(paths: paths)
            // Storage answers 200 with a SHORT list (often empty) when RLS
            // filters the DELETE — the call "succeeds" while removing nothing.
            // Without this check, cleanup silently no-ops forever.
            if removed.count < paths.count {
                print("Entry image cleanup removed \(removed.count)/\(paths.count) object(s) — check the entry-images select+delete policies on storage.objects")
            }
        } catch {
            // Observable but harmless. Deliberately logs the count and the
            // transport error only — never entry content.
            print("Entry image cleanup failed for \(paths.count) object(s):", error.localizedDescription)
        }
    }

    /// Extracts the in-bucket object path from a public URL
    /// (`…/object/public/entry-images/<path>`). The canonical way back from a
    /// stored attachment URL to the key Storage expects: `remove(paths:)` takes
    /// in-bucket paths, and handing it a public URL deletes nothing while
    /// reporting success. Lives here because this type owns the bucket and
    /// mints the paths in the first place.
    static func storagePath(fromPublicUrl url: String) -> String? {
        guard let range = url.range(of: "/object/public/\(bucket)/")
        else { return nil }
        let raw = String(url[range.upperBound...])
        return raw.removingPercentEncoding ?? raw
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
