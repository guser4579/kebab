//
//  LinkFavicon.swift
//  kebab
//

import SwiftUI
import UIKit

/// The single icon slot for a URL: the site's favicon when one resolves,
/// the caller's generic link glyph otherwise. Exactly one of the two ever
/// renders — the glyph is strictly a fallback, never an underlay, so a
/// favicon with transparency can't show glyph strokes bleeding through.
///
/// Call sites keep the slot's outer frame constant across both states so
/// neighboring text never shifts when a favicon arrives.
struct LinkFavicon<Fallback: View>: View {

    let faviconURL: URL?
    /// Rendered favicon square, matching the sizes the favicon previously
    /// drew at (16pt chips, 14pt search teaser).
    let size: CGFloat
    @ViewBuilder let fallback: () -> Fallback

    @State private var favicon: UIImage?

    init(faviconURL: URL?, size: CGFloat, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.faviconURL = faviconURL
        self.size = size
        self.fallback = fallback
        // Synchronous cache seed, same as CachedAsyncImage: a recycled row
        // renders its favicon on the first frame instead of flashing the
        // glyph and swapping.
        _favicon = State(initialValue: faviconURL.flatMap { ImageCache.shared.object(forKey: $0 as NSURL) })
    }

    var body: some View {
        Group {
            if let favicon {
                Image(uiImage: favicon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                fallback()
            }
        }
        .task(id: faviconURL) {
            // Keyed to the CURRENT url (a cache hit resolves instantly, so
            // re-running after the synchronous seed costs nothing): if the
            // url changes or resolution fails, the slot falls back to the
            // glyph rather than keeping a stale favicon.
            guard let faviconURL else {
                favicon = nil
                return
            }
            favicon = await CachedAsyncImage.fetch(faviconURL)
        }
    }
}
