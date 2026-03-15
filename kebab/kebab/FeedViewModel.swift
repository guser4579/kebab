import Foundation
import Combine
import LinkPresentation
import Supabase

@MainActor
final class FeedViewModel: ObservableObject {

    @Published var entries: [Entry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    var feedEntries: [Entry] {
        entries.filter { $0.pinned_at == nil }
    }

    var pinnedEntries: [Entry] {
        entries.filter { $0.pinned_at != nil }
               .sorted { $0.pinned_at! < $1.pinned_at! }
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
        defer { isLoading = false }

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
            favicon_url: nil
        )

        return (cleaned, attachment)
    }

    private func enrichLinkMetadata(entryId: UUID, attachment: EntryAttachment) async {
        guard let url = URL(string: attachment.url) else { return }

        do {
            let provider = LPMetadataProvider()
            provider.timeout = 10

            let metadata = try await provider.startFetchingMetadata(for: url)

            guard let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return
            }

            let enriched = EntryAttachment(
                type: attachment.type,
                url: attachment.url,
                title: title,
                favicon_url: attachment.favicon_url
            )

            try await repository.updateAttachments(entryId: entryId, attachments: [enriched])
            await loadEntries()
        } catch {
            // Silently ignore — entry keeps its current URL-only presentation
        }
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

    func toggleEntryHidden(id: UUID, currentValue: Bool) async {
        do {
            try await supabase
                .from("entries")
                .update(["is_content_hidden": !currentValue])
                .eq("id", value: id)
                .execute()

            await loadEntries()
        } catch {
            print("Failed to toggle entry hidden state:", error)
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

    func sendComment(content: String, rootEntry: Entry) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let session = try await supabase.auth.session
            let payload = InsertCommentPayload(
                user_id: session.user.id,
                parent_id: rootEntry.id,
                root_id: rootEntry.id,
                content: trimmed,
                is_content_hidden: false
            )
            try await supabase
                .from("entries")
                .insert(payload)
                .execute()
        } catch {
            print("Failed to send comment:", error)
        }
    }
}

private struct InsertCommentPayload: Encodable {
    let user_id: UUID
    let parent_id: UUID
    let root_id: UUID
    let content: String
    let is_content_hidden: Bool
}
