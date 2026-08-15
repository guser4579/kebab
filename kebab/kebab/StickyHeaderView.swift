//
//  StickyHeaderView.swift
//  kebab
//

import SwiftUI

/// App header: settings, wordmark, search. The feed/collections tab row was
/// sunset when the chip bar became the primary way to navigate collections.
struct StickyHeaderView: View {

    var onSettingsTapped: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    /// The feed screen hides this hairline: the collection nav bar directly
    /// below draws the single separator between chrome and feed.
    var showsBottomSeparator: Bool = true

    private let headerTotalHeight: CGFloat = 101
    private let topBarContentTopOffset: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: topBarContentTopOffset)

            topBar

            Color.clear
                .frame(height: 16)

            Rectangle()
                .fill(showsBottomSeparator ? Style.Color.separator : SwiftUI.Color.clear)
                .frame(height: 1)
        }
        .frame(height: headerTotalHeight)
        .frame(maxWidth: .infinity)
        .background(Style.Color.background)
    }

    private var topBar: some View {
        ZStack {
            Text("kebab")
                .font(Style.Typography.headerTitle())
                .foregroundColor(Style.Color.primaryText)

            HStack {
                Button {
                    onSettingsTapped?()
                } label: {
                    // Hamburger: settings lives on the left side of the app.
                    Icon("menu")
                        .foregroundColor(Style.Color.primaryText)
                }
                Spacer(minLength: 0)
                Button {
                    onSearchTapped?()
                } label: {
                    Icon("search")
                        .foregroundColor(Style.Color.primaryText)
                }
            }
            .padding(.horizontal, Style.Spacing.x4)
        }
        .frame(height: 24)
    }
}
