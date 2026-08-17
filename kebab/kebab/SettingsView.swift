//
//  SettingsView.swift
//  kebab
//

import SwiftUI

struct SettingsView: View {

    let onClose: () -> Void
    @ObservedObject var authViewModel: AuthViewModel
    @ObservedObject var profileStore: ProfileStore

    @AppStorage("kebab.appearance") private var appearance = "dark"

    /// The panel's pushed detail pages.
    private enum Detail {
        case account
        case appearance
    }

    /// In-panel push state: a detail slides in from the right over the menu
    /// root, same manual offset choreography as the panel itself (never
    /// NavigationStack — settings lives outside any nav).
    @State private var openDetail: Detail? = nil
    /// Live finger translation while dragging the open detail page back.
    @State private var detailDragOffset: CGFloat = 0

    @State private var isDeleteConfirmPresented = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?

    private static let pushTransition: Animation = .spring(response: 0.36, dampingFraction: 1.0)

    private let contentTopOffset: CGFloat = 60
    private let rowPaddingVertical: CGFloat = 12
    private let rowPaddingHorizontal: CGFloat = 16
    private let containerCornerRadius: CGFloat = 16
    private let avatarSize: CGFloat = 64

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                rootPage
                    // Parallax: the root recedes while the detail covers it,
                    // so the pop reads as returning, not appearing.
                    .offset(x: openDetail != nil
                        ? -geometry.size.width * 0.25 + detailDragOffset * 0.25
                        : 0)

                detailPage(.account, geometry: geometry) {
                    AccountPageView(
                        profileStore: profileStore,
                        authViewModel: authViewModel,
                        isOpen: openDetail == .account,
                        onBack: { closeDetail() }
                    )
                }

                detailPage(.appearance, geometry: geometry) {
                    appearancePage
                }
            }
            // Detail pages wait one panel-width to the right; without
            // clipping they would poke out past the closed panel and sit over
            // the feed (closed −width + parked +width = on screen).
            .clipped()
        }
        .background(Style.Color.background)
        .ignoresSafeArea(edges: .all)
        .alert("Delete your account?", isPresented: $isDeleteConfirmPresented) {
            Button("Delete account", role: .destructive) {
                Task { await handleDeleteAccount() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes your kebab account and everything in it \u{2014} entries, comments, collections, and your profile. This can\u{2019}t be undone.")
        }
        .alert(
            "Couldn\u{2019}t delete account",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            if let deleteErrorMessage {
                Text(deleteErrorMessage)
            }
        }
    }

    private func handleDeleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await authViewModel.deleteAccount()
            // Success tears down the session; RootView presents the welcome
            // screen. Nothing left to do here.
        } catch {
            deleteErrorMessage = "Your account wasn\u{2019}t deleted. Check your connection and try again."
        }
    }

    private func closeDetail() {
        withAnimation(Self.pushTransition) {
            openDetail = nil
            detailDragOffset = 0
        }
    }

    /// Shared push container: parks the page one width right when closed,
    /// tracks the drag-back finger when open. Parked pages must not hit-test
    /// (clipping hides their pixels but NOT their hit area, so an invisible
    /// page would silently eat every touch meant for the feed).
    private func detailPage<Content: View>(
        _ detail: Detail,
        geometry: GeometryProxy,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = openDetail == detail
        return content()
            .offset(x: (isOpen ? detailDragOffset : 0) + (isOpen ? 0 : geometry.size.width))
            .allowsHitTesting(isOpen)
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        guard openDetail == detail else { return }
                        // Only rightward movement pulls the page back.
                        detailDragOffset = max(0, value.translation.width)
                    }
                    .onEnded { value in
                        guard openDetail == detail else { return }
                        let projected = value.predictedEndTranslation.width
                        if value.translation.width > 80 || projected > 200 {
                            closeDetail()
                        } else {
                            withAnimation(Self.pushTransition) {
                                detailDragOffset = 0
                            }
                        }
                    }
            )
    }

    // MARK: - Root page (menu)

    private var rootPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: contentTopOffset)

            headerRow(title: "Menu", showsBack: false)

            Color.clear
                .frame(height: 12)

            divider

            VStack(alignment: .leading, spacing: 0) {
                profileCard

                Color.clear
                    .frame(height: 28)

                sectionLabel("settings")

                Color.clear
                    .frame(height: Style.Spacing.x2)

                settingsGroup

                Color.clear
                    .frame(height: 28)

                sectionLabel("account")

                Color.clear
                    .frame(height: Style.Spacing.x2)

                accountGroup
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Style.Color.background)
    }

    // MARK: - Appearance page (pushed)

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: contentTopOffset)

            headerRow(title: "Appearance", showsBack: true)

            Color.clear
                .frame(height: 12)

            divider

            appearancePicker
                .padding(.horizontal, 16)
                .padding(.top, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Style.Color.background)
    }

    // MARK: - Header

    private func headerRow(title: String, showsBack: Bool) -> some View {
        HStack(spacing: Style.Spacing.x2) {
            if showsBack {
                Button {
                    closeDetail()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Style.Color.secondary)
                        .frame(width: Style.Icon.grid, height: Style.Icon.grid)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(title)
                .font(.custom("DMSans-Medium", size: 18))
                .foregroundColor(Style.Color.primaryText)

            Spacer(minLength: 0)

            // Close belongs to the Menu root only: a sub-screen offers one
            // exit — back — so the panel can't be torn down mid-flow.
            if !showsBack {
                Button {
                    onClose()
                } label: {
                    Icon("close")
                        .foregroundColor(Style.Color.primaryText)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Profile card (the Account destination)

    /// The identity card doubles as the Account entry point — avatar, name
    /// when set, email, and a trailing chevron announcing the push.
    private var profileCard: some View {
        Button {
            withAnimation(Self.pushTransition) {
                openDetail = .account
            }
        } label: {
            VStack(spacing: Style.Spacing.x3) {
                cardAvatar

                VStack(spacing: Style.Spacing.base) {
                    if let name = profileStore.displayName, !name.isEmpty {
                        Text(name)
                            .font(.custom("DMSans-Medium", size: 16))
                            .foregroundColor(Style.Color.primaryText)
                            .lineLimit(1)
                    }

                    Text(authViewModel.currentUserEmail ?? "")
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, rowPaddingHorizontal)
            .frame(maxWidth: .infinity)
            .background(Style.Color.composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: containerCornerRadius))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cardAvatar: some View {
        if let url = profileStore.avatarURL {
            CachedAsyncImage(url: url, contentMode: .fill)
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Style.Color.composerSend)
                .frame(width: avatarSize, height: avatarSize)
                .overlay(
                    Text(avatarInitial)
                        .font(.custom("DMSans-SemiBold", size: 26))
                        .foregroundColor(Style.Color.composerSendForeground)
                )
        }
    }

    private var avatarInitial: String {
        let source = profileStore.displayName ?? authViewModel.currentUserEmail
        guard let first = source?.trimmingCharacters(in: .whitespaces).first else { return "" }
        return String(first).uppercased()
    }

    // MARK: - Settings group

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Style.Typography.meta())
            .foregroundColor(Style.Color.secondary)
            .padding(.leading, Style.Spacing.base)
    }

    /// One container, one row per destination. New destinations are new
    /// rows here (or a new labeled group), never new inline controls —
    /// detail lives one level deeper.
    private var settingsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            navigationRow(
                label: "Appearance",
                symbol: "circle.lefthalf.filled",
                value: appearanceDisplayName
            ) {
                withAnimation(Self.pushTransition) {
                    openDetail = .appearance
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
    }

    private func navigationRow(
        label: String,
        symbol: String,
        value: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Style.Spacing.x3) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Style.Color.secondary)
                    .frame(width: Style.Icon.grid)

                Text(label)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)

                Spacer(minLength: 0)

                if let value {
                    Text(value)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Style.Color.secondary)
            }
            .padding(.vertical, rowPaddingVertical)
            .padding(.horizontal, rowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Account group (lifecycle actions)

    /// Sign out and delete share one grouped container — the account's exit
    /// paths together, the destructive one last in red.
    private var accountGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task {
                    await authViewModel.signOut()
                }
            } label: {
                HStack {
                    Text("Sign out")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Style.Color.primaryText)
                    Spacer(minLength: 0)
                    Icon("logout-05")
                        .foregroundColor(Style.Color.secondary)
                }
                .padding(.vertical, rowPaddingVertical)
                .padding(.horizontal, rowPaddingHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)

            rowDivider

            Button {
                isDeleteConfirmPresented = true
            } label: {
                HStack {
                    Text("Delete account")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Style.Color.destructive)
                    Spacer(minLength: 0)
                    if isDeleting {
                        ProgressView()
                            .tint(Style.Color.secondary)
                    } else {
                        Icon("trash-2")
                            .foregroundColor(Style.Color.destructive)
                    }
                }
                .padding(.vertical, rowPaddingVertical)
                .padding(.horizontal, rowPaddingHorizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
    }

    private var appearanceDisplayName: String {
        switch appearance {
        case "system": return "System"
        case "light": return "Light"
        default: return "Dark"
        }
    }

    // MARK: - Appearance picker (detail content)

    // Stacked option rows with a trailing tick on the active one — the
    // app's selection language (flat rows choose, tick marks the choice).
    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            appearanceRow("System", value: "system", symbol: "circle.lefthalf.filled")
            rowDivider
            appearanceRow("Light", value: "light", symbol: "sun.max")
            rowDivider
            appearanceRow("Dark", value: "dark", symbol: "moon")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, rowPaddingHorizontal)
    }

    private func appearanceRow(_ label: String, value: String, symbol: String) -> some View {
        Button {
            guard appearance != value else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                appearance = value
            }
        } label: {
            HStack(spacing: Style.Spacing.x3) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Style.Color.secondary)
                    .frame(width: Style.Icon.grid)

                Text(label)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)

                Spacer(minLength: 0)

                if appearance == value {
                    Icon("tick-02")
                        .foregroundColor(Style.Color.composerSend)
                }
            }
            .padding(.vertical, rowPaddingVertical)
            .padding(.horizontal, rowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
