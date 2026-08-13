//
//  CachedAsyncImage.swift
//  kebab
//

import SwiftUI
import UIKit

/// In-memory image cache shared by all feed imagery. AsyncImage refetches
/// every time a lazy row recycles, which made link previews flicker in and
/// out of the feed; a cache makes an image load once and render instantly
/// forever after.
enum ImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
}

/// Drop-in AsyncImage replacement backed by ImageCache, with one retry on
/// transient network failure. Renders synchronously from cache when possible
/// (no placeholder flash on recycled rows).
struct CachedAsyncImage: View {

    let url: URL?
    var contentMode: ContentMode = .fill
    /// Show a spinner while loading (full-screen viewer); rows keep a quiet
    /// placeholder.
    var showsSpinner: Bool = false

    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill, showsSpinner: Bool = false) {
        self.url = url
        self.contentMode = contentMode
        self.showsSpinner = showsSpinner
        _image = State(initialValue: url.flatMap { ImageCache.shared.object(forKey: $0 as NSURL) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if showsSpinner {
                ProgressView()
                    .tint(Style.Color.secondary)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard image == nil, let url else { return }
        if let cached = ImageCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }

        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let loaded = UIImage(data: data)
                else { return }
                ImageCache.shared.setObject(loaded, forKey: url as NSURL, cost: data.count)
                image = loaded
                return
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
    }
}
