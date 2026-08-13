import SwiftUI
import Supabase

struct AddToCollectionFullScreenView: View {

    let entry: Entry
    /// Sticky header title. Defaults to "Add to collection"; pass "Move entry" for the move flow.
    let title: String
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
    @State private var isNewSubVisible = false

    init(
        entry: Entry,
        title: String = "Add to collection",
        supabase: SupabaseClient,
        onDismiss: @escaping () -> Void,
        onSuccess: @escaping () -> Void
    ) {
        self.entry = entry
        self.title = title
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

                        if initialCollectionId != nil {
                            noCollectionRow

                            Rectangle()
                                .fill(Style.Color.separator)
                                .frame(height: 1)
                                .frame(maxWidth: .infinity)
                        }

                        ForEach(parentCollections) { parent in
                            parentRow(parent)

                            let subs = subCollections(for: parent.id)
                            if expandedCollectionId == parent.id {
                                VStack(spacing: 0) {
                                    ForEach(subs) { sub in
                                        subRow(sub, isLast: false)
                                    }
                                    newSubCollectionRow
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
        .overlay {
            if isNewSubVisible, let parentId = expandedCollectionId {
                NewCollectionFullScreenView(
                    collectionsViewModel: collectionsVM,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isNewSubVisible = false
                        }
                    },
                    title: "New sub-collection",
                    parentId: parentId,
                    existingSiblingNames: subCollections(for: parentId).map { $0.name },
                    onSuccess: { created in
                        // Auto-select the newly created sub-collection; parent stays expanded.
                        selectedCollectionId = created.id
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
                if let current = collectionsVM.collections.first(where: { $0.id == id }) {
                    if let parentId = current.parentId {
                        // Sub-collection: expand its parent so the current sub is visible.
                        expandedCollectionId = parentId
                    } else {
                        // Top-level collection: expand itself so its sub-collections
                        // (and the "New sub-collection" row) are visible.
                        expandedCollectionId = current.id
                    }
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
                Text(title)
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
                Icon("add-circle")
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

    // MARK: - No Collection Row

    private var noCollectionRow: some View {
        let isSelected = selectedCollectionId == nil
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                selectedCollectionId = nil
                expandedCollectionId = nil
            }
        } label: {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 16)

                Text("No collection")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)

                Spacer(minLength: Style.Spacing.x3)

                if isSelected {
                    Icon("tick-02")
                        .foregroundColor(Style.Color.composerSend)
                }

                Color.clear
                    .frame(width: Style.Layout.entryContentPadding)
            }
            .padding(.vertical, Style.Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Parent Row

    private func parentRow(_ collection: Collection) -> some View {
        let isSelected = selectedCollectionId == collection.id

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    handleParentTap(collection)
                }
            } label: {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                            .font(Style.Typography.body())
                            .foregroundColor(Style.Color.primaryText)
                            .lineLimit(1)

                        Text(itemLabel(collection.itemCount))
                            .font(Style.Typography.meta())
                            .foregroundColor(Style.Color.secondary)
                    }

                    Spacer(minLength: Style.Spacing.x3)

                    if isSelected {
                        Icon("tick-02")
                            .foregroundColor(Style.Color.composerSend)
                    }

                    Color.clear
                        .frame(width: Style.Layout.entryContentPadding)
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

                    VStack(alignment: .leading, spacing: 2) {
                        Text(sub.name)
                            .font(Style.Typography.body())
                            .foregroundColor(Style.Color.primaryText)
                            .lineLimit(1)

                        Text(itemLabel(sub.itemCount))
                            .font(Style.Typography.meta())
                            .foregroundColor(Style.Color.secondary)
                    }

                    Spacer(minLength: Style.Spacing.x3)

                    if isSelected {
                        Icon("tick-02")
                            .foregroundColor(Style.Color.composerSend)
                    }

                    Color.clear
                        .frame(width: Style.Layout.entryContentPadding)
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

    // MARK: - New Sub-Collection Row

    /// Trailing row inside an expanded parent. Indented to align with sub rows;
    /// full-width bottom separator closes the expanded section like the last sub
    /// row used to.
    private var newSubCollectionRow: some View {
        VStack(spacing: 0) {
            Button {
                isNewSubVisible = true
            } label: {
                HStack(spacing: Style.Spacing.x3) {
                    Color.clear
                        .frame(width: 33 - Style.Spacing.x3)

                    Icon("add-circle")
                        .foregroundColor(Style.Color.primaryText)

                    Text("New sub-collection")
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.primaryText)
                        .lineLimit(1)

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

    // MARK: - Tap Logic

    private func handleParentTap(_ collection: Collection) {
        if selectedCollectionId == collection.id {
            // Already selected → deselect and collapse.
            selectedCollectionId = nil
            expandedCollectionId = nil
        } else {
            // Select and expand (even with zero subs, so the "New sub-collection"
            // row is reachable); collapse the previously expanded parent.
            selectedCollectionId = collection.id
            expandedCollectionId = collection.id
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
