//
//  DetailHeaderBar.swift
//  kebab
//

import SwiftUI

/// The pushed-screen header: a centred title with the back chevron on the
/// leading edge, closed by the 1pt rule. Shared by Entry and the Explore lens
/// lists so they stay identical.
struct DetailHeaderBar: View {

    let title: String
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            topBar

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

    private var topBar: some View {
        ZStack {
            Text(title)
                .font(Style.Typography.face(16, .medium))
                .foregroundColor(Style.Color.primaryText)

            HStack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Style.Color.secondary)
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Style.Spacing.x4)
            .frame(height: 24, alignment: .center)
        }
        .frame(height: 24)
    }
}
