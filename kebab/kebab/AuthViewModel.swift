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
    /// the device-global caches — feed snapshots, per-scope pages, the
    /// offline outbox, composer drafts — so nothing composed or cached under
    /// one account can surface in (or sync into) the next. Per-user stores
    /// (recent activity/searches, search corpus) key by user id and keep
    /// their data for that account's return.
    private func handleSessionEnded() {
        LocalStore.removeAll()
        OutboxStore().purgeAll()
        UserDefaults.standard.removeObject(forKey: "composer.draft.feed")
        UserDefaults.standard.removeObject(forKey: "composer.draft.feed.link")
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
