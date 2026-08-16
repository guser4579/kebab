//
//  SettingsView.swift
//  kebab
//

import SwiftUI

struct SettingsView: View {

    let onClose: () -> Void
    @ObservedObject var authViewModel: AuthViewModel

    @AppStorage("kebab.appearance") private var appearance = "dark"

    /// In-panel push state: the appearance detail slides in from the right
    /// over the menu root, same manual offset choreography as the panel
    /// itself (never NavigationStack — settings lives outside any nav).
    @State private var isAppearanceOpen = false
    /// Live finger translation while dragging the detail page back.
    @State private var detailDragOffset: CGFloat = 0

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
                    .offset(x: isAppearanceOpen
                        ? -geometry.size.width * 0.25 + detailDragOffset * 0.25
                        : 0)

                appearancePage
                    .offset(x: (isAppearanceOpen ? 0 : geometry.size.width) + detailDragOffset)
                    // Parked one width to the right, the page still overlaps
                    // the closed panel's neighborhood on screen; clipping hides
                    // its pixels but NOT its hit area, so it would silently eat
                    // every touch meant for the feed.
                    .allowsHitTesting(isAppearanceOpen)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 15)
                            .onChanged { value in
                                guard isAppearanceOpen else { return }
                                // Only rightward movement pulls the page back.
                                detailDragOffset = max(0, value.translation.width)
                            }
                            .onEnded { value in
                                guard isAppearanceOpen else { return }
                                let projected = value.predictedEndTranslation.width
                                if value.translation.width > 80 || projected > 200 {
                                    withAnimation(Self.pushTransition) {
                                        isAppearanceOpen = false
                                        detailDragOffset = 0
                                    }
                                } else {
                                    withAnimation(Self.pushTransition) {
                                        detailDragOffset = 0
                                    }
                                }
                            }
                    )
            }
            // The detail page waits one panel-width to the right; without
            // clipping it would poke out past the closed panel and sit over
            // the feed (closed −width + parked +width = on screen).
            .clipped()
        }
        .background(Style.Color.background)
        .ignoresSafeArea(edges: .all)
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)

            Spacer(minLength: 0)

            // Account exit stays alone at the bottom edge: distance from the
            // everyday rows is the destructive treatment.
            logOutContainer
                .padding(.horizontal, 16)
                .padding(.bottom, 48)
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
                    withAnimation(Self.pushTransition) {
                        isAppearanceOpen = false
                    }
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

    // MARK: - Profile card

    private var profileCard: some View {
        VStack(spacing: Style.Spacing.x3) {
            Circle()
                .fill(Style.Color.composerSend)
                .frame(width: avatarSize, height: avatarSize)
                .overlay(
                    Text(avatarInitial)
                        .font(.custom("DMSans-SemiBold", size: 26))
                        .foregroundColor(Style.Color.composerSendForeground)
                )

            Text(authViewModel.currentUserEmail ?? "")
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, rowPaddingHorizontal)
        .frame(maxWidth: .infinity)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
    }

    private var avatarInitial: String {
        guard let first = authViewModel.currentUserEmail?.first else { return "" }
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
                    isAppearanceOpen = true
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

    // MARK: - Log out

    private var logOutContainer: some View {
        Button {
            Task {
                await authViewModel.signOut()
            }
        } label: {
            HStack {
                Text("Log out")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Style.Color.destructive)
                Spacer(minLength: 0)
                Icon("logout-05")
                    .foregroundColor(Style.Color.destructive)
            }
            .padding(.vertical, rowPaddingVertical)
            .padding(.horizontal, rowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.Color.composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
        }
        .buttonStyle(.plain)
    }
}
