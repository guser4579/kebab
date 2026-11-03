//
//  AttachmentStorage.swift
//  kebab
//

import Foundation
import UIKit
import Supabase

/// Everything attachments keep in Supabase Storage, across two buckets.
///
/// **Images** live in the public `entry-images` bucket. Paths are unguessable —
/// `{userId}/{UUID}.jpg` — which is the privacy model for the public bucket:
/// objects are only reachable with the exact URL stored on the entry. Images
/// are resized to max 2048pt and JPEG-compressed before upload so a 48MP photo
/// doesn't burn user bandwidth or storage quota.
///
/// **File originals** live in the private `entry-files` bucket, because a
/// document can be far more sensitive than a photo. They're reached only through
/// short-lived signed URLs, created when the user opens one.
///
/// **File thumbnails** (a PDF's first page, a video's poster) deliberately go in
/// `entry-images`: the same privacy model photos already have, and they render
/// through `CachedAsyncImage` with no signed-URL churn on every feed row. The
/// trade-off is that a first page is reachable by anyone holding its unguessable
/// URL, while the document itself isn't.
final class AttachmentStorage {

    nonisolated static let imagesBucket = "entry-images"
    nonisolated static let filesBucket = "entry-files"
    /// How long a signed URL to an original lasts.
    nonisolated static let signedURLLifetime = 3600

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
                .from(Self.imagesBucket)
                .upload(path, data: data, options: FileOptions(contentType: "image/jpeg"))
            let url = try supabase.storage
                .from(Self.imagesBucket)
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

    // MARK: - Files

    /// Object paths derive from the staged file's id, so a retry after a dropped
    /// connection or a failed insert lands on the same objects rather than
    /// leaving orphans. Lowercased to match the RLS folder check: Swift renders
    /// UUIDs uppercase but Postgres's auth.uid()::text is lowercase.
    nonisolated static func filePath(fileId: UUID, name: String, userId: UUID) -> String {
        let cleaned = (name as NSString).pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let ext = cleaned.isEmpty ? "bin" : cleaned
        return "\(userId.uuidString.lowercased())/\(fileId.uuidString.lowercased()).\(ext)"
    }

    nonisolated static func thumbnailPath(fileId: UUID, userId: UUID) -> String {
        "\(userId.uuidString.lowercased())/\(fileId.uuidString.lowercased())-thumb.jpg"
    }

    /// Uploads a staged file (and its thumbnail) and returns its attachment.
    /// Safe to call again for the same file: objects that already landed on an
    /// earlier attempt count as uploaded.
    func uploadFile(_ file: PendingFile, fileURL: URL, thumbnailURL: URL?, userId: UUID) async throws -> EntryAttachment {
        let path = Self.filePath(fileId: file.id, name: file.name, userId: userId)
        try await upload(fileURL, to: Self.filesBucket, path: path, mime: file.mime)

        var thumbURL: String?
        if let thumbnailURL {
            let thumbPath = Self.thumbnailPath(fileId: file.id, userId: userId)
            try await upload(thumbnailURL, to: Self.imagesBucket, path: thumbPath, mime: "image/jpeg")
            thumbURL = try supabase.storage
                .from(Self.imagesBucket)
                .getPublicURL(path: thumbPath)
                .absoluteString
        }

        return EntryAttachment(
            type: "file",
            url: path,
            title: nil,
            favicon_url: nil,
            image_url: nil,
            file: FileMetadata(
                path: path,
                name: file.name,
                mime: file.mime,
                size: file.size,
                kind: file.kind.rawValue,
                thumb_url: thumbURL,
                duration: file.duration,
                page_count: file.pageCount
            )
        )
    }

    /// Streams from disk. The SDK's file-URL upload encodes the whole multipart
    /// body into memory first, and it has no resumable upload, so this posts the
    /// raw bytes itself with `upload(for:fromFile:)`. There's no resuming a
    /// dropped upload: the next flush sends it again to the same path.
    private func upload(_ fileURL: URL, to bucket: String, path: String, mime: String) async throws {
        let storage = supabase.storage.configuration
        var request = URLRequest(url: storage.url.appendingPathComponent("object/\(bucket)/\(path)"))
        request.httpMethod = "POST"
        for (field, value) in storage.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let token = try await supabase.auth.session.accessToken
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue("max-age=3600", forHTTPHeaderField: "Cache-Control")
        request.setValue("false", forHTTPHeaderField: "x-upsert")

        let (body, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !Self.uploadSucceeded(status: status, body: body) else { return }
        // Status only: the path carries the user id.
        throw NSError(
            domain: "AttachmentStorage",
            code: status,
            userInfo: [NSLocalizedDescriptionKey: "Upload failed with status \(status)."]
        )
    }

    /// A duplicate means an earlier attempt landed. Storage reports it either as
    /// a real 409 or as a 400 with `"statusCode":"409"` in the body, depending on
    /// the route.
    nonisolated static func uploadSucceeded(status: Int, body: Data) -> Bool {
        if (200..<300).contains(status) || status == 409 { return true }
        struct Failure: Decodable { let statusCode: String? }
        return (try? JSONDecoder().decode(Failure.self, from: body))?.statusCode == "409"
    }

    /// A fresh short-lived URL to an original. Only ever created when the user
    /// opens a file or plays a video, never at render time.
    func signedURL(forPath path: String) async throws -> URL {
        try await supabase.storage
            .from(Self.filesBucket)
            .createSignedURL(path: path, expiresIn: Self.signedURLLifetime)
    }

    // MARK: - Cleanup

    /// The objects a set of attachments owns, per bucket. Link preview images
    /// live on remote hosts, so `storagePath(fromPublicUrl:)` returns nil for
    /// them — nothing outside these buckets can be touched.
    nonisolated static func objectPaths(for attachments: [EntryAttachment]) -> (images: [String], files: [String]) {
        var images: [String] = []
        var files: [String] = []
        for attachment in attachments {
            switch attachment.attachmentType {
            case .image:
                if let path = storagePath(fromPublicUrl: attachment.url) { images.append(path) }
            case .file:
                guard let file = attachment.file else { continue }
                files.append(file.path)
                if let thumb = file.thumb_url, let path = storagePath(fromPublicUrl: thumb) {
                    images.append(path)
                }
            case .link, nil:
                continue
            }
        }
        return (images, files)
    }

    /// Physically removes the Storage objects behind a set of attachments. Call
    /// this ONLY once the database rows that referenced them are confirmed
    /// deleted — the bytes are the last copy, and a row that still exists must
    /// always resolve to a live object.
    ///
    /// Best-effort by design: the database is the source of truth, so a bucket
    /// failure here leaves an unreachable orphan rather than resurrecting content
    /// the user already deleted. Failures are logged, never thrown.
    func removeObjects(for attachments: [EntryAttachment]) async {
        let paths = Self.objectPaths(for: attachments)
        for path in paths.files {
            FileCache.shared.evict(path: path)
        }
        await remove(paths.images, from: Self.imagesBucket)
        await remove(paths.files, from: Self.filesBucket)
    }

    private func remove(_ paths: [String], from bucket: String) async {
        guard !paths.isEmpty else { return }
        do {
            // An entry carries a handful of attachments at most, so this is
            // always one small request — no batching needed (unlike the
            // account-wide purge).
            let removed = try await supabase.storage
                .from(bucket)
                .remove(paths: paths)
            // Storage answers 200 with a SHORT list (often empty) when RLS
            // filters the DELETE — the call "succeeds" while removing nothing.
            // Without this check, cleanup silently no-ops forever.
            if removed.count < paths.count {
                print("Attachment cleanup removed \(removed.count)/\(paths.count) object(s) — check the \(bucket) select+delete policies on storage.objects")
            }
        } catch {
            // Observable but harmless. Deliberately logs the count and the
            // transport error only — never entry content.
            print("Attachment cleanup failed for \(paths.count) object(s) in \(bucket):", error.localizedDescription)
        }
    }

    /// Extracts the in-bucket object path from a public URL
    /// (`…/object/public/entry-images/<path>`). The canonical way back from a
    /// stored attachment URL to the key Storage expects: `remove(paths:)` takes
    /// in-bucket paths, and handing it a public URL deletes nothing while
    /// reporting success. Lives here because this type owns the bucket and
    /// mints the paths in the first place.
    nonisolated static func storagePath(fromPublicUrl url: String) -> String? {
        guard let range = url.range(of: "/object/public/\(imagesBucket)/")
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
