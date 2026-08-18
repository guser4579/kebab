//
//  CachedAsyncImage.swift
//  kebab
//

import CryptoKit
import ImageIO
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

    /// The ONE cost metric for this cache: the decoded bitmap footprint.
    /// Every insertion goes through here so the 64MB budget means what it
    /// says (JPEG byte counts undercounted real memory ~10x).
    static func insert(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        shared.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// Downsampled decoding via ImageIO: never materializes more pixels than the
/// cap (the 2048pt upload ceiling — entry images lose nothing, oversized
/// og:images stop costing ~16MB+ each). Pure function, safe off-main; call
/// it from a detached task so row decodes never touch the main thread.
nonisolated enum ImageDecode {
    static func downsampled(_ data: Data, maxPixel: CGFloat = 2048) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Disk layer under the memory cache: downloaded image bytes persist across
/// launches (in Caches, so the system may purge under pressure), keyed by a
/// hash of the URL. A cold launch renders yesterday's images from disk
/// instead of redownloading every visible row. Pure functions, safe off-main.
nonisolated enum ImageDiskCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kebab-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func fileURL(for remote: URL) -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    static func read(for remote: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: remote))
    }

    static func write(_ data: Data, for remote: URL) {
        try? data.write(to: fileURL(for: remote), options: .atomic)
    }

    /// Deletes every cached image byte. Called when a session definitively
    /// ends so one account's entry/avatar imagery cannot linger on disk into
    /// the next account (the memory cache and URLCache are cleared alongside).
    static func removeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// URLs that failed definitively this session (HTTP 4xx or undecodable
/// payload) — not re-requested on every row appearance. Session-scoped on
/// purpose: a relaunch retries everything, so a once-dead URL can recover.
/// Transient transport errors and 5xx responses are never recorded here.
enum ImageLoadFailures {
    static var urls: Set<URL> = []
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
        // Keyed to the CURRENT url, not "loaded once": a mounted instance
        // whose url changes (the menu profile card after an avatar replace)
        // must fetch the new image — the previous one stays visible until
        // the swap so the change never flashes through a blank frame.
        guard let url else {
            image = nil
            return
        }
        if let cached = ImageCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }
        if ImageLoadFailures.urls.contains(url) { return }

        // Local file (pending outbox images): plain read + downsampled decode
        // off-main. File URLs never produce HTTPURLResponse, so they must not
        // go through the network branch below.
        if url.isFileURL {
            let loaded = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: url)).flatMap { ImageDecode.downsampled($0) }
            }.value
            if let loaded {
                ImageCache.insert(loaded, for: url)
                image = loaded
            }
            return
        }

        // Disk layer: bytes fetched in an earlier session decode off-main —
        // a cold launch never redownloads what it already has.
        let diskLoaded = await Task.detached(priority: .userInitiated) {
            ImageDiskCache.read(for: url).flatMap { ImageDecode.downsampled($0) }
        }.value
        if Task.isCancelled { return }
        if let diskLoaded {
            ImageCache.insert(diskLoaded, for: url)
            image = diskLoaded
            return
        }

        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else {
                    // A definitive client-error answer (404 favicon, dead
                    // og:image) won't change this session; remember it.
                    // Server errors (5xx) stay retryable on a later appearance.
                    if let http = response as? HTTPURLResponse,
                       (400..<500).contains(http.statusCode) {
                        ImageLoadFailures.urls.insert(url)
                    }
                    return
                }
                // Decode off-main at the downsample cap; persist the original
                // bytes for future launches.
                let loaded = await Task.detached(priority: .userInitiated) {
                    ImageDecode.downsampled(data)
                }.value
                guard let loaded else {
                    // Undecodable payload won't improve on retry this session.
                    ImageLoadFailures.urls.insert(url)
                    return
                }
                Task.detached(priority: .utility) {
                    ImageDiskCache.write(data, for: url)
                }
                ImageCache.insert(loaded, for: url)
                image = loaded
                return
            } catch is CancellationError {
                // Fast scrolling cancels row tasks — not a failure, no retry.
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                    if Task.isCancelled { return }
                }
            }
        }
    }
}
