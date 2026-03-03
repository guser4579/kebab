import SwiftUI
import Supabase

struct ContentView: View {

    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://bjhyaqjimicxtgulvnrl.supabase.co")!,
        supabaseKey: "sb_publishable_J7aGdl5L9Fi_cHzK9sfbdA_dkjtBReV"
    )

    @State private var status = "Not tested"

    var body: some View {
        VStack(spacing: 20) {
            Text(status)

            Button("Test Connection") {
                Task {
                    do {
                        let response = try await supabase
                            .from("profiles")
                            .select()
                            .execute()

                        status = "Connected. Rows: \(response.data.count)"
                    } catch {
                        status = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
        .padding()
    }
}
