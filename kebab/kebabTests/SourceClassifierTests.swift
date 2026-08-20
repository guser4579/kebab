//
//  SourceClassifierTests.swift
//  kebabTests
//
//  Recognition is the load-bearing half of X support: a false positive sends
//  a profile or a search page down the enrichment path (and spends a billed X
//  read on nothing), while a false negative silently degrades a real post to a
//  bare link. These pin both directions.
//

import Foundation
import Testing
@testable import kebab

struct SourceClassifierTests {

    // MARK: - Accepted post URLs

    @Test(arguments: [
        "https://x.com/kebabapp/status/1234567890123456789",
        "https://www.x.com/kebabapp/status/1234567890123456789",
        "https://twitter.com/kebabapp/status/1234567890123456789",
        "https://www.twitter.com/kebabapp/status/1234567890123456789",
        "https://mobile.twitter.com/kebabapp/status/1234567890123456789",
        "https://m.x.com/kebabapp/status/1234567890123456789",
        "http://x.com/kebabapp/status/1234567890123456789",
        // Legacy plural path still in the wild.
        "https://twitter.com/kebabapp/statuses/1234567890123456789",
        // Share decoration.
        "https://x.com/kebabapp/status/1234567890123456789?s=20&t=abcDEF",
        "https://x.com/kebabapp/status/1234567890123456789?utm_source=newsletter",
        "https://x.com/kebabapp/status/1234567890123456789#anchor",
        // X's own per-media deep links.
        "https://x.com/kebabapp/status/1234567890123456789/photo/1",
        "https://x.com/kebabapp/status/1234567890123456789/video/1",
    ])
    func recognizesPostURLs(_ urlString: String) {
        let ref = SourceClassifier.xPostRef(from: urlString)
        #expect(ref?.postID == "1234567890123456789")
        #expect(ref?.username == "kebabapp")
    }

    @Test
    func normalizesLegacyTwitterURLToCanonicalXURL() {
        let ref = SourceClassifier.xPostRef(from: "https://twitter.com/kebabapp/status/1?s=46")
        #expect(ref?.canonicalURL == "https://x.com/kebabapp/status/1")
    }

    @Test
    func recognizesReservedRoutingFormsWithoutAHandle() {
        let web = SourceClassifier.xPostRef(from: "https://x.com/i/web/status/1234567890123456789")
        #expect(web?.postID == "1234567890123456789")
        #expect(web?.username == nil)

        // "i" is routing, never a real handle.
        let short = SourceClassifier.xPostRef(from: "https://x.com/i/status/1234567890123456789")
        #expect(short?.postID == "1234567890123456789")
        #expect(short?.username == nil)
        #expect(short?.canonicalURL == "https://x.com/i/web/status/1234567890123456789")
    }

    @Test
    func toleratesAMissingScheme() {
        #expect(SourceClassifier.xPostRef(from: "x.com/kebabapp/status/42")?.postID == "42")
        #expect(SourceClassifier.xPostRef(from: "  https://x.com/kebabapp/status/42  ")?.postID == "42")
    }

    // MARK: - Rejected X URLs

    @Test(arguments: [
        // Ordinary X surfaces that are emphatically not posts.
        "https://x.com/kebabapp",
        "https://x.com/kebabapp/with_replies",
        "https://x.com/kebabapp/media",
        "https://x.com",
        "https://x.com/",
        "https://x.com/home",
        "https://x.com/explore",
        "https://x.com/search?q=incentive%20alignment",
        "https://x.com/hashtag/design",
        "https://x.com/messages",
        "https://x.com/notifications",
        "https://x.com/i/spaces/1YpKkZWyQAvxj",
        "https://x.com/i/lists/12345",
        "https://x.com/compose/post",
        "https://twitter.com/settings/account",
        // Post-adjacent pages that are not the post.
        "https://x.com/kebabapp/status/1234567890/likes",
        "https://x.com/kebabapp/status/1234567890/retweets",
        "https://x.com/kebabapp/status/1234567890/analytics",
        // Malformed ids.
        "https://x.com/kebabapp/status/notanumber",
        "https://x.com/kebabapp/status/",
        "https://x.com/kebabapp/status/12345678901234567890123456789",
        // Invalid handle shape.
        "https://x.com/this-handle-is-way-too-long/status/1",
        "https://x.com/bad.handle/status/1",
    ])
    func rejectsNonPostXURLs(_ urlString: String) {
        #expect(SourceClassifier.xPostRef(from: urlString) == nil)
        #expect(SourceClassifier.source(of: urlString) == .generic)
    }

    // MARK: - Rejected hosts

    @Test(arguments: [
        "https://nytimes.com/kebabapp/status/1234567890",
        // Lookalike hosts must never match on a substring.
        "https://x.com.evil.example/kebabapp/status/1234567890",
        "https://notx.com/kebabapp/status/1234567890",
        "https://twitter.com.phish.example/kebabapp/status/1234567890",
        "https://fixupx.com/kebabapp/status/1234567890",
        "https://vxtwitter.com/kebabapp/status/1234567890",
        // Non-http schemes.
        "javascript:alert(1)//x.com/a/status/1",
        "ftp://x.com/kebabapp/status/1234567890",
        "",
        "   ",
        "not a url at all",
    ])
    func rejectsForeignAndMalformedHosts(_ urlString: String) {
        #expect(SourceClassifier.xPostRef(from: urlString) == nil)
        #expect(SourceClassifier.isXPostURL(urlString) == false)
    }

    @Test
    func ordinaryLinksStayGeneric() {
        #expect(SourceClassifier.source(of: "https://www.nytimes.com/2026/08/20/opinion/incentives.html") == .generic)
        #expect(SourceClassifier.source(of: "https://x.com/kebabapp") == .generic)
    }

    @Test
    func classifiesRecognizedPostsAsRichSources() {
        let source = SourceClassifier.source(of: "https://x.com/kebabapp/status/99?s=20")
        #expect(source == .xPost(SourceClassifier.XPostRef(postID: "99", username: "kebabapp")))
    }
}
