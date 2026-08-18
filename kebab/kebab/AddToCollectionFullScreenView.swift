import SwiftUI

struct AddToCollectionFullScreenView: View {

    let entry: Entry
    /// Sticky header title. Defaults to "Add to collection"; pass "Move entry" for the move flow.
    let title: String
    let onDismiss: () -> Void
    /// Called on tick with (oldCollectionId, newCollectionId). The surface
    /// dismisses in the same beat — the host owns the local-first membership
    /// patch, background persistence, and failure rollback.
    let onConfirm: (UUID?, UUID?) -> Void

    /// Shared, already-loaded collections model (injected via environment) —
    /// the picker renders instantly instead of refetching on every open.
    @EnvironmentObject private var collectionsVM: CollectionsViewModel

    @State private var selectedCollectionId: UUID?
    @State private var initialCollectionId: UUID?
    /// The parent collection currently expanded in the picker; nil = all collapsed.
    @State private var expandedCollectionId: UUID?
    @State private var isNewCollectionVisible = false
    @State private var isNewSubVisible = false

    init(
        entry: Entry,
        title: String = "Add to collection",
        onDismiss: @escaping () -> Void,
        onConfirm: @escaping (UUID?, UUID?) -> Void
    ) {
        self.entry = entry
        self.title = title
        self.onDismiss = onDismiss
        self.onConfirm = onConfirm
    }

    private var hasChange: Bool {
        selectedCollectionId != initialCollectionId
    }

    private var tickInteractive: Bool {
        hasChange
    }

    // MARK: - Helpers

    private var parentCollections: [Collection] {
        collectionsVM.parentCollections
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
                            .padding(.horizontal, Style.Layout.entryContentPadding)

                        if initialCollectionId != nil {
                            noCollectionRow

                            Rectangle()
                                .fill(Style.Color.separator)
                                .frame(height: 1)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, Style.Layout.entryContentPadding)
                        }

                        ForEach(parentCollections) { parent in
                            parentRow(parent)

                            let subs = subCollections(for: parent.id)
                            if expandedCollectionId == parent.id {
                                VStack(spacing: 0) {
                                    ForEach(subs) { sub in
                                        subRow(sub)
                                    }
                                    newSubCollectionRow
                                }
                            }
                        }

                        // Breathing room so the last collection's expansion
                        // never crowds the screen edge.
                        Color.clear
                            .frame(height: 64)
                    }
                }
                .defaultScrollAnchor(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Style.Color.background)
        .ignoresSafeArea(edges: [.top, .bottom])
        .overlay {
            if isNewCollectionVisible {
                NewCollectionFullScreenView(
                    collectionsViewModel: collectionsVM,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isNewCollectionVisible = false
                        }
                    },
                    onSuccess: { created in
                        // Auto-select the newly created top-level collection by
                        // its actual id; cancelling never changes the selection.
                        selectedCollectionId = created.id
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
            // Membership comes straight off the entry — no network round trip,
            // so selection and expansion render on the first frame.
            if initialCollectionId == nil, let id = entry.collection_id {
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
            // Background freshness pass; the UI is already populated.
            await collectionsVM.loadCollections()
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
                        handleConfirm()
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
            // Deselecting collapses — instant snap, no animation.
            selectedCollectionId = nil
            expandedCollectionId = nil
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
                if selectedCollectionId == collection.id {
                    // Collapse is an instant snap; only expansion animates.
                    handleParentTap(collection)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        handleParentTap(collection)
                    }
                }
            } label: {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name.collectionDisplayName)
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
                .padding(.horizontal, Style.Layout.entryContentPadding)
        }
    }

    // MARK: - Sub-Collection Row

    /// Hierarchy is conveyed by indentation alone (40pt vs the parent's 16pt),
    /// matching the folder-picker convention (Outlook, Apple Mail, Dropbox).
    /// The vertical spine is deliberately absent — that's comment-thread
    /// language, not folder-hierarchy language.
    private func subRow(_ sub: Collection) -> some View {
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
                        .frame(width: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(sub.name.collectionDisplayName)
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
                .padding(.horizontal, Style.Layout.entryContentPadding)
        }
    }

    // MARK: - New Sub-Collection Row

    /// Trailing row inside an expanded parent, indented to align with sub rows.
    private var newSubCollectionRow: some View {
        VStack(spacing: 0) {
            Button {
                isNewSubVisible = true
            } label: {
                HStack(spacing: Style.Spacing.x3) {
                    Color.clear
                        .frame(width: 40 - Style.Spacing.x3)

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
                .padding(.horizontal, Style.Layout.entryContentPadding)
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

    /// Local-first: report the change and dismiss in the same beat. The host
    /// patches membership locally and persists behind with rollback.
    @MainActor
    private func handleConfirm() {
        guard tickInteractive else { return }
        onConfirm(initialCollectionId, selectedCollectionId)
        onDismiss()
    }
}
