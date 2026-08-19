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

    @Published var errorMessage: String?
    /// Entries composed on-device that haven't reached the server yet.
    @Published var pendingEntries: [PendingEntry] = []
    /// Single-select collection scope. Also drives composer targeting: while
    /// active, new entries are added to `targetCollectionId`.
    @Published var activeCollectionFilter: CollectionFilter?
    /// Resolves a collection id to display info (name + parent). Set by the
    /// owner from the collections model so pending and freshly promoted
    /// entries render breadcrumbs and match aggregate filters without a
    /// server round-trip.
    var collectionInfoResolver: ((UUID) -> CollectionDisplayInfo?)?
    /// Fired when an outbox entry is promoted to a server row, so the paged
    /// All store can adopt it without a reload.
    var onEntryPromoted: ((Entry) -> Void)?
    /// Fired with the freshly patched entry after any optimistic mutation
    /// (checklist, fire, resurface, edit, enrichment, hidden toggle, comment
    /// count, membership) — the owner reconciles it into every warm scope
    /// store and the search corpus. This replaced the retired whole-corpus
    /// mirror's lookup-based fan-out.
    var onEntryChanged: ((Entry) -> Void)?
    /// Fired when content changed for something no warm store holds (a
    /// comment, or a root beyond the loaded pages) — the owner marks the
    /// search corpus stale so its next look refetches.
    var onCommentContentChanged: (() -> Void)?
    /// Fired when a delete is confirmed by the server, whichever screen
    /// initiated it, so every warm scope store drops (and tombstones) the row.
    var onEntryDeleted: ((UUID) -> Void)?
    /// Resolves the freshest warm copy of an entry (scope stores + arrival
    /// buffers). Optimistic patches are computed against this truth; a miss
    /// means nothing on any warm surface renders the entry.
    var entryResolver: ((UUID) -> Entry?)?
    /// Resolves a thread from purely local state (warm scopes + the on-device
    /// corpus mirror). Detail screens call this from `init`, so the correct
    /// thread geometry exists in the FIRST rendered frame instead of arriving
    /// with the network. Never performs I/O.
    var localThreadResolver: ((UUID) -> LocalThread)?

    /// Everything a detail screen needs to lay out a thread before it appears.
    struct LocalThread {
        let root: Entry?
        let comments: [Entry]
        static let empty = LocalThread(root: nil, comments: [])
    }

    /// True when two thread snapshots carry the same rows, ignoring fetch
    /// order. Lets a refresh that changed nothing skip rebuilding presentation
    /// state, so a normal open → refresh never reconstructs the screen.
    static func isSameThread(_ a: [Entry], _ b: [Entry]) -> Bool {
        guard a.count == b.count else { return false }
        return a.sorted { $0.id.uuidString < $1.id.uuidString }
            == b.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Synchronous, allocation-cheap local thread lookup. Returns `.empty`
    /// when nothing is cached yet (cold install), in which case the screen
    /// renders its normal zero-comment form and the fetch fills it in.
    func localThread(rootId: UUID) -> LocalThread {
        localThreadResolver?(rootId) ?? .empty
    }

    /// The signed-in user, for display-entry construction. Set at launch.
    private(set) var currentUserId: UUID?

    func configure(userId: UUID) {
        currentUserId = userId
    }

    /// The warm copy an optimistic patch starts from — the resolver's truth
    /// when warm, otherwise the caller's own copy.
    private func currentEntry(id: UUID, fallback: Entry) -> Entry {
        entryResolver?(id) ?? fallback
    }

    /// Outbox entries mapped to display form, newest first — consumed by the
    /// paged All feed, which renders pending entries at the live edge.
    var pendingDisplayEntries: [Entry] {
        pendingEntries.reversed().map { displayEntry(for: $0) }
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
            user_id: currentUserId ?? pending.id,
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

        // Offline reads live in the per-scope page caches (FeedStore); this
        // model only restores the durable outbox.
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
        images: [PendingImage] = [],
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
                collectionId: collectionId,
                authorUserId: supabase.auth.currentSession?.user.id
            )
            pendingEntries.append(pending)
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
                let session = try await supabase.auth.session
                // Account-boundary guard: never upload one account's queued
                // entry into another. If the signed-in user differs from the
                // entry's author (a sign-out/sign-in raced this flush), drop
                // the item instead of posting it as the wrong user. Legacy
                // items (nil author, queued before author-binding) keep the
                // old behavior — they predate multi-account on this device.
                if let author = pending.authorUserId, author != session.user.id {
                    pendingEntries.removeAll { $0.id == pending.id }
                    outbox.remove(pending)
                    continue
                }
                let imagePayloads = outbox.loadImageDatas(for: pending)
                if !imagePayloads.isEmpty {
                    // Staged bytes ARE the upload payload — no second
                    // decode/encode generation at flush time.
                    let uploaded = try await imageStorage.uploadImageData(imagePayloads, userId: session.user.id)
                    // Seed the shared image cache so the promoted row renders
                    // the uploaded URLs straight from memory — the
                    // file:// → https:// swap never shows a placeholder.
                    // Decode happens off-main; the swap waits for it.
                    for (payload, attachment) in zip(imagePayloads, uploaded) {
                        if let url = URL(string: attachment.url) {
                            let decoded = await Task.detached(priority: .userInitiated) {
                                ImageDecode.downsampled(payload)
                            }.value
                            if let decoded {
                                ImageCache.insert(decoded, for: url)
                            }
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

                // Promote atomically: hand the persisted form to the warm
                // scopes and drop the pending form in the same run-loop tick.
                // Same id ⇒ SwiftUI keeps the row's identity ⇒ no blink, no
                // scroll shift.
                let info = filedCollectionId.flatMap { collectionInfoResolver?($0) }
                let promoted = Entry(
                    id: pending.id,
                    user_id: session.user.id,
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
                pendingEntries.removeAll { $0.id == pending.id }
                outbox.remove(pending)
                onEntryPromoted?(promoted)
            } catch let error as URLError {
                // Offline / transport failure: stop the whole pass quietly.
                _ = error
                break
            } catch {
                // No signed-in session (e.g. `auth.session` threw because a
                // sign-out raced this flush): stop the pass and do NOT write
                // the item back. Re-persisting here would resurrect a purged
                // entry, which could then flush into the next account. The
                // item, if genuinely the current user's, is already on disk.
                if supabase.auth.currentSession == nil { break }
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
            // Patch only this entry across warm scopes — never a reload.
            if let current = entryResolver?(entryId) {
                onEntryChanged?(current.withAttachments(updated))
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

    /// Deletes on the backend, designed to succeed overwhelmingly often:
    /// transport failures get brief in-place retries before the caller's
    /// failure path (restore + transient notice) ever runs. No feed reload —
    /// warm scope stores are told through `onEntryDeleted`.
    @discardableResult
    func deleteEntry(id: UUID) async -> Bool {
        errorMessage = nil
        for attempt in 0..<3 {
            do {
                try await repository.deleteEntry(id: id)
                onEntryDeleted?(id)
                return true
            } catch let error as URLError {
                // Offline / transport: retry quietly, then give up.
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    continue
                }
                errorMessage = error.localizedDescription
            } catch {
                // Server rejection: retrying won't change the answer.
                errorMessage = error.localizedDescription
                return false
            }
        }
        return false
    }

    /// Local-first content edit: the patched entry fans out to every warm
    /// scope immediately, persistence runs behind, and a genuine failure
    /// fans the pre-edit content back out. Detail hosts patch their own
    /// thread/root copies and use the returned Bool for their rollback.
    func updateEntryContent(id: UUID, content: String) async -> Bool {
        errorMessage = nil
        let original = entryResolver?(id)
        if let original {
            onEntryChanged?(original.withContent(content))
        }
        do {
            try await repository.updateEntryContent(id: id, content: content)
            if original == nil {
                // A comment, or a root beyond warm pages: the corpus refetches.
                onCommentContentChanged?()
            }
            return true
        } catch {
            if let original {
                onEntryChanged?(original)
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Toggles the checklist line at `lineIndex` with an immediate optimistic
    /// patch (checkbox taps must feel instant from the feed); rolls back if
    /// the server write fails. No reload — only the one row re-renders.
    @discardableResult
    func toggleChecklistItem(entry: Entry, lineIndex: Int) async -> Bool {
        let base = currentEntry(id: entry.id, fallback: entry)
        let newContent = Checklist.toggling(base.content, lineIndex: lineIndex)
        guard newContent != base.content else { return true }
        onEntryChanged?(base.withContent(newContent))
        do {
            try await repository.updateEntryContent(id: entry.id, content: newContent)
            return true
        } catch {
            onEntryChanged?(base)
            return false
        }
    }

    /// Toggles `is_content_hidden` with an immediate optimistic patch that
    /// fans out to every warm scope store; persists behind and rolls back on
    /// a genuine backend failure. No feed reload. Comments live in detail
    /// thread state — their hosts patch locally and use the returned Bool to
    /// keep or roll back that state.
    @discardableResult
    func toggleEntryHidden(id: UUID, currentValue: Bool) async -> Bool {
        let warm = entryResolver?(id)
        if let warm {
            onEntryChanged?(warm.withIsContentHidden(!currentValue))
        }
        do {
            try await supabase
                .from("entries")
                .update(["is_content_hidden": !currentValue])
                .eq("id", value: id)
                .execute()
            if warm == nil {
                onCommentContentChanged?()
            }
            return true
        } catch {
            if let warm {
                onEntryChanged?(warm.withIsContentHidden(currentValue))
            }
            return false
        }
    }

    /// Increments `resurface_count` by 1 with an immediate optimistic patch
    /// fanned into every warm scope store, so the counter updates in place
    /// inside collections too. On backend failure the patch is rolled back
    /// using the pre-tap value. Never reloads the feed — the move to the
    /// live edge is reconciled by the caller's scope revalidation.
    @discardableResult
    func resurfaceEntry(entry: Entry) async -> Bool {
        guard entry.pinned_at == nil, entry.parent_id == nil else { return false }
        let base = currentEntry(id: entry.id, fallback: entry)
        onEntryChanged?(base.withResurfaceCount(base.resurface_count + 1))
        do {
            try await repository.resurfaceEntry(id: entry.id)
            return true
        } catch {
            let now = currentEntry(id: entry.id, fallback: base)
            onEntryChanged?(now.withResurfaceCount(base.resurface_count))
            return false
        }
    }

    /// Increments `fire_count` by 1 with an immediate optimistic patch.
    /// On backend failure the patch is rolled back using the pre-tap value.
    /// Does NOT reload the feed or touch `feed_order_at` — no scroll or ordering side effects.
    @discardableResult
    func fireEntry(entry: Entry) async -> Bool {
        guard entry.parent_id == nil else { return false }
        let base = currentEntry(id: entry.id, fallback: entry)
        onEntryChanged?(base.withFireCount(base.fire_count + 1))
        do {
            try await repository.fireEntry(id: entry.id)
            return true
        } catch {
            let now = currentEntry(id: entry.id, fallback: base)
            onEntryChanged?(now.withFireCount(base.fire_count))
            return false
        }
    }

    /// Fetches one entry from the server. Used only by the reminder deep
    /// link, when the target isn't in any warm scope or the corpus mirror.
    func fetchEntry(id: UUID) async -> Entry? {
        try? await repository.fetchEntry(id: id)
    }

    /// nil means the fetch itself failed (offline or server error) — callers
    /// keep or substitute local truth. An empty array is a real answer: the
    /// server says the thread has no comments.
    func loadComments(rootId: UUID) async -> [Entry]? {
        do {
            return try await repository.fetchComments(rootId: rootId)
        } catch {
            return nil
        }
    }

    /// Persists a comment. The caller owns the optimistic thread/count state
    /// (insert the comment locally, bump the count, THEN call this) — the
    /// return value says whether to keep or roll back that state. `id` is
    /// the optimistic comment's client-generated id, so the server row and
    /// the local row are the same object.
    @discardableResult
    func sendComment(id: UUID? = nil, content: String, parentId: UUID, rootId: UUID, depth: Int) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            let session = try await supabase.auth.session
            try await repository.insertComment(
                id: id,
                userId: session.user.id,
                parentId: parentId,
                rootId: rootId,
                depth: depth,
                content: trimmed
            )
            // No count bump here: the caller already applied it optimistically
            // via applyCommentCountDelta before persistence — bumping again on
            // success would double-count.
            return true
        } catch {
            // Don't log the error: PostgrestError.detail can carry the comment
            // text. The boolean return drives the caller's rollback.
            return false
        }
    }

    /// Local-first comment counting: the root's counter changes in the same
    /// beat as the optimistic thread mutation, fanned into every warm feed
    /// scope (and the search corpus) — no refetch, no reload, no temporary
    /// disagreement between surfaces. Server revalidation later merges the
    /// identical authoritative value, so there is no double increment and no
    /// flicker.
    func applyCommentCountDelta(rootId: UUID, delta: Int) {
        if let current = entryResolver?(rootId) {
            onEntryChanged?(current.withCommentCount(max(0, (current.comment_count ?? 0) + delta)))
        }
        noteThreadChanged(rootId: rootId)
    }

    // MARK: - Collection membership (local-first move)

    /// Patches an entry's collection membership and fans it out to every
    /// warm scope store and the search corpus. Breadcrumb fields resolve
    /// from the local collections model.
    private func applyCollectionMembership(entryId: UUID, collectionId: UUID?) {
        guard let current = entryResolver?(entryId) else { return }
        let info = collectionId.flatMap { collectionInfoResolver?($0) }
        onEntryChanged?(current.withCollection(
            id: collectionId,
            name: info?.name,
            parentId: info?.parentId,
            parentName: info?.parentName
        ))
    }

    /// Local-first collection move: membership changes everywhere immediately
    /// (the entry leaves/joins warm scopes in the same beat), persistence
    /// runs behind. On a genuine failure the pre-move membership is restored.
    /// The server move is remove-then-add — not atomic; a failure between the
    /// two can leave the entry unfiled server-side until the next
    /// revalidation reconciles it (flagged for backend hardening).
    func moveEntry(id: UUID, from oldCollectionId: UUID?, to newCollectionId: UUID?) async -> Bool {
        let previousCollectionId = entryResolver?(id)?.collection_id ?? oldCollectionId
        applyCollectionMembership(entryId: id, collectionId: newCollectionId)
        do {
            do {
                // Preferred path: one atomic, ownership-checked server move.
                try await collectionRepository.moveEntryToCollection(entryId: id, collectionId: newCollectionId)
            } catch where Self.isMissingFunction(error) {
                // The atomic RPC isn't deployed yet (older backend). Fall back
                // to the legacy remove-then-add so the move still works; the
                // atomic path takes over automatically once the migration
                // (20260818_atomic_move_entry.sql) is applied.
                if let oldCollectionId {
                    try await collectionRepository.removeEntryFromCollection(entryId: id, collectionId: oldCollectionId)
                }
                if let newCollectionId {
                    try await collectionRepository.addEntryToCollection(entryId: id, collectionId: newCollectionId)
                }
            }
            return true
        } catch {
            applyCollectionMembership(entryId: id, collectionId: previousCollectionId)
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// True when PostgREST reports the RPC signature doesn't exist (schema
    /// cache miss, code PGRST202) — i.e. the atomic move function hasn't been
    /// deployed. Any other error is a real failure and must not fall back.
    private static func isMissingFunction(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "PGRST202"
    }

    // MARK: - Deleted-entry tombstones

    /// Ids confirmed (or optimistically assumed) deleted this session,
    /// including cascade descendants. A comment screen re-appearing from the
    /// nav stack checks its anchor against this set: deleting an ancestor
    /// cascades away every screen anchored below it, and those screens must
    /// pop instead of rendering ghosts. Retracted if the server rejects the
    /// delete.
    private var tombstonedEntryIds: Set<UUID> = []

    func noteEntriesDeleted(_ ids: Set<UUID>) {
        tombstonedEntryIds.formUnion(ids)
    }

    func retractEntriesDeleted(_ ids: Set<UUID>) {
        tombstonedEntryIds.subtract(ids)
    }

    func isEntryDeleted(_ id: UUID) -> Bool {
        tombstonedEntryIds.contains(id)
    }

    // MARK: - Thread staleness

    /// Per-root thread revision, bumped by any mutation that changes thread
    /// content (comment insert/delete, comment edit, hidden toggle). Detail
    /// screens compare against the revision they last rendered and refetch
    /// only when genuinely stale — a reappearing screen whose thread hasn't
    /// changed does no work at all. Not @Published on purpose: it's checked
    /// on appearance, never rendered.
    private var threadRevisions: [UUID: Int] = [:]

    func noteThreadChanged(rootId: UUID) {
        threadRevisions[rootId, default: 0] += 1
    }

    func threadRevision(rootId: UUID) -> Int {
        threadRevisions[rootId] ?? 0
    }
}

// MARK: - Thread data derivation

struct ThreadData {
    private let childrenMap: [UUID: [Entry]]
    private let entryById: [UUID: Entry]
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
        entryById = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func entry(id: UUID) -> Entry? {
        entryById[id]
    }

    func directChildren(of id: UUID) -> [Entry] {
        childrenMap[id] ?? []
    }

    func subtreeCount(for id: UUID) -> Int {
        let children = childrenMap[id] ?? []
        return children.reduce(children.count) { $0 + subtreeCount(for: $1.id) }
    }

    /// The comment chain above the given comment, ordered root-ward first
    /// (nearest the root Entry → immediate parent). The root Entry itself is
    /// not part of thread data and is resolved separately by callers.
    ///
    /// `parent_id` is the structural truth — persisted `depth` is never
    /// consulted. The walk is O(depth) over the prebuilt id map, and defends
    /// against malformed local state: a missing parent truncates the chain
    /// (the valid portion still renders), and a visited set makes a corrupt
    /// cycle terminate instead of looping.
    func ancestors(of id: UUID) -> [Entry] {
        var chain: [Entry] = []
        var visited: Set<UUID> = [id]
        var parentId = entryById[id]?.parent_id
        while let currentId = parentId,
              !visited.contains(currentId),
              let parent = entryById[currentId] {
            chain.append(parent)
            visited.insert(currentId)
            parentId = parent.parent_id
        }
        return chain.reversed()
    }
}
