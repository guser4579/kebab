import SwiftUI
import Supabase

struct MainAppView: View {

    @StateObject private var feedViewModel: FeedViewModel
    @State private var composerText: String = ""
    @State private var hasScrolledToInitialBottom = false

    init(supabase: SupabaseClient) {
        _feedViewModel = StateObject(wrappedValue: FeedViewModel(supabase: supabase))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(feedViewModel.entries) { entry in
                            Text(entry.content)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("feedBottom")
                    }
                    .padding(.horizontal, Style.Layout.entryContentPadding)
                    .padding(.top, Style.Spacing.x4)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Style.Color.background)
                .foregroundColor(Style.Color.primaryText)
                .task {
                    await feedViewModel.loadEntries()
                }
                .onChange(of: feedViewModel.entries.count) { _, newCount in
                    guard newCount > 0, !hasScrolledToInitialBottom else { return }
                    hasScrolledToInitialBottom = true
                    DispatchQueue.main.async {
                        proxy.scrollTo("feedBottom", anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    ComposerView(
                        text: $composerText,
                        maxHeight: geometry.size.height * Style.Layout.composerMaxHeightFraction,
                        onSent: { content in
                            Task {
                                await feedViewModel.sendEntry(content: content)
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                withAnimation(.easeOut(duration: 0.25)) {
                                    proxy.scrollTo("feedBottom", anchor: .bottom)
                                }
                            }
                        },
                        onFocus: {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("feedBottom", anchor: .bottom)
                            }
                        }
                    )
                }
            }
        }
    }
}

#Preview {
    MainAppView(supabase: SupabaseClient(
        supabaseURL: URL(string: "https://example.supabase.co")!,
        supabaseKey: "key"
    ))
}
