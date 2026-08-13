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

    init(supabase: SupabaseClient) {
        self.supabase = supabase
        Task { await checkSession() }
    }

    func checkSession() async {
        defer { hasResolvedInitialSession = true }
        do {
            let session = try await supabase.auth.session
            currentUserId = session.user.id
            currentUserEmail = session.user.email
            isAuthenticated = true
        } catch {
            // Offline durability: a transport failure (no signal, token refresh
            // unreachable) must NOT present the login screen when a locally
            // stored session exists — the cached feed should appear and tokens
            // refresh whenever connectivity returns.
            if let localSession = supabase.auth.currentSession {
                currentUserId = localSession.user.id
                currentUserEmail = localSession.user.email
                isAuthenticated = true
            } else {
                isAuthenticated = false
                currentUserId = nil
                currentUserEmail = nil
            }
        }
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
        isAuthenticated = false
        currentUserId = nil
        currentUserEmail = nil
    }

    func resetFlow() {
        codeSent = false
        code = ""
        errorMessage = nil
    }
}
