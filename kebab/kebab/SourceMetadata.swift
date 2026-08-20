//
//  SourceMetadata.swift
//  kebab
//

import Foundation

/// Enrichment attached to a source, not to the entry.
///
/// A Kebab entry is unchanged by this feature: it still has user-authored
/// content, optional attachments, comments, collections and reminder state.
/// What gained a dimension is the *attachment* — a link may now carry a
/// resolved, Kebab-owned description of what it points at.
///
/// This envelope exists so the next rich source is a new `kind` and a new
/// payload field, not five more columns on `Entry`. It rides inside the
/// existing `attachments` jsonb, so no schema migration was required and every
/// previously stored attachment decodes unchanged (absent key → nil → the
/// generic link path, exactly as before).
nonisolated struct SourceMetadata: Codable, Sendable, Equatable {
    /// `SourceKind` raw value. Stored as a string so an unknown future kind
    /// written by a newer client degrades to "generic link" instead of failing
    /// to decode the whole entry.
    let kind: String
    /// `SourceStatus` raw value.
    let status: String
    /// When enrichment ran, ISO-8601. Provenance only — nothing refetches.
    let resolved_at: String?
    /// Present exactly when `kind == x_post` and `status == resolved`.
    let x_post: XPostSource?
    /// Server error code when `status == unavailable`, for support triage.
    let reason: String?

    init(
        kind: String,
        status: String,
        resolved_at: String? = nil,
        x_post: XPostSource? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.resolved_at = resolved_at
        self.x_post = x_post
        self.reason = reason
    }

    static func resolvedXPost(_ post: XPostSource, at date: Date = Date()) -> SourceMetadata {
        SourceMetadata(
            kind: SourceKind.xPost.rawValue,
            status: SourceStatus.resolved.rawValue,
            resolved_at: ISO8601.string(from: date),
            x_post: post
        )
    }

    /// A verdict, not a failure to record: this post is permanently not
    /// available to Kebab (deleted, protected, unsupported). Persisting it is
    /// what stops the app from ever asking X about this source again.
    static func unavailableXPost(reason: String, at date: Date = Date()) -> SourceMetadata {
        SourceMetadata(
            kind: SourceKind.xPost.rawValue,
            status: SourceStatus.unavailable.rawValue,
            resolved_at: ISO8601.string(from: date),
            reason: reason
        )
    }
}

nonisolated enum SourceKind: String, Sendable {
    case xPost = "x_post"
}

/// The persisted half of the enrichment lifecycle.
///
/// `unresolved` is the absence of a `SourceMetadata` and `loading` is transient
/// in-memory state, so neither is ever written. A transient failure also writes
/// nothing — it leaves the source unresolved and hands the retry to
/// `XEnrichmentQueue`, which is bounded. Only these two outcomes are durable.
nonisolated enum SourceStatus: String, Sendable {
    case resolved
    case unavailable
}

// MARK: - X post

/// A public X post as Kebab keeps it: the fields the native card renders, and
/// nothing else. No engagement metrics are requested, stored, or refreshed —
/// this is a preserved copy of what the user saved, not a live mirror.
nonisolated struct XPostSource: Codable, Sendable, Equatable {
    let post_id: String
    /// Canonical `https://x.com/{handle}/status/{id}`, built server-side from
    /// the authoritative author handle. This is what the card opens.
    let url: String
    /// Post text with t.co shortlinks resolved to their display form and the
    /// trailing media shortlink removed. Source content — never the user's.
    let text: String
    /// ISO-8601. Stored as a string so it round-trips identically through the
    /// Postgrest decoder and the LocalStore snapshot decoder, which use
    /// different date strategies.
    let created_at: String?
    let author: XPostAuthor
    let media: [XPostMedia]
    /// The first attached media type Kebab cannot render inline
    /// ("video", "animated_gif"), or nil when everything is a photo.
    let unsupported_media: String?

    var createdAtDate: Date? {
        created_at.flatMap(ISO8601.date(from:))
    }

    /// Photos, in author order — the only media rendered as images.
    var photos: [XPostMedia] {
        media.filter { $0.type == "photo" && $0.url != nil }
    }

    /// A still frame for a video/GIF post, when X supplied one. Shown as a
    /// non-playing preview that opens the post on X; v1 has no video player.
    var unsupportedPreviewURL: String? {
        guard unsupported_media != nil else { return nil }
        return media.first { $0.type != "photo" }?.preview_image_url
    }

    /// One line of searchable, imported source text. Deliberately separate
    /// from `Entry.content`, which is only ever what the user wrote.
    var searchableText: String {
        [text, author.name, "@" + author.username]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

nonisolated struct XPostAuthor: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let username: String
    let profile_image_url: String?
    let verified: Bool?
    let verified_type: String?

    var isVerified: Bool {
        if let verified { return verified }
        guard let verified_type else { return false }
        return verified_type != "none"
    }
}

nonisolated struct XPostMedia: Codable, Sendable, Equatable {
    let key: String
    /// "photo", "video", "animated_gif".
    let type: String
    /// Direct image URL — photos only.
    let url: String?
    let preview_image_url: String?
    let width: Int?
    let height: Int?
    let alt_text: String?

    /// Intrinsic aspect ratio when X reported dimensions, so the card reserves
    /// the right height before the image arrives and never snaps on load.
    var aspectRatio: CGFloat? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}

// MARK: - Applying enrichment to an attachment

extension EntryAttachment {

    /// The attachment as it looks once an X post resolved.
    ///
    /// Besides carrying the source, this fills the two generic link fields
    /// Kebab's non-card surfaces already read — `title` and `image_url` — with
    /// the post's own text and first photo. That is what makes an X entry show
    /// something meaningful in reminder notifications, search previews and the
    /// existing search index without any of those surfaces learning what an X
    /// post is. It never touches `Entry.content`: the post text stays source
    /// content, and the user's writing stays theirs.
    func enrichedWithXPost(_ post: XPostSource, at date: Date = Date()) -> EntryAttachment {
        EntryAttachment(
            type: type,
            url: url,
            title: post.text.isEmpty ? "@\(post.author.username)" : post.text,
            favicon_url: favicon_url,
            image_url: post.photos.first?.url ?? post.unsupportedPreviewURL ?? image_url,
            source: .resolvedXPost(post, at: date)
        )
    }

    /// The attachment as it looks once X gave a permanent verdict. Presentation
    /// is unchanged — the generic link card — but the recorded verdict is what
    /// keeps Kebab from ever asking about this source again.
    func markedSourceUnavailable(reason: String, at date: Date = Date()) -> EntryAttachment {
        withSource(.unavailableXPost(reason: reason, at: date))
    }
}

// MARK: - Timestamps

/// Shared ISO-8601 formatters. `ISO8601DateFormatter` is expensive to build and
/// these are read while rows render, so both variants are made once.
nonisolated enum ISO8601 {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        withFractional.date(from: string) ?? plain.date(from: string)
    }

    static func string(from date: Date) -> String {
        plain.string(from: date)
    }
}
