//
//  SourceCardView.swift
//  kebab
//

import SwiftUI

/// Renders an entry's attached source in whatever form Kebab knows it.
///
/// The single place the "which card?" question is answered, so the feed row and
/// the entry detail screen can never drift apart, and the next rich source is a
/// new branch here rather than a new branch in every host.
///
/// The default remains the generic link preview: an attachment only leaves that
/// path once enrichment has actually resolved it. Every failure mode — not yet
/// enriched, permanently unavailable, a source kind this build doesn't know —
/// lands back on `RichLinkCardView`, unchanged.
struct SourceCardView: View {

    let attachment: EntryAttachment
    /// Feed rows split their tap targets so a link-only entry stays easy to
    /// open; see `RichLinkCardView`. The X card always splits them, so this
    /// only affects the generic path.
    var footerOnlyOpensLink: Bool = false

    var body: some View {
        if let post = attachment.xPostSource {
            XPostCardView(post: post)
        } else {
            RichLinkCardView(
                urlString: attachment.url,
                title: attachment.title,
                imageURL: attachment.image_url,
                footerOnlyOpensLink: footerOnlyOpensLink
            )
        }
    }
}
