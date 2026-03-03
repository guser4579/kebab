import SwiftUI
import Supabase

@main
struct kebabApp: App {

    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://bjhyaqjimicxtgulvnrl.supabase.co")!,
        supabaseKey: "sb_publishable_J7aGdl5L9Fi_cHzK9sfbdA_dkjtBReV"
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
