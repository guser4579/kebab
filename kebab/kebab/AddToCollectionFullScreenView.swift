import SwiftUI
import Supabase

struct AddToCollectionFullScreenView: View {

    let entry: Entry
    let onDismiss: () -> Void
    /// Called after a successful mutation so the caller can reload shared collection state.
    let onSuccess: () -> Void

    @StateObject private var collectionsVM: CollectionsViewModel
    private let repository: CollectionRepository

    @State private var selectedCollectionId: UUID?
    @State private var initialCollectionId: UUID?
    @State private var isConfirming = false
    @State private var confirmError: String?
    @State private var isNewCollectionVisible = false

    init(
        entry: Entry,
        supabase: SupabaseClient,
        onDismiss: @escaping () -> Void,
        onSuccess: @escaping () -> Void
    ) {
        self.entry = entry
        self.onDismiss = onDismiss
        self.onSuccess = onSuccess
        self.repository = CollectionRepository(supabase: supabase)
        _collectionsVM = StateObject(wrappedValue: CollectionsViewModel(supabase: supabase))
    }

    private var hasChange: Bool {
        selectedCollectionId != initialCollectionId
    }

    private var tickInteractive: Bool {
        hasChange && !isConfirming
    }

    var body: some View {
        VStack(spacing: 0) {
            addToCollectionHeader

            if collectionsVM.isLoading && !collectionsVM.hasCompletedInitialLoad {
                Spacer()
                ProgressView()
                    .tint(Style.Color.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        newCollectionRow

                        Rectangle()
                            .fill(Style.Color.separator)
                            .frame(height: 1)
                            .frame(maxWidth: .infinity)

                        ForEach(collectionsVM.collections) { collection in
                            collectionSelectionRow(collection)
                        }
                    }
                }
                .defaultScrollAnchor(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Style.Color.background)
        .ignoresSafeArea(edges: [.top, .bottom])
        .alert("Couldn't update collection", isPresented: Binding(
            get: { confirmError != nil },
            set: { if !$0 { confirmError = nil } }
        )) {
            Button("OK", role: .cancel) { confirmError = nil }
        } message: {
            if let confirmError {
                Text(confirmError)
            }
        }
        .overlay {
            if isNewCollectionVisible {
                NewCollectionFullScreenView(
                    collectionsViewModel: collectionsVM,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isNewCollectionVisible = false
                        }
                        // Auto-select the newly created collection.
                        // loadCollections() has already completed before onDismiss fires,
                        // and collections are sorted by updated_at desc, so the new one is first.
                        if let newest = collectionsVM.collections.first {
                            selectedCollectionId = newest.id
                        }
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .task {
            await collectionsVM.loadCollections()
            if let id = try? await repository.getCollectionIdForEntry(entryId: entry.id) {
                initialCollectionId = id
                selectedCollectionId = id
            }
        }
    }

    // MARK: - Header

    private var addToCollectionHeader: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            ZStack {
                Text("Add to collection")
                    .font(.custom("DMSans-Medium", size: 16))
                    .foregroundColor(Style.Color.primaryText)

                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Icon("close")
                            .foregroundColor(Style.Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        Task { await handleConfirm() }
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

    // MARK: - New Collection Row

    private var newCollectionRow: some View {
        Button {
            isNewCollectionVisible = true
        } label: {
            HStack(spacing: Style.Spacing.x3) {
                Icon("add-collection")
                    .foregroundColor(Style.Color.primaryText)

                Text("New collection")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Style.Layout.entryContentPadding)
            .padding(.vertical, Style.Spacing.x4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Collection Selection Row

    private func collectionSelectionRow(_ collection: Collection) -> some View {
        let isSelected = selectedCollectionId == collection.id

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if selectedCollectionId == collection.id {
                        selectedCollectionId = nil
                    } else {
                        selectedCollectionId = collection.id
                    }
                }
            } label: {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 16)

                    if isSelected {
                        Icon("tick-02")
                            .foregroundColor(Style.Color.composerSend)
                        Color.clear
                            .frame(width: 8)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                            .font(Style.Typography.body())
                            .foregroundColor(Style.Color.primaryText)
                            .lineLimit(1)

                        Text(collection.itemCount == 1 ? "1 item" : "\(collection.itemCount) items")
                            .font(Style.Typography.meta())
                            .foregroundColor(Style.Color.secondary)
                    }

                    Spacer(minLength: Style.Layout.entryContentPadding)
                }
                .padding(.vertical, Style.Spacing.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Style.Color.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Confirm

    @MainActor
    private func handleConfirm() async {
        guard tickInteractive else { return }

        isConfirming = true

        do {
            if let oldId = initialCollectionId {
                try await repository.removeEntryFromCollection(entryId: entry.id, collectionId: oldId)
            }
            if let newId = selectedCollectionId {
                try await repository.addEntryToCollection(entryId: entry.id, collectionId: newId)
            }

            isConfirming = false
            Haptics.mediumTap()
            onSuccess()
            onDismiss()
        } catch {
            isConfirming = false
            confirmError = error.localizedDescription
        }
    }
}
