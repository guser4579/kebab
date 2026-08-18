import Foundation
import Combine
import Supabase

@MainActor
final class AuthViewModel: ObservableObject {

    @Published var email: String = ""
    @Published var code: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isAuthenticated: Bool = false
    /// `true` after the first `checkSession()` finishes (success or failure).
    @Published private(set) var hasResolvedInitialSession: Bool = false
    @Published var codeSent: Bool = false
    @Published private(set) var currentUserId: UUID?
    @Published var currentUserEmail: String?

    private let supabase: SupabaseClient
    /// Lifetime subscription to auth events; a definitive `.signedOut`
    /// mid-session (revoked/rotated refresh token, sign-out from another
    /// device) must land on the login screen, never a zombie session whose
    /// every request silently fails.
    private var authEventsTask: Task<Void, Never>?

    init(supabase: SupabaseClient) {
        self.supabase = supabase
        Task { await checkSession() }
        authEventsTask = Task { [weak self] in
            for await (event, _) in supabase.auth.authStateChanges {
                // `.initialSession` is checkSession's job (it carries the
                // offline fallback); only a definitive sign-out routes here.
                if event == .signedOut {
                    self?.handleSessionEnded()
                }
            }
        }
    }

    deinit {
        authEventsTask?.cancel()
    }

    func checkSession() async {
        defer { hasResolvedInitialSession = true }
        do {
            let session = try await supabase.auth.session
            currentUserId = session.user.id
            currentUserEmail = session.user.email
            isAuthenticated = true
        } catch let error where error.isTransportFailure {
            // Offline durability: a transport failure (no signal, token refresh
            // unreachable) must NOT present the login screen when a locally
            // stored session exists — the cached feed should appear and tokens
            // refresh whenever connectivity returns.
            if let localSession = supabase.auth.currentSession {
                currentUserId = localSession.user.id
                currentUserEmail = localSession.user.email
                isAuthenticated = true
            } else {
                handleSessionEnded()
            }
        } catch {
            // The server answered and rejected the stored session (revoked or
            // rotated refresh token). Falling back to the local copy here
            // would open a zombie session — purge and present login instead.
            handleSessionEnded()
        }
    }

    /// One definitive end-of-session path, whatever triggered it (explicit
    /// sign-out, revoked token at launch, `.signedOut` mid-session). Purges
    /// every on-device store that holds one account's private content —
    /// feed/collection snapshots and the search corpus (LocalStore), the
    /// offline outbox, composer drafts, and the image byte caches (disk +
    /// memory + URLCache) — so nothing composed or cached under one account
    /// can surface in, or sync into, the next. LocalStore.removeAll wipes the
    /// whole cache directory, so the per-user-keyed history files
    /// (recentActivity_/searchHistory_/searchCorpus_) go too — they are
    /// rebuilt from the server on the account's return.
    private func handleSessionEnded() {
        LocalStore.removeAll()
        OutboxStore().purgeAll()
        UserDefaults.standard.removeObject(forKey: "composer.draft.feed")
        UserDefaults.standard.removeObject(forKey: "composer.draft.feed.link")
        ImageDiskCache.removeAll()
        ImageCache.shared.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        isAuthenticated = false
        currentUserId = nil
        currentUserEmail = nil
    }

    func sendOTP() async {
        guard !email.isEmpty else {
            errorMessage = "Enter your email"
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await supabase.auth.signInWithOTP(email: email)
            codeSent = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func verifyOTP() async {
        guard !code.isEmpty, code.count == 6 else {
            errorMessage = "Enter the 6-digit code"
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            try await supabase.auth.verifyOTP(
                email: email,
                token: code,
                type: .email
            )
            let session = try await supabase.auth.session
            currentUserId = session.user.id
            codeSent = false
            code = ""
            currentUserEmail = email
            isAuthenticated = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        do {
            try await supabase.auth.signOut()
        } catch { }
        // The `.signedOut` event usually lands first; running the shared
        // path again is idempotent and covers a failed network revoke.
        handleSessionEnded()
    }

    /// Permanently deletes the account, then tears down local state. Unlike
    /// sign-out, the per-user keyed stores are purged too — this account can
    /// never return. Throws before touching anything local if a server step
    /// fails, so a failure leaves the account fully intact and retryable.
    ///
    /// Order matters for privacy. The `delete_account` RPC only deletes
    /// `storage.objects` metadata rows, which leaves the actual image BYTES in
    /// the public bucket — anyone still holding a stored URL could keep
    /// fetching them. So we first physically delete the user's uploaded images
    /// through the Storage API (which removes the bytes), while the session is
    /// still valid, and only then run the account teardown. If the image purge
    /// fails we abort BEFORE deleting the account, so we never reach the state
    /// "account gone, images still reachable."
    func deleteAccount() async throws {
        guard let uid = currentUserId else {
            throw NSError(
                domain: "Kebab.DeleteAccount",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "You're signed out. Sign in again to delete your account."]
            )
        }

        // 1. Physically remove the user's own uploaded images (entry photos +
        //    avatar, all under entry-images/{uid}/). Ownership is enforced
        //    twice: every path is derived from the user's own rows, and the
        //    bucket's folder-scoped DELETE policy rejects anything outside
        //    {uid}/, so this can never touch another account's files.
        try await purgeUserStorageObjects(userId: uid)

        // 2. Server-side teardown: entries, collections, memberships, any
        //    straggler storage metadata rows, profile, and the auth user.
        try await supabase.rpc("delete_account").execute()

        // 3. ProfileStore caches each account's display name + avatar URL under
        //    "profile_<uid>". Sweep every such key (not just the deleted
        //    account's) so no residual profile PII is left in the preferences
        //    plist. The per-user history files (recentActivity_/searchHistory_/
        //    searchCorpus_) live in LocalStore's directory, wiped below.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("profile_") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // The auth user is already gone server-side; this just clears the
        // local token storage and may fail harmlessly.
        try? await supabase.auth.signOut()
        handleSessionEnded()
    }

    /// Deletes every Storage object the user owns, by the URLs the account
    /// actually references (entry image attachments + the current avatar) —
    /// the only URLs that could have been shared or persisted anywhere. Uses
    /// the Storage API `remove`, which deletes the underlying bytes (not just
    /// the metadata row). Idempotent: re-running after a partial failure just
    /// removes whatever remains. Throws on a real transport/permission failure
    /// so the caller aborts the account deletion and the user can retry.
    private func purgeUserStorageObjects(userId uid: UUID) async throws {
        struct AttachmentsRow: Decodable { let attachments: [EntryAttachment]? }
        struct AvatarRow: Decodable { let avatar_url: String? }

        var paths: Set<String> = []

        // Image attachments across all of the user's entries (RLS scopes the
        // select to user_id = auth.uid(), so this is the user's own content).
        let rows: [AttachmentsRow] = try await supabase
            .from("entries")
            .select("attachments")
            .eq("user_id", value: uid)
            .execute()
            .value
        for row in rows {
            for attachment in row.attachments ?? [] where attachment.attachmentType == .image {
                if let path = ProfileRepository.storagePath(fromPublicUrl: attachment.url) {
                    paths.insert(path)
                }
            }
        }

        // The current avatar object (avatars share the entry-images bucket).
        let profileRows: [AvatarRow] = try await supabase
            .from("profiles")
            .select("avatar_url")
            .eq("id", value: uid)
            .limit(1)
            .execute()
            .value
        if let avatar = profileRows.first?.avatar_url,
           let path = ProfileRepository.storagePath(fromPublicUrl: avatar) {
            paths.insert(path)
        }

        guard !paths.isEmpty else { return }

        // Remove in bounded batches so a large account doesn't send one huge
        // request. remove() silently ignores paths that are already gone, so
        // a retry after a partial delete is safe.
        let all = Array(paths)
        var index = 0
        while index < all.count {
            let batch = Array(all[index..<min(index + 100, all.count)])
            _ = try await supabase.storage
                .from(ImageStorageRepository.bucket)
                .remove(paths: batch)
            index += 100
        }
    }

    func resetFlow() {
        codeSent = false
        code = ""
        errorMessage = nil
    }
}

private extension Error {
    /// True for connectivity-level failures (offline, DNS, timeouts) — the
    /// cases where a stored session should be trusted until the server can
    /// actually be asked. Anything else from the auth endpoint is a real
    /// answer, not a bad connection.
    var isTransportFailure: Bool {
        (self as NSError).domain == NSURLErrorDomain
    }
}
