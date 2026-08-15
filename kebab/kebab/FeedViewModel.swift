import Foundation
import Combine
import LinkPresentation
import Supabase
import UIKit
import Network

/// Collection fields needed to render an entry's breadcrumb locally —
/// resolved from the collections model instead of a server round-trip.
struct CollectionDisplayInfo {
    let name: String
    let parentId: UUID?
    let parentName: String?
}

@MainActor
final class FeedViewModel: ObservableObject {

    @Published var entries: [Entry] = []
    @Published var isLoading: Bool = false
    @Published var hasCompletedInitialLoad: Bool = false
    @Published var errorMessage: String?
    /// Entries composed on-device that haven't reached the server yet.
    @Published var pendingEntries: [PendingEntry] = []
    /// Independent toggle; combines with any collection filter.
    @Published var hasLinkFilterActive: Bool = false
    /// Single-select collection scope. Also drives composer targeting: while
    /// active, new entries are added to `targetCollectionId`.
    @Published var activeCollectionFilter: CollectionFilter?
    /// Resolves a collection id to display info (name + parent). Set by the
    /// owner from the collections model so pending and freshly promoted
    /// entries render breadcrumbs and match aggregate filters without a
    /// server round-trip.
    var collectionInfoResolver: ((UUID) -> CollectionDisplayInfo?)?

    var feedEntries: [Entry] {
        entries.filter { $0.pinned_at == nil }
    }

    var pinnedEntries: [Entry] {
        entries.filter { $0.pinned_at != nil }
               .sorted { $0.pinned_at! > $1.pinned_at! }
    }

    /// Feed entries with active filters applied, followed by any not-yet-synced
    /// pending entries. Views should consume this instead of feedEntries.
    var filteredFeedEntries: [Entry] {
        var result = feedEntries
        if hasLinkFilterActive {
            result = result.filter { $0.linkAttachment != nil }
        }
        switch activeCollectionFilter {
        case .all(let parentId):
            result = result.filter {
                $0.collection_id == parentId || $0.collection_parent_id == parentId
            }
        case .single(let id):
            result = result.filter { $0.collection_id == id }
        case nil:
            break
        }

        let pendingDisplay = pendingEntries.compactMap { pending -> Entry? in
            // Pending entries have no parsed link yet.
            if hasLinkFilterActive { return nil }
            switch activeCollectionFilter {
            case .all(let parentId):
                // Match the parent itself or any of its sub-collections, same
                // as the aggregate filter on synced entries above.
                let pendingParentId = pending.collectionId.flatMap { collectionInfoResolver?($0)?.parentId }
                guard pending.collectionId == parentId || pendingParentId == parentId else { return nil }
            case .single(let id):
                guard pending.collectionId == id else { return nil }
            case nil:
                break
            }
            return displayEntry(for: pending)
        }
        return result + pendingDisplay
    }

    /// Combined count the feed's scroll logic watches — pending entries are
    /// part of the visible list.
    var totalDisplayCount: Int {
        entries.count + pendingEntries.count
    }

    /// Maps an outbox item to a display-only Entry, with file:// image
    /// attachments so offline photos render at full parity.
    private func displayEntry(for pending: PendingEntry) -> Entry {
        var imageAttachments = pending.imageFilenames.map { filename in
            EntryAttachment(
                type: "image",
                url: outbox.imageURL(for: filename).absoluteString,
                title: nil,
                favicon_url: nil,
                image_url: nil
            )
        }
        // Staged link renders as a link card from the first frame, matching
        // the promoted form.
        if let stagedURL = pending.linkURL {
            imageAttachments.append(EntryAttachment(
                type: "link",
                url: stagedURL,
                title: nil,
                favicon_url: nil,
                image_url: nil
            ))
        }
        let info = pending.collectionId.flatMap { collectionInfoResolver?($0) }
        return Entry(
            id: pending.id,
            user_id: entries.first?.user_id ?? pending.id,
            parent_id: nil,
            root_id: nil,
            depth: 0,
            content: pending.content,
            created_at: pending.createdAt,
            pinned_at: nil,
            isContentHidden: false,
            comment_count: nil,
            resurface_count: 0,
            fire_count: 0,
            attachments: imageAttachments.isEmpty ? nil : imageAttachments,
            collection_id: pending.collectionId,
            collection_name: info?.name,
            collection_parent_id: info?.parentId,
            collection_parent_name: info?.parentName,
            isPending: true,
            pendingFailed: pending.failed
        )
    }

    /// Sets the collection filter, or clears it when `filter` is already active.
    func toggleCollectionFilter(_ filter: CollectionFilter) {
        activeCollectionFilter = (activeCollectionFilter == filter) ? nil : filter
    }

    private let repository: EntryRepository
    private let collectionRepository: CollectionRepository
    private let imageStorage: ImageStorageRepository
    private let supabase: SupabaseClient
    private let outbox = OutboxStore()
    private let pathMonitor = NWPathMonitor()
    private var isFlushing = false

    init(supabase: SupabaseClient) {
        self.repository = EntryRepository(supabase: supabase)
        self.collectionRepository = CollectionRepository(supabase: supabase)
        self.imageStorage = ImageStorageRepository(supabase: supabase)
        self.supabase = supabase

        // Offline read layer: open instantly on the last-known feed.
        entries = LocalStore.load([Entry].self, from: "feed") ?? []
        hasCompletedInitialLoad = !entries.isEmpty
        pendingEntries = outbox.loadAll()

        // Flush the outbox whenever connectivity (re)appears — including the
        // initial callback at launch, which drains anything left over from a
        // previous session.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                await self?.flushOutbox()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "kebab.connectivity"))
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
            LocalStore.save(entries, as: "feed")
        } catch {
            // Offline or failed refresh: keep showing the cached feed.
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Send (queue-then-flush)

    /// Stages the entry in the on-disk outbox and kicks a sync. The send
    /// always succeeds locally — the entry appears in the feed immediately
    /// with a pending mark, and delivery happens whenever connectivity
    /// allows. Returns the entry's stable client-generated id (the same id
    /// it keeps after promotion, so post-capture actions can target it), or
    /// nil only if the outbox itself can't write (disk full), in which case
    /// the caller restores the draft.
    @discardableResult
    func queueEntry(
        content: String,
        images: [UIImage] = [],
        linkURL: URL? = nil,
        collectionId: UUID? = nil
    ) -> UUID? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty || linkURL != nil else { return nil }

        do {
            let pending = try outbox.enqueue(
                content: trimmed,
                images: images,
                linkURL: linkURL?.absoluteString,
                collectionId: collectionId
            )
            pendingEntries.append(pending)
            Haptics.mediumTap()
            kickFlush()
            return pending.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func kickFlush() {
        Task { await flushOutbox() }
    }

    /// Drains the outbox oldest-first. Transport errors (offline) stop the
    /// pass — the path monitor retries later. Server rejections count against
    /// the entry; after repeated rejections it's marked failed and surfaces
    /// the warning state instead of silently retrying forever.
    ///
    /// Reconciliation is promote-in-place: on successful persistence the
    /// pending entry becomes a regular entry in the same state update, so the
    /// rendered row keeps its identity and position — the user never sees the
    /// local entry disappear and the database entry reappear.
    func flushOutbox() async {
        guard !isFlushing, pendingEntries.contains(where: { !$0.failed }) else { return }
        isFlushing = true
        defer { isFlushing = false }

        for pending in pendingEntries.filter({ !$0.failed }) {
            do {
                var attachments: [EntryAttachment] = []
                let images = outbox.loadImages(for: pending)
                let session = try await supabase.auth.session
                if !images.isEmpty {
                    let uploaded = try await imageStorage.uploadImages(images, userId: session.user.id)
                    // Seed the shared image cache so the promoted row renders
                    // the uploaded URLs straight from memory — the
                    // file:// → https:// swap never shows a placeholder.
                    for (image, attachment) in zip(images, uploaded) {
                        if let url = URL(string: attachment.url) {
                            let cost = Int(image.size.width * image.size.height
                                * image.scale * image.scale * 4)
                            ImageCache.shared.setObject(image, forKey: url as NSURL, cost: cost)
                        }
                    }
                    attachments += uploaded
                }
                // An explicitly staged link (composer chip) takes precedence
                // and leaves the text untouched; otherwise fall back to
                // detecting a typed URL in the text, as before.
                let cleanedContent: String
                let link: EntryAttachment?
                if let stagedURL = pending.linkURL {
                    cleanedContent = pending.content
                    link = EntryAttachment(
                        type: "link",
                        url: stagedURL,
                        title: nil,
                        favicon_url: nil,
                        image_url: nil
                    )
                } else {
                    (cleanedContent, link) = Self.extractFirstLink(from: pending.content)
                }
                if let link {
                    attachments.append(link)
                }

                do {
                    try await repository.insertEntry(
                        id: pending.id,
                        content: cleanedContent,
                        attachments: attachments.isEmpty ? nil : attachments
                    )
                } catch where Self.isDuplicateKey(error) {
                    // A previous attempt landed before we could confirm it —
                    // the client-generated id makes this safely idempotent.
                }

                var filedCollectionId: UUID?
                if let collectionId = pending.collectionId {
                    if (try? await collectionRepository.addEntryToCollection(
                        entryId: pending.id,
                        collectionId: collectionId
                    )) != nil {
                        filedCollectionId = collectionId
                    }
                }

                if let link, link.title == nil {
                    let allAttachments = attachments
                    let entryId = pending.id
                    Task {
                        await self.enrichLinkMetadata(
                            entryId: entryId,
                            attachment: link,
                            existingAttachments: allAttachments
                        )
                    }
                }

                // Promote atomically: append the persisted form and drop the
                // pending form in the same run-loop tick. Same id ⇒ SwiftUI
                // keeps the row's identity ⇒ no blink, no scroll shift.
                let info = filedCollectionId.flatMap { collectionInfoResolver?($0) }
                let promoted = Entry(
                    id: pending.id,
                    user_id: entries.first?.user_id ?? session.user.id,
                    parent_id: nil,
                    root_id: nil,
                    depth: 0,
                    content: cleanedContent,
                    created_at: pending.createdAt,
                    pinned_at: nil,
                    isContentHidden: false,
                    comment_count: nil,
                    resurface_count: 0,
                    fire_count: 0,
                    attachments: attachments.isEmpty ? nil : attachments,
                    collection_id: filedCollectionId,
                    collection_name: info?.name,
                    collection_parent_id: info?.parentId,
                    collection_parent_name: info?.parentName
                )
                entries.append(promoted)
                pendingEntries.removeAll { $0.id == pending.id }
                LocalStore.save(entries, as: "feed")
                outbox.remove(pending)
            } catch let error as URLError {
                // Offline / transport failure: stop the whole pass quietly.
                _ = error
                break
            } catch {
                var updated = pending
                updated.attempts += 1
                if updated.attempts >= 3 {
                    updated.failed = true
                }
                outbox.update(updated)
                pendingEntries = pendingEntries.map { $0.id == updated.id ? updated : $0 }
            }
        }
    }

    /// Clears the failure state and tries again (user tapped "Try again").
    func retryPending(id: UUID) {
        guard var pending = pendingEntries.first(where: { $0.id == id }) else { return }
        pending.attempts = 0
        pending.failed = false
        outbox.update(pending)
        pendingEntries = pendingEntries.map { $0.id == id ? pending : $0 }
        kickFlush()
    }

    /// Removes a queued entry entirely (user tapped "Discard").
    func discardPending(id: UUID) {
        guard let pending = pendingEntries.first(where: { $0.id == id }) else { return }
        outbox.remove(pending)
        pendingEntries.removeAll { $0.id == id }
    }

    private static func isDuplicateKey(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
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
        // Extend the removal range forward past any non-whitespace characters.
        // NSDataDetector can stop before certain characters (e.g. '|', '{') in long
        // tracked URLs, which would leave a querystring tail fragment as bare text.
        var extendedEnd = matchRange.upperBound
        while extendedEnd < text.endIndex, !text[extendedEnd].isWhitespace {
            extendedEnd = text.index(after: extendedEnd)
        }
        cleaned.removeSubrange(matchRange.lowerBound..<extendedEnd)
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

    private func enrichLinkMetadata(
        entryId: UUID,
        attachment: EntryAttachment,
        existingAttachments: [EntryAttachment]
    ) async {
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

        // Replace only the link element — image attachments on the same entry
        // must survive enrichment.
        let updated = existingAttachments.map { existing in
            (existing.attachmentType == .link && existing.url == attachment.url) ? enriched : existing
        }

        do {
            try await repository.updateAttachments(entryId: entryId, attachments: updated)
            // Patch only this entry in-memory rather than triggering a full feed reload.
            // A full reload is not safe to fire arbitrarily — it replaces the entire entries
            // array and can disrupt scroll position. Patching a single array element causes
            // SwiftUI to re-render only that row, which is safe and minimal.
            entries = entries.map { entry in
                entry.id == entryId ? entry.withAttachments(updated) : entry
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
            Haptics.destructiveTap()
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

    /// Toggles the checklist line at `lineIndex` with an immediate optimistic
    /// patch (checkbox taps must feel instant from the feed); rolls back if
    /// the server write fails. No reload — only the one row re-renders.
    func toggleChecklistItem(entry: Entry, lineIndex: Int) async {
        let newContent = Checklist.toggling(entry.content, lineIndex: lineIndex)
        guard newContent != entry.content else { return }
        entries = entries.map { $0.id == entry.id ? $0.withContent(newContent) : $0 }
        Haptics.lightTap()
        do {
            try await repository.updateEntryContent(id: entry.id, content: newContent)
            LocalStore.save(entries, as: "feed")
        } catch {
            entries = entries.map { $0.id == entry.id ? $0.withContent(entry.content) : $0 }
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

            Haptics.lightTap()
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
            Haptics.lightTap()
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
        Haptics.lightTap()
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
            Haptics.lightTap()
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
            Haptics.mediumTap()
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
