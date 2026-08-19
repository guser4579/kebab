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

    /// User-selected appearance; defaults to dark (the app's original look).
    @AppStorage("kebab.appearance") private var appearance = "dark"

    init() {
        // Installed before the first frame so a reminder tap that cold-
        // launched the app is captured and replayed once the reminder store
        // attaches — the deep link is never dropped.
        ReminderNotificationDelegate.install()
        // Generous shared URL cache so link-preview and entry images persist
        // across scrolling sessions and app launches instead of refetching.
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
    }

    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://bjhyaqjimicxtgulvnrl.supabase.co")!,
        supabaseKey: "sb_publishable_J7aGdl5L9Fi_cHzK9sfbdA_dkjtBReV"
    )

    var body: some Scene {
        WindowGroup {
            RootView(supabase: supabase)
                .environment(\.supabase, supabase)
                // Dynamic Style.Color tokens resolve app-wide from this.
                // "system" (nil) follows the device appearance.
                .preferredColorScheme(
                    appearance == "system" ? nil : (appearance == "light" ? .light : .dark)
                )
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
        Group {
            if !authViewModel.hasResolvedInitialSession {
                InitialSessionLoadingView()
            } else if authViewModel.isAuthenticated {
                MainAppView(supabase: supabase, authViewModel: authViewModel)
            } else {
                AuthView(viewModel: authViewModel)
            }
        }
    }
}

private struct InitialSessionLoadingView: View {
    var body: some View {
        ZStack {
            Style.Color.background
                .ignoresSafeArea()
            ProgressView()
                .tint(Style.Color.secondary)
        }
    }
}
