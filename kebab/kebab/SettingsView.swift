//
//  SettingsView.swift
//  kebab
//

import SwiftUI

struct SettingsView: View {

    let onClose: () -> Void
    @ObservedObject var authViewModel: AuthViewModel

    private let contentTopOffset: CGFloat = 60
    private let headerHorizontalPadding: CGFloat = 16
    private let containerSpacing: CGFloat = 8
    private let containerPaddingHorizontal: CGFloat = 16
    private let rowPaddingVertical: CGFloat = 12
    private let rowPaddingHorizontal: CGFloat = 16
    private let rowCornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: contentTopOffset)

            headerRow

            Color.clear
                .frame(height: 12)

            headerDivider

            VStack(alignment: .leading, spacing: containerSpacing) {
                emailContainer
                logOutContainer
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Style.Color.background)
        .ignoresSafeArea(edges: .all)
    }

    private var headerRow: some View {
        HStack {
            Text("settings")
                .font(.custom("DMMono-Medium", size: 18))
                .foregroundColor(Style.Color.primaryText)

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.28)) {
                    onClose()
                }
            } label: {
                Icon("close")
                    .foregroundColor(Style.Color.primaryText)
            }
        }
        .padding(.horizontal, 16)
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var emailContainer: some View {
        HStack {
            Text(authViewModel.currentUserEmail ?? "")
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
            Spacer(minLength: 0)
            Icon("email")
                .foregroundColor(Style.Color.secondary)
        }
        .padding(.top, rowPaddingVertical)
        .padding(.bottom, rowPaddingVertical)
        .padding(.leading, rowPaddingHorizontal)
        .padding(.trailing, rowPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: rowCornerRadius))
    }

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
            .padding(.top, rowPaddingVertical)
            .padding(.bottom, rowPaddingVertical)
            .padding(.leading, rowPaddingHorizontal)
            .padding(.trailing, rowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.Color.composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: rowCornerRadius))
        }
        .buttonStyle(.plain)
    }
}
