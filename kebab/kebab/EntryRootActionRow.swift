import SwiftUI

/// Root-entry actions (resurface, pin, fire) with optional chat shortcut to `EntryDetailView`.
/// Used by feed rows (`includeChat: true`) and root `EntryDetailView` (`includeChat: false`).
struct EntryRootActionRow: View {

    let entry: Entry
    var feedViewModel: FeedViewModel?
    var includeChat: Bool
    var showResurface: Bool = true
    var onResultActivated: (() -> Void)?
    var onResurfaceTapped: (() -> Void)?
    var onPinTapped: (() -> Void)?
    var onFireTapped: (() -> Void)?

    @State private var isResurfacing = false

    var body: some View {
        HStack(spacing: Style.Spacing.x4) {
            if includeChat {
                Group {
                    if let feedViewModel = feedViewModel {
                        NavigationLink(destination: EntryDetailView(entry: entry, feedViewModel: feedViewModel)) {
                            Icon("message-circle")
                                .foregroundColor(Style.Color.secondary)
                        }
                        .simultaneousGesture(TapGesture().onEnded { onResultActivated?() })
                    } else {
                        Button {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        } label: {
                            Icon("message-circle")
                                .foregroundColor(Style.Color.secondary)
                        }
                    }
                }
            }

            if showResurface {
                Button {
                    guard !isResurfacing else { return }
                    isResurfacing = true
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    onResurfaceTapped?()
                } label: {
                    Icon("refresh-04")
                        .foregroundColor(Style.Color.secondary)
                }
            }

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                onFireTapped?()
            } label: {
                Icon("fire-03")
                    .foregroundColor(Style.Color.secondary)
            }
        }
        .frame(minHeight: 24, alignment: .leading)
        .onChange(of: entry.resurface_count) {
            isResurfacing = false
        }
    }
}
