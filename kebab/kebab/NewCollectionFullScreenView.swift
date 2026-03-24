import SwiftUI
import UIKit

struct NewCollectionFullScreenView: View {

    @ObservedObject var collectionsViewModel: CollectionsViewModel
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var isCreating = false
    @State private var createErrorMessage: String?

    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tickInteractive: Bool {
        !trimmedName.isEmpty && !isCreating
    }

    var body: some View {
        VStack(spacing: 0) {
            createHeader

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
        .alert("Couldn't create collection", isPresented: Binding(
            get: { createErrorMessage != nil },
            set: { if !$0 { createErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                createErrorMessage = nil
            }
        } message: {
            if let createErrorMessage {
                Text(createErrorMessage)
            }
        }
        .onAppear {
            // Small delay lets the slide-up transition settle before the
            // keyboard appears, matching the FocusingTextView deferred-focus
            // approach used in EditEntryFullScreenView.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }

    private var createHeader: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            ZStack {
                Text("New collection")
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
                        Task { await handleCreate() }
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
    private func handleCreate() async {
        guard tickInteractive else { return }

        isCreating = true
        let ok = await collectionsViewModel.createCollection(name: trimmedName)
        isCreating = false

        if ok {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            Haptics.mediumTap()
            onDismiss()
        } else {
            createErrorMessage = collectionsViewModel.errorMessage ?? "Something went wrong."
        }
    }
}
