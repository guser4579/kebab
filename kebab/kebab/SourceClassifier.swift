//
//  SourceClassifier.swift
//  kebab
//

import Foundation

/// The one place that decides what KIND of thing an attached source URL points
/// at. Every surface that needs to know "is this an X post?" asks here rather
/// than comparing host strings inline, so the recognition rules have a single
/// definition and a single test suite.
///
/// Today it recognizes exactly one rich source (a public X post); everything
/// else is a generic link and keeps Kebab's existing preview treatment.
/// Adding a source later means adding a case here, not a branch in the UI.
///
/// The rules deliberately mirror `supabase/functions/x-post/index.ts`, which
/// re-validates server-side — the client's classification is an optimization
/// and a routing decision, never the authority.
nonisolated enum SourceClassifier {

    /// A recognized public X post: enough to ask the server for it, and enough
    /// to name it before the server answers.
    struct XPostRef: Equatable, Sendable {
        let postID: String
        /// nil for `/i/web/status/…` links and the reserved `i` handle — the
        /// resolved post carries the authoritative author handle.
        let username: String?

        /// Provisional canonical form, used only before enrichment resolves.
        /// After enrichment `XPostSource.url` (built from the API's author) is
        /// the canonical URL the card opens.
        var canonicalURL: String {
            guard let username else {
                return "https://x.com/i/web/status/\(postID)"
            }
            return "https://x.com/\(username)/status/\(postID)"
        }
    }

    /// What Kebab knows how to enrich. `generic` is the existing link path.
    enum Source: Equatable, Sendable {
        case xPost(XPostRef)
        case generic
    }

    private static let xHosts: Set<String> = [
        "x.com",
        "www.x.com",
        "mobile.x.com",
        "m.x.com",
        "twitter.com",
        "www.twitter.com",
        "mobile.twitter.com",
        "m.twitter.com",
    ]

    /// Only X's own per-media deep links may trail a post id. `/likes`,
    /// `/retweets`, `/analytics`, `/with_replies` and friends are not posts.
    private static let mediaSuffixes: Set<String> = ["photo", "video", "gif"]

    static func source(of urlString: String) -> Source {
        if let ref = xPostRef(from: urlString) { return .xPost(ref) }
        return .generic
    }

    static func isXPostURL(_ urlString: String) -> Bool {
        xPostRef(from: urlString) != nil
    }

    /// Extracts a post reference from any accepted X post URL shape, or nil for
    /// every other X URL (profiles, home, search, explore, lists, Spaces,
    /// messages, hashtags) and every non-X URL.
    ///
    /// Query and fragment are share decoration (`?s=20&t=…`, `?utm_source=…`)
    /// and are always dropped.
    static func xPostRef(from urlString: String) -> XPostRef? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Attachments always carry a scheme; tolerate a bare host anyway so a
        // hand-typed "x.com/user/status/1" still classifies.
        var components = URLComponents(string: trimmed)
        if components?.scheme == nil {
            components = URLComponents(string: "https://" + trimmed)
        }
        guard let components else { return nil }

        switch components.scheme?.lowercased() {
        case "https", "http": break
        default: return nil
        }

        guard let host = components.host?.lowercased(), xHosts.contains(host) else { return nil }

        let parts = components.path.split(separator: "/").map(String.init)

        let idIndex: Int
        var username: String?

        if parts.count >= 4,
           parts[0].lowercased() == "i",
           parts[1].lowercased() == "web",
           isStatusSegment(parts[2]) {
            idIndex = 3
        } else if parts.count >= 3, isStatusSegment(parts[1]) {
            guard isValidUsername(parts[0]) else { return nil }
            // "i" is reserved routing, never a real handle.
            username = parts[0].lowercased() == "i" ? nil : parts[0]
            idIndex = 2
        } else {
            return nil
        }

        let postID = parts[idIndex]
        guard isValidPostID(postID) else { return nil }

        let trailing = parts.dropFirst(idIndex + 1)
        if !trailing.isEmpty {
            guard trailing.count == 2,
                  let first = trailing.first,
                  mediaSuffixes.contains(first.lowercased()),
                  let index = trailing.last,
                  index.count <= 2,
                  index.allSatisfy(\.isNumber)
            else { return nil }
        }

        return XPostRef(postID: postID, username: username)
    }

    // MARK: - Segment rules

    private static func isStatusSegment(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        return lower == "status" || lower == "statuses"
    }

    private static func isValidUsername(_ segment: String) -> Bool {
        guard (1...15).contains(segment.count) else { return false }
        return segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private static func isValidPostID(_ segment: String) -> Bool {
        guard (1...25).contains(segment.count) else { return false }
        return segment.allSatisfy(\.isNumber) && segment.allSatisfy(\.isASCII)
    }
}
