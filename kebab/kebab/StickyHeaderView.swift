//
//  StickyHeaderView.swift
//  kebab
//

import SwiftUI

struct StickyHeaderView: View {

    enum Tab: String, CaseIterable, Hashable {
        case feed
        case pinned
    }

    @Binding var selectedTab: StickyHeaderView.Tab
    var onSettingsTapped: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    @Namespace private var tabNamespace

    private let headerTotalHeight: CGFloat = 142
    private let topBarContentTopOffset: CGFloat = 60
    private let titleToTabsSpacing: CGFloat = 24
    private let tabLabelToIndicatorSpacing: CGFloat = 6
    private let tabIndicatorHeight: CGFloat = 4
    private let tabIndicatorCornerRadius: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: topBarContentTopOffset)

            topBar

            Color.clear
                .frame(height: titleToTabsSpacing)

            tabsRow

            Rectangle()
                .fill(Style.Color.separator)
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
                    Icon("settings")
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

    private var tabsRow: some View {
        HStack(spacing: 0) {
            ForEach(StickyHeaderView.Tab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: StickyHeaderView.Tab) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: tabLabelToIndicatorSpacing) {
                Text(tabTitle(tab))
                    .font(.custom("DMSans-Medium", size: 18))
                    .foregroundColor(selectedTab == tab ? Color.white : Style.Color.secondary)

                if selectedTab == tab {
                    RoundedRectangle(cornerRadius: tabIndicatorCornerRadius)
                        .fill(Style.Color.composerSend)
                        .frame(height: tabIndicatorHeight)
                        .matchedGeometryEffect(id: "tabIndicator", in: tabNamespace)
                } else {
                    Color.clear
                        .frame(height: tabIndicatorHeight)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func tabTitle(_ tab: StickyHeaderView.Tab) -> String {
        switch tab {
        case .feed: return "feed"
        case .pinned: return "pinned"
        }
    }
}
