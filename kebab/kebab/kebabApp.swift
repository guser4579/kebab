import SwiftUI
import Supabase

private struct SupabaseKey: EnvironmentKey {
    static let defaultValue: SupabaseClient? = nil
}

extension EnvironmentValues {
    var supabase: SupabaseClient? {
        get { self[SupabaseKey.self] }
        set { self[SupabaseKey.self] = newValue }
    }
}

@main
struct kebabApp: App {

    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://bjhyaqjimicxtgulvnrl.supabase.co")!,
        supabaseKey: "sb_publishable_J7aGdl5L9Fi_cHzK9sfbdA_dkjtBReV"
    )

    var body: some Scene {
        WindowGroup {
            RootView(supabase: supabase)
                .environment(\.supabase, supabase)
        }
    }
}

struct RootView: View {
    let supabase: SupabaseClient
    @StateObject private var authViewModel: AuthViewModel

    init(supabase: SupabaseClient) {
        self.supabase = supabase
        _authViewModel = StateObject(wrappedValue: AuthViewModel(supabase: supabase))
    }

    var body: some View {
        if authViewModel.isAuthenticated {
            MainAppView(supabase: supabase)
        } else {
            AuthView(viewModel: authViewModel)
        }
    }
}
