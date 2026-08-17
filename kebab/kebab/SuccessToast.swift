//
//  SuccessToast.swift
//  kebab
//

import SwiftUI

/// The transient success confirmation — a slim capsule with a filled green
/// check, floating directly above the screen's primary action. Established by
/// Account's "Account updated"; shared so every success moment reads the same.
struct SuccessToast: View {

    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Style.Color.successForeground)

            Text(text)
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.successForeground)
        }
        .padding(.vertical, Style.Spacing.x2)
        .padding(.horizontal, 14)
        .background(Style.Color.successBackground, in: Capsule())
        .frame(maxWidth: .infinity)
    }
}
