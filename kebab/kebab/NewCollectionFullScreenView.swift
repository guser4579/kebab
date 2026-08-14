import SwiftUI
import UIKit

struct NewCollectionFullScreenView: View {

    @ObservedObject var collectionsViewModel: CollectionsViewModel
    let onDismiss: () -> Void

    /// Overrides the sheet header title (e.g. "New sub-collection").
    var title: String = "New collection"
    /// When non-nil, creates a sub-collection under this parent instead of a top-level collection.
    var parentId: UUID? = nil
    /// Sibling sub-collection names used for live duplicate validation (case-insensitive).
    /// Leave empty for top-level collection creation (no duplicate check).
    var existingSiblingNames: [String] = []
    /// When non-nil this surface renames the given collection instead of
    /// creating one: the field is prefilled with its current name and the
    /// tick requires an actual change. Same layout, keyboard behavior, and
    /// controls as creation — one naming surface for all four flows.
    var renameTarget: Collection? = nil
    /// Called with the created (or renamed) collection after a successful
    /// submit, before dismissal — lets owners navigate into it or refresh.
    var onSuccess: ((Collection) -> Void)? = nil

    @State private var name: String = ""
    @State private var isCreating = false
    @State private var createErrorMessage: String?
    /// Set to true immediately before `isCreating` is cleared on the success path.
    /// Prevents a re-render triggered by `isCreating = false` from briefly evaluating
    /// `isDuplicate = true` against the freshly reloaded sibling list — before
    /// `onDismiss()` has had a chance to close the sheet.
    @State private var hasSubmittedSuccessfully = false

    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when trimmed name matches a sibling, case-insensitively.
    /// Suppressed during submission (`isCreating`) and after a successful submit
    /// (`hasSubmittedSuccessfully`) so the re-render caused by clearing `isCreating`
    /// cannot flash a false duplicate against the freshly reloaded sibling list.
    private var isDuplicate: Bool {
        guard !trimmedName.isEmpty, !isCreating, !hasSubmittedSuccessfully else { return false }
        let lower = trimmedName.lowercased()
        // A case-only change of a rename target's own name is never a
        // duplicate of itself.
        if let renameTarget, lower == renameTarget.name.lowercased() {
            return false
        }
        return existingSiblingNames.contains { $0.lowercased() == lower }
    }

    private var tickInteractive: Bool {
        guard !trimmedName.isEmpty, !isDuplicate, !isCreating else { return false }
        // Renaming requires an actual change.
        if let renameTarget, trimmedName == renameTarget.name {
            return false
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            createHeader

            TextField(
                (parentId != nil || renameTarget?.parentId != nil)
                    ? "Sub-collection name" : "Collection name",
                text: $name
            )
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .tint(Style.Color.composerSend)
                .padding(.horizontal, Style.Layout.entryContentPadding)
                .padding(.top, 16)
                .focused($isFocused)

            if isDuplicate {
                Text("A sub-collection with this name already exists.")
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Style.Layout.entryContentPadding)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Style.Color.background)
        .ignoresSafeArea(edges: [.top, .bottom])
        .alert(
            renameTarget == nil ? "Couldn't create collection" : "Couldn't rename collection",
            isPresented: Binding(
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
            // Rename starts from the existing name, ready to edit.
            if let renameTarget, name.isEmpty {
                name = renameTarget.name
            }
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
                Text(title)
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

        if let renameTarget {
            // Rename path — same surface, different mutation.
            let ok = await collectionsViewModel.renameCollection(
                id: renameTarget.id,
                name: trimmedName
            )
            if ok {
                hasSubmittedSuccessfully = true
                isCreating = false
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
                Haptics.mediumTap()
                // The reload inside renameCollection already has the fresh
                // model; fall back to the target if it's not found.
                let updated = collectionsViewModel.collections
                    .first { $0.id == renameTarget.id } ?? renameTarget
                onSuccess?(updated)
                onDismiss()
            } else {
                isCreating = false
                createErrorMessage = collectionsViewModel.errorMessage ?? "Something went wrong."
            }
        } else if let parentId {
            // Sub-collection creation path
            if let created = await collectionsViewModel.createSubcollection(
                parentId: parentId,
                name: trimmedName
            ) {
                // Raise the success flag BEFORE clearing isCreating so the re-render
                // that isCreating = false triggers cannot briefly evaluate isDuplicate
                // against the freshly reloaded sibling list.
                hasSubmittedSuccessfully = true
                isCreating = false
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
                Haptics.mediumTap()
                onSuccess?(created)
                onDismiss()
            } else {
                isCreating = false
                createErrorMessage = collectionsViewModel.errorMessage ?? "Something went wrong."
            }
        } else {
            // Top-level collection creation path
            if let created = await collectionsViewModel.createCollection(name: trimmedName) {
                hasSubmittedSuccessfully = true
                isCreating = false
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
                Haptics.mediumTap()
                onSuccess?(created)
                onDismiss()
            } else {
                isCreating = false
                createErrorMessage = collectionsViewModel.errorMessage ?? "Something went wrong."
            }
        }
    }
}
