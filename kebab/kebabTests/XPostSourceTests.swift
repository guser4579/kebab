//
//  XPostSourceTests.swift
//  kebabTests
//
//  Persistence and fallback for rich sources. The invariants that matter:
//  every attachment written before this feature still decodes; a resolved post
//  survives the round trip through jsonb; and every failure mode lands back on
//  the generic link card rather than a broken X card.
//

import Foundation
import Testing
@testable import kebab

struct XPostSourceTests {

    // The Edge Function's success payload, verbatim.
    private static let resolvedJSON = """
    {
      "status": "resolved",
      "post": {
        "post_id": "1234567890123456789",
        "url": "https://x.com/kebabapp/status/1234567890123456789",
        "text": "Interesting framing of incentive alignment",
        "created_at": "2026-08-20T14:05:00.000Z",
        "author": {
          "id": "42",
          "name": "Kebab",
          "username": "kebabapp",
          "profile_image_url": "https://pbs.twimg.com/profile_images/1/avatar_400x400.jpg",
          "verified": true,
          "verified_type": "blue"
        },
        "media": [
          {
            "key": "3_1",
            "type": "photo",
            "url": "https://pbs.twimg.com/media/one.jpg",
            "preview_image_url": null,
            "width": 1200,
            "height": 800,
            "alt_text": "A chart"
          },
          {
            "key": "3_2",
            "type": "photo",
            "url": "https://pbs.twimg.com/media/two.jpg",
            "preview_image_url": null,
            "width": 900,
            "height": 900,
            "alt_text": null
          }
        ],
        "unsupported_media": null
      }
    }
    """

    private struct ResolveResponse: Decodable {
        let status: String
        let post: XPostSource?
    }

    private static func decodePost(_ json: String) throws -> XPostSource {
        let response = try JSONDecoder().decode(ResolveResponse.self, from: Data(json.utf8))
        return try #require(response.post)
    }

    private static func linkAttachment(url: String = "https://x.com/kebabapp/status/1234567890123456789") -> EntryAttachment {
        EntryAttachment(type: "link", url: url, title: nil, favicon_url: nil, image_url: nil)
    }

    // MARK: - Decoding the Edge Function response

    @Test
    func decodesResolvedPost() throws {
        let post = try Self.decodePost(Self.resolvedJSON)

        #expect(post.post_id == "1234567890123456789")
        #expect(post.url == "https://x.com/kebabapp/status/1234567890123456789")
        #expect(post.text == "Interesting framing of incentive alignment")
        #expect(post.author.username == "kebabapp")
        #expect(post.author.name == "Kebab")
        #expect(post.author.isVerified)
        #expect(post.media.count == 2)
        #expect(post.photos.count == 2)
        #expect(post.unsupported_media == nil)
        #expect(post.unsupportedPreviewURL == nil)

        var utc = DateComponents()
        utc.year = 2026; utc.month = 8; utc.day = 20; utc.hour = 14; utc.minute = 5
        utc.timeZone = TimeZone(identifier: "UTC")
        let expected = try #require(Calendar(identifier: .gregorian).date(from: utc))
        #expect(post.createdAtDate == expected)

        // Reported dimensions drive the media box, so a row's height is known
        // before any image loads.
        #expect(post.media[0].aspectRatio == 1.5)
        #expect(post.media[1].aspectRatio == 1.0)
    }

    @Test
    func decodesTextOnlyPost() throws {
        let post = try Self.decodePost("""
        {"status":"resolved","post":{
          "post_id":"1","url":"https://x.com/a/status/1","text":"No media here",
          "created_at":"2026-08-20T14:05:00.000Z",
          "author":{"id":"9","name":"A","username":"a","profile_image_url":null,
                    "verified":null,"verified_type":null},
          "media":[],"unsupported_media":null}}
        """)

        #expect(post.photos.isEmpty)
        #expect(post.author.isVerified == false)
        #expect(post.author.profile_image_url == nil)
    }

    @Test
    func recognizesUnsupportedMediaAndItsStillFrame() throws {
        let post = try Self.decodePost("""
        {"status":"resolved","post":{
          "post_id":"1","url":"https://x.com/a/status/1","text":"Clip",
          "created_at":"2026-08-20T14:05:00.000Z",
          "author":{"id":"9","name":"A","username":"a","profile_image_url":null,
                    "verified":false,"verified_type":"none"},
          "media":[{"key":"7_1","type":"video","url":null,
                    "preview_image_url":"https://pbs.twimg.com/ext_tw_video_thumb/still.jpg",
                    "width":1280,"height":720,"alt_text":null}],
          "unsupported_media":"video"}}
        """)

        // v1 renders the reliable half — text, author, still frame — and never
        // attempts playback.
        #expect(post.photos.isEmpty)
        #expect(post.unsupported_media == "video")
        #expect(post.unsupportedPreviewURL == "https://pbs.twimg.com/ext_tw_video_thumb/still.jpg")
    }

    @Test
    func decodesTimestampsWithoutFractionalSeconds() throws {
        let post = try Self.decodePost("""
        {"status":"resolved","post":{
          "post_id":"1","url":"https://x.com/a/status/1","text":"t",
          "created_at":"2026-08-20T14:05:00Z",
          "author":{"id":"9","name":"A","username":"a","profile_image_url":null,
                    "verified":null,"verified_type":null},
          "media":[],"unsupported_media":null}}
        """)
        #expect(post.createdAtDate != nil)
    }

    // MARK: - Backward compatibility

    @Test
    func attachmentsWrittenBeforeThisFeatureStillDecode() throws {
        // Exactly the shape already stored in `entries.attachments`.
        let legacy = """
        [
          {"type":"link","url":"https://www.nytimes.com/x.html","title":"A headline",
           "favicon_url":null,"image_url":"https://example.com/og.jpg"},
          {"type":"image","url":"https://example.com/photo.jpg","title":null,
           "favicon_url":null,"image_url":null}
        ]
        """
        let attachments = try JSONDecoder().decode([EntryAttachment].self, from: Data(legacy.utf8))

        #expect(attachments.count == 2)
        #expect(attachments[0].source == nil)
        #expect(attachments[0].isSourceSettled == false)
        #expect(attachments[0].xPostSource == nil)
        #expect(attachments[0].title == "A headline")
        #expect(attachments[1].attachmentType == .image)
    }

    @Test
    func unknownSourceKindsDegradeToTheGenericCard() throws {
        // A newer client writing a source this build has never heard of must
        // not break decoding, and must not render as an X card.
        let json = """
        {"type":"link","url":"https://example.com/a","title":"T","favicon_url":null,
         "image_url":null,
         "source":{"kind":"reddit_post","status":"resolved","resolved_at":null,
                   "x_post":null,"reason":null}}
        """
        let attachment = try JSONDecoder().decode(EntryAttachment.self, from: Data(json.utf8))
        #expect(attachment.xPostSource == nil)
        #expect(attachment.isSourceSettled)
    }

    // MARK: - Applying enrichment

    @Test
    func enrichmentAttachesTheSourceWithoutTouchingTheURL() throws {
        let post = try Self.decodePost(Self.resolvedJSON)
        let original = Self.linkAttachment(url: "https://twitter.com/kebabapp/status/1234567890123456789?s=20")
        let enriched = original.enrichedWithXPost(post)

        // The URL the user actually saved is preserved untouched; the
        // canonical form lives on the source.
        #expect(enriched.url == original.url)
        #expect(enriched.xPostSource?.url == "https://x.com/kebabapp/status/1234567890123456789")
        #expect(enriched.type == "link")
        #expect(enriched.isSourceSettled)

        // The generic fields non-card surfaces read (reminders, search
        // previews) are filled from the post, not from the user's writing.
        #expect(enriched.title == post.text)
        #expect(enriched.image_url == "https://pbs.twimg.com/media/one.jpg")
    }

    @Test
    func enrichmentSurvivesAJSONRoundTrip() throws {
        let post = try Self.decodePost(Self.resolvedJSON)
        let enriched = Self.linkAttachment().enrichedWithXPost(post)

        let data = try JSONEncoder().encode([enriched])
        let restored = try JSONDecoder().decode([EntryAttachment].self, from: data)

        #expect(restored.first == enriched)
        #expect(restored.first?.xPostSource == post)
    }

    @Test
    func userTextAndImportedPostTextStaySeparate() throws {
        let post = try Self.decodePost(Self.resolvedJSON)
        let userText = "Worth revisiting when we redo pricing"
        let entry = Self.entry(content: userText, attachments: [Self.linkAttachment().enrichedWithXPost(post)])

        #expect(entry.content == userText)
        #expect(entry.content.contains(post.text) == false)
        #expect(entry.xPostSource?.text == post.text)
        // Both are searchable, from two different places in the model.
        #expect(post.searchableText.contains(post.text))
        #expect(post.searchableText.contains("@kebabapp"))
    }

    // MARK: - Fallback

    @Test
    func permanentFailuresKeepAValidGenericLinkEntry() {
        let attachment = Self.linkAttachment().markedSourceUnavailable(reason: "not_found")
        let entry = Self.entry(content: "", attachments: [attachment])

        // No X card...
        #expect(entry.xPostSource == nil)
        // ...but still a perfectly ordinary link entry.
        #expect(entry.linkAttachment?.url == "https://x.com/kebabapp/status/1234567890123456789")
        #expect(entry.linkAttachment?.attachmentType == .link)
        // ...and a recorded verdict, which is what stops Kebab re-asking X.
        #expect(attachment.isSourceSettled)
        #expect(attachment.source?.reason == "not_found")
        #expect(attachment.source?.status == SourceStatus.unavailable.rawValue)
    }

    @Test
    func transientFailuresLeaveTheSourceUnresolved() {
        // Nothing is written for a retryable failure — an unsettled source is
        // exactly what makes a later bounded attempt legitimate.
        let attachment = Self.linkAttachment()
        #expect(attachment.isSourceSettled == false)
        #expect(attachment.xPostSource == nil)
    }

    @Test
    func enrichmentNeverDisturbsSiblingImageAttachments() throws {
        let post = try Self.decodePost(Self.resolvedJSON)
        let image = EntryAttachment(
            type: "image", url: "https://example.com/mine.jpg",
            title: nil, favicon_url: nil, image_url: nil
        )
        let link = Self.linkAttachment()
        let enriched = link.enrichedWithXPost(post)

        // The same match rule FeedViewModel uses to splice the result back in.
        let updated = [image, link].map { existing in
            (existing.attachmentType == .link && existing.url == enriched.url) ? enriched : existing
        }

        #expect(updated.count == 2)
        #expect(updated[0] == image)
        #expect(updated[1].xPostSource == post)
    }

    // MARK: - Bounded retry

    @Test
    func retryQueueStopsAtTheAttemptCeiling() {
        let userId = UUID()
        let entryId = UUID()
        let url = "https://x.com/kebabapp/status/1234567890123456789"

        for _ in 0..<(XEnrichmentQueue.maxAttempts - 1) {
            XEnrichmentQueue.recordAttempt(
                entryId: entryId, postID: "1234567890123456789", sourceURL: url, userId: userId
            )
        }
        #expect(XEnrichmentQueue.load(userId: userId).count == 1)
        #expect(XEnrichmentQueue.load(userId: userId).first?.attempts == XEnrichmentQueue.maxAttempts - 1)

        // The attempt that reaches the ceiling drops the item for good: a
        // source that never resolves must never keep asking.
        XEnrichmentQueue.recordAttempt(
            entryId: entryId, postID: "1234567890123456789", sourceURL: url, userId: userId
        )
        #expect(XEnrichmentQueue.load(userId: userId).isEmpty)
    }

    @Test
    func retryQueueDropsSettledSources() {
        let userId = UUID()
        let entryId = UUID()
        XEnrichmentQueue.recordAttempt(
            entryId: entryId, postID: "1", sourceURL: "https://x.com/a/status/1", userId: userId
        )
        #expect(XEnrichmentQueue.load(userId: userId).count == 1)

        XEnrichmentQueue.remove(entryId: entryId, userId: userId)
        #expect(XEnrichmentQueue.load(userId: userId).isEmpty)
    }

    // MARK: - Fixtures

    private static func entry(content: String, attachments: [EntryAttachment]) -> Entry {
        Entry(
            id: UUID(),
            user_id: UUID(),
            parent_id: nil,
            root_id: nil,
            depth: 0,
            content: content,
            created_at: Date(),
            pinned_at: nil,
            isContentHidden: false,
            comment_count: nil,
            resurface_count: 0,
            fire_count: 0,
            attachments: attachments,
            collection_id: nil,
            collection_name: nil,
            collection_parent_id: nil,
            collection_parent_name: nil
        )
    }
}
