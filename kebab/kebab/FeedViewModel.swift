import Foundation
import Combine
import LinkPresentation
import Supabase

@MainActor
final class FeedViewModel: ObservableObject {

    @Published var entries: [Entry] = []
    @Published var isLoading: Bool = false
    @Published var hasCompletedInitialLoad: Bool = false
    @Published var errorMessage: String?

    var feedEntries: [Entry] {
        entries.filter { $0.pinned_at == nil }
    }

    var pinnedEntries: [Entry] {
        entries.filter { $0.pinned_at != nil }
               .sorted { $0.pinned_at! > $1.pinned_at! }
    }

    private let repository: EntryRepository
    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.repository = EntryRepository(supabase: supabase)
        self.supabase = supabase
    }

    func loadEntries() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasCompletedInitialLoad = true
        }

        do {
            entries = try await repository.fetchRootEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendEntry(content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let (cleanedContent, attachment) = Self.extractFirstLink(from: trimmed)

        errorMessage = nil
        do {
            let entryId = try await repository.insertEntry(
                content: cleanedContent,
                attachments: attachment.map { [$0] }
            )
            await loadEntries()

            if let attachment = attachment, attachment.title == nil {
                Task {
                    await self.enrichLinkMetadata(entryId: entryId, attachment: attachment)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func extractFirstLink(from text: String) -> (content: String, attachment: EntryAttachment?) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return (text, nil)
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: nsRange),
              let matchRange = Range(match.range, in: text),
              let url = match.url else {
            return (text, nil)
        }

        var cleaned = text
        cleaned.removeSubrange(matchRange)
        cleaned = cleaned.replacingOccurrences(of: "\\n([ \\t]*\\n)+", with: "\n", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        let attachment = EntryAttachment(
            type: "link",
            url: url.absoluteString,
            title: nil,
            favicon_url: nil,
            image_url: nil
        )

        return (cleaned, attachment)
    }

    private func enrichLinkMetadata(entryId: UUID, attachment: EntryAttachment) async {
        guard let url = URL(string: attachment.url) else { return }

        // Run title fetch and og:image extraction concurrently.
        // Title is required to proceed. Image is strictly best-effort and never blocks title persistence.
        async let fetchedTitle = fetchPageTitle(url: url)
        async let fetchedImageURL = fetchOGImageURL(url: url)

        let (title, imageURL) = await (fetchedTitle, fetchedImageURL)

        guard let title else { return }

        let enriched = EntryAttachment(
            type: attachment.type,
            url: attachment.url,
            title: title,
            favicon_url: attachment.favicon_url,
            image_url: imageURL
        )

        do {
            try await repository.updateAttachments(entryId: entryId, attachments: [enriched])
            // Patch only this entry in-memory rather than triggering a full feed reload.
            // A full reload is not safe to fire arbitrarily — it replaces the entire entries
            // array and can disrupt scroll position. Patching a single array element causes
            // SwiftUI to re-render only that row, which is safe and minimal.
            entries = entries.map { entry in
                entry.id == entryId ? entry.withAttachments([enriched]) : entry
            }
        } catch {
            // Silently ignore — entry keeps its current compact presentation.
        }
    }

    // MARK: - Metadata fetch helpers

    private func fetchPageTitle(url: URL) async -> String? {
        do {
            let provider = LPMetadataProvider()
            provider.timeout = 10
            let metadata = try await provider.startFetchingMetadata(for: url)
            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (title?.isEmpty == false) ? title : nil
        } catch {
            return nil
        }
    }

    /// Fetches page HTML and extracts the og:image or twitter:image URL.
    /// Returns nil on any network failure, parse failure, or timeout — never throws.
    private func fetchOGImageURL(url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            return extractOGImageURL(from: html, pageURL: url)
        } catch {
            return nil
        }
    }

    /// Scans HTML for the first <meta> tag that contains og:image (preferred) or
    /// twitter:image (fallback) and returns the resolved content attribute value.
    private func extractOGImageURL(from html: String, pageURL: URL) -> String? {
        var ogRaw: String? = nil
        var twitterRaw: String? = nil
        var searchStart = html.startIndex

        while let metaOpen = html.range(of: "<meta", options: .caseInsensitive, range: searchStart..<html.endIndex) {
            guard let tagClose = html.range(of: ">", range: metaOpen.upperBound..<html.endIndex) else {
                searchStart = metaOpen.upperBound
                continue
            }
            let tag = String(html[metaOpen.lowerBound..<tagClose.upperBound])

            if ogRaw == nil, tag.range(of: "og:image", options: .caseInsensitive) != nil {
                ogRaw = extractMetaContentValue(from: tag)
            } else if twitterRaw == nil, tag.range(of: "twitter:image", options: .caseInsensitive) != nil {
                twitterRaw = extractMetaContentValue(from: tag)
            }

            if ogRaw != nil && twitterRaw != nil { break }
            searchStart = tagClose.upperBound
        }

        guard let raw = ogRaw ?? twitterRaw else { return nil }
        return resolvedImageURL(raw, relativeTo: pageURL)
    }

    /// Extracts the value of the content="..." or content='...' attribute from a meta tag string.
    private func extractMetaContentValue(from tag: String) -> String? {
        for quote in ["\"", "'"] {
            let prefix = "content=\(quote)"
            let pattern = "\(prefix)([^\(quote)]*)\(quote)"
            if let range = tag.range(of: pattern, options: .regularExpression) {
                let value = String(String(tag[range]).dropFirst(prefix.count).dropLast(1))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Resolves a raw og:image string against the source page URL.
    /// Handles absolute URLs, protocol-relative URLs, root-relative paths, and relative paths.
    /// Returns nil for data URIs and unresolvable inputs.
    private func resolvedImageURL(_ raw: String, relativeTo pageURL: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.lowercased().hasPrefix("data:") else { return nil }

        // Protocol-relative: //cdn.example.com/img.jpg
        if trimmed.hasPrefix("//") {
            let scheme = pageURL.scheme ?? "https"
            return resolvedImageURL("\(scheme):\(trimmed)", relativeTo: pageURL)
        }

        // Already absolute with a scheme
        if let url = URL(string: trimmed), url.scheme != nil {
            return url.absoluteString
        }

        // Relative path — resolve against the page URL
        return URL(string: trimmed, relativeTo: pageURL)?.absoluteString
    }

    func deleteEntry(id: UUID) async {
        errorMessage = nil
        do {
            try await repository.deleteEntry(id: id)
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Persists new text for an entry/comment/reply. Patches the local entries array immediately
    /// so callers can defer any authoritative reload until their overlay is fully dismissed,
    /// avoiding scroll position disruption while the editor is still on screen.
    func updateEntryContent(id: UUID, content: String) async -> Bool {
        errorMessage = nil
        do {
            try await repository.updateEntryContent(id: id, content: content)
            entries = entries.map { $0.id == id ? $0.withContent(content) : $0 }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Toggles `is_content_hidden` on the given entry and reloads the feed.
    /// Returns `true` if the backend write succeeded, `false` on any error.
    /// Callers that display a local copy of the toggled entry should only patch
    /// their local state when this returns `true`.
    @discardableResult
    func toggleEntryHidden(id: UUID, currentValue: Bool) async -> Bool {
        do {
            try await supabase
                .from("entries")
                .update(["is_content_hidden": !currentValue])
                .eq("id", value: id)
                .execute()

            await loadEntries()
            return true
        } catch {
            print("Failed to toggle entry hidden state:", error)
            return false
        }
    }

    func resurfaceEntry(entry: Entry) async {
        guard entry.pinned_at == nil, entry.parent_id == nil else { return }
        do {
            try await repository.resurfaceEntry(id: entry.id)
            await loadEntries()
        } catch {
            print("Failed to resurface entry:", error)
        }
    }

    /// Increments `fire_count` by 1 with an immediate optimistic patch.
    /// On backend failure the patch is rolled back using the pre-tap value.
    /// Does NOT reload the feed or touch `feed_order_at` — no scroll or ordering side effects.
    @discardableResult
    func fireEntry(entry: Entry) async -> Bool {
        guard entry.parent_id == nil else { return false }
        entries = entries.map { $0.id == entry.id ? $0.withFireCount($0.fire_count + 1) : $0 }
        do {
            try await repository.fireEntry(id: entry.id)
            return true
        } catch {
            entries = entries.map { $0.id == entry.id ? $0.withFireCount(entry.fire_count) : $0 }
            print("Failed to fire entry:", error)
            return false
        }
    }

    func togglePin(entry: Entry) async {
        do {
            try await repository.togglePin(id: entry.id, pin: entry.pinned_at == nil)
            await loadEntries()
        } catch {
            print("Failed to toggle pin:", error)
        }
    }

    func loadComments(rootId: UUID) async -> [Entry] {
        do {
            return try await repository.fetchComments(rootId: rootId)
        } catch {
            return []
        }
    }

    func sendComment(content: String, parentId: UUID, rootId: UUID, depth: Int) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let session = try await supabase.auth.session
            try await repository.insertComment(
                userId: session.user.id,
                parentId: parentId,
                rootId: rootId,
                depth: depth,
                content: trimmed
            )
        } catch {
            print("Failed to send comment:", error)
        }
    }
}

// MARK: - Thread data derivation

struct ThreadData {
    private let childrenMap: [UUID: [Entry]]
    let totalCount: Int

    init(entries: [Entry]) {
        totalCount = entries.count
        var map: [UUID: [Entry]] = [:]
        for entry in entries {
            guard let parentId = entry.parent_id else { continue }
            map[parentId, default: []].append(entry)
        }
        for key in map.keys {
            map[key]?.sort { $0.created_at < $1.created_at }
        }
        childrenMap = map
    }

    func directChildren(of id: UUID) -> [Entry] {
        childrenMap[id] ?? []
    }

    func subtreeCount(for id: UUID) -> Int {
        let children = childrenMap[id] ?? []
        return children.reduce(children.count) { $0 + subtreeCount(for: $1.id) }
    }
}
