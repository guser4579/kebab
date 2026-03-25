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
    /// The parent collection currently expanded in the picker; nil = all collapsed.
    @State private var expandedCollectionId: UUID?
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

    // MARK: - Helpers

    private var parentCollections: [Collection] {
        collectionsVM.collections.filter { $0.parentId == nil }
    }

    private func subCollections(for parentId: UUID) -> [Collection] {
        collectionsVM.collections
            .filter { $0.parentId == parentId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func itemLabel(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    // MARK: - Body

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

                        ForEach(parentCollections) { parent in
                            parentRow(parent)

                            let subs = subCollections(for: parent.id)
                            if expandedCollectionId == parent.id && !subs.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(Array(subs.enumerated()), id: \.element.id) { idx, sub in
                                        subRow(sub, isLast: idx == subs.count - 1)
                                    }
                                }
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Style.Color.separator)
                                        .frame(width: 1)
                                        .frame(maxHeight: .infinity)
                                        .padding(.leading, 16)
                                }
                            }
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
                        // Auto-select the newly created top-level collection.
                        if let newest = collectionsVM.collections.first(where: { $0.parentId == nil }) {
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
                // If destination is a sub-collection, expand its parent automatically.
                if let current = collectionsVM.collections.first(where: { $0.id == id }),
                   let parentId = current.parentId {
                    expandedCollectionId = parentId
                }
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

    // MARK: - Parent Row

    private func parentRow(_ collection: Collection) -> some View {
        let isSelected = selectedCollectionId == collection.id
        let subs = subCollections(for: collection.id)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    handleParentTap(collection, hasSubs: !subs.isEmpty)
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

                        Text(itemLabel(collection.itemCount))
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

    // MARK: - Sub-Collection Row

    /// Indented using the same leading/trailing values as CommentRowView (33pt / 16pt),
    /// with a vertical separator line overlay at 16pt from leading — matching EntryDetailView's
    /// comment-section line pattern exactly.
    /// `isLast` controls the separator inset:
    /// - intermediate rows: indent to the spine (16pt) so the line abuts the vertical thread line
    /// - last row: full-width separator, matching the parent row style
    private func subRow(_ sub: Collection, isLast: Bool) -> some View {
        let isSelected = selectedCollectionId == sub.id

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    selectedCollectionId = sub.id
                    // Parent remains expanded (expandedCollectionId stays unchanged).
                }
            } label: {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 33)

                    if isSelected {
                        Icon("tick-02")
                            .foregroundColor(Style.Color.composerSend)
                        Color.clear
                            .frame(width: 8)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(sub.name)
                            .font(Style.Typography.body())
                            .foregroundColor(Style.Color.primaryText)
                            .lineLimit(1)

                        Text(itemLabel(sub.itemCount))
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
                .padding(.leading, isLast ? 0 : 16)
        }
    }

    // MARK: - Tap Logic

    private func handleParentTap(_ collection: Collection, hasSubs: Bool) {
        if selectedCollectionId == collection.id {
            // Already selected → deselect and collapse.
            selectedCollectionId = nil
            expandedCollectionId = nil
        } else {
            // Select and expand if it has sub-collections; collapse previous.
            selectedCollectionId = collection.id
            expandedCollectionId = hasSubs ? collection.id : nil
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
