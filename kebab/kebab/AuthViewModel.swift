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
    @Published var codeSent: Bool = false

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
        Task { await checkSession() }
    }

    func checkSession() async {
        do {
            _ = try await supabase.auth.session
            isAuthenticated = true
        } catch {
            isAuthenticated = false
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
            isAuthenticated = true
            codeSent = false
            code = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetFlow() {
        codeSent = false
        code = ""
        errorMessage = nil
    }
}
