import SwiftUI
import UIKit

struct RenameCollectionFullScreenView: View {

    let collection: Collection
    @ObservedObject var collectionsViewModel: CollectionsViewModel
    let onDismiss: () -> Void
    /// Called with the new trimmed name immediately after a successful server rename,
    /// so the detail header can update before the overlay finishes its exit transition.
    let onSuccess: (String) -> Void

    @State private var name: String
    @State private var isRenaming = false
    @State private var renameErrorMessage: String?

    @FocusState private var isFocused: Bool

    init(
        collection: Collection,
        collectionsViewModel: CollectionsViewModel,
        onDismiss: @escaping () -> Void,
        onSuccess: @escaping (String) -> Void
    ) {
        self.collection = collection
        self.collectionsViewModel = collectionsViewModel
        self.onDismiss = onDismiss
        self.onSuccess = onSuccess
        _name = State(initialValue: collection.name)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedOriginal: String {
        collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Disabled when empty, unchanged, or a rename is in flight.
    private var tickInteractive: Bool {
        !trimmedName.isEmpty && trimmedName != trimmedOriginal && !isRenaming
    }

    var body: some View {
        VStack(spacing: 0) {
            renameHeader

            TextField("Collection name", text: $name)
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .tint(Style.Color.composerSend)
                .padding(.horizontal, Style.Layout.entryContentPadding)
                .padding(.top, 16)
                .focused($isFocused)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Style.Color.background)
        .ignoresSafeArea(edges: [.top, .bottom])
        .alert("Couldn't rename collection", isPresented: Binding(
            get: { renameErrorMessage != nil },
            set: { if !$0 { renameErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                renameErrorMessage = nil
            }
        } message: {
            if let renameErrorMessage {
                Text(renameErrorMessage)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }

    private var renameHeader: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            ZStack {
                Text("Rename")
                    .font(.custom("DMSans-Medium", size: 16))
                    .foregroundColor(Style.Color.primaryText)

                HStack {
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        onDismiss()
                    } label: {
                        Icon("close")
                            .foregroundColor(Style.Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        Task { await handleRename() }
                    } label: {
                        Icon("tick-02")
                            .foregroundColor(
                                tickInteractive
                                    ? Style.Color.composerSend
                                    : Style.Color.secondary.opacity(0.35)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!tickInteractive)
                }
                .padding(.horizontal, Style.Spacing.x4)
                .frame(height: 24, alignment: .center)
            }
            .frame(height: 24)

            Color.clear
                .frame(height: 12)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(Style.Color.background)
    }

    @MainActor
    private func handleRename() async {
        guard tickInteractive else { return }

        isRenaming = true
        let ok = await collectionsViewModel.renameCollection(id: collection.id, name: trimmedName)
        isRenaming = false

        if ok {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            Haptics.mediumTap()
            onSuccess(trimmedName)
            onDismiss()
        } else {
            renameErrorMessage = collectionsViewModel.errorMessage ?? "Something went wrong."
        }
    }
}
