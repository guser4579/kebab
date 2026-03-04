import SwiftUI

struct AuthView: View {

    enum AuthFlow {
        case welcome
        case email
        case code
    }

    @ObservedObject var viewModel: AuthViewModel
    @State private var flow: AuthFlow = .welcome

    var body: some View {
        ZStack {
            Style.Color.background
                .ignoresSafeArea()

            Group {
                switch flow {
                case .welcome:
                    welcomeScreen
                case .email:
                    emailScreen
                case .code:
                    codeScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Style.Layout.entryContentPadding)
        }
    }

    // MARK: - Welcome

    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("kebab")
                    .font(.system(size: 24, weight: .medium).monospaced())
                    .foregroundColor(Style.Color.primaryText)

                Text("Unifying fragmented thoughts.")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .padding(.top, Style.Layout.bodyBelowKebab)
                    .multilineTextAlignment(.center)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .padding(.top, Style.Layout.bodyBelowKebab)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, Style.Layout.welcomeTopOffset)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Button("Sign up") {
                    flow = .email
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Style.Color.primaryText)
                .frame(height: Style.Layout.composerSingleLineHeight)
                .frame(maxWidth: .infinity)
                .background(Style.Color.composerSend, in: Capsule())
                .disabled(viewModel.isLoading)

                Button("Sign in") {
                    flow = .email
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Style.Color.primaryText)
                .padding(.top, Style.Layout.signInBelowPrimary)

                legalText
                    .font(Style.Typography.meta())
                    .multilineTextAlignment(.center)
                    .padding(.top, Style.Layout.legalBelowSignIn)
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Email

    private var emailScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("auth")
                    .font(.system(size: 18, weight: .medium).monospaced())
                    .foregroundColor(Style.Color.primaryText)

                Rectangle()
                    .fill(Style.Color.separator)
                    .frame(height: 1)
                    .padding(.top, Style.Layout.separatorSpacingBelowHeader)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)

            VStack(spacing: 0) {
                Text("kebab")
                    .font(.system(size: 24, weight: .medium).monospaced())
                    .foregroundColor(Style.Color.primaryText)

                Text("Enter your email below.")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .padding(.top, Style.Layout.bodyBelowKebab)
                    .multilineTextAlignment(.center)

                emailField
                    .padding(.top, Style.Layout.inputBelowBody)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .padding(.top, Style.Layout.bodyBelowKebab)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Style.Layout.kebabBelowHeader)

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                primaryButton(title: "Submit") {
                    Task {
                        await viewModel.sendOTP()
                        if viewModel.errorMessage == nil {
                            flow = .code
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var emailField: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Style.Color.composerBackground)
                .frame(height: Style.Layout.composerSingleLineHeight)

            if viewModel.email.isEmpty {
                Text("Enter email")
                    .font(Style.Typography.composerPlaceholder())
                    .foregroundColor(Style.Color.secondary)
                    .padding(.leading, Style.Spacing.composerPaddingLeft)
            }

            TextField("", text: $viewModel.email)
                .font(Style.Typography.composerText())
                .foregroundColor(Style.Color.primaryText)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .keyboardType(.emailAddress)
                .padding(.leading, Style.Spacing.composerPaddingLeft)
                .frame(height: Style.Layout.composerSingleLineHeight)
        }
    }

    // MARK: - Code (OTP)

    private var codeScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("auth")
                    .font(.system(size: 18, weight: .medium).monospaced())
                    .foregroundColor(Style.Color.primaryText)

                Rectangle()
                    .fill(Style.Color.separator)
                    .frame(height: 1)
                    .padding(.top, Style.Layout.separatorSpacingBelowHeader)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)

            VStack(spacing: 0) {
                Text("kebab")
                    .font(.system(size: 24, weight: .medium).monospaced())
                    .foregroundColor(Style.Color.primaryText)

                Text("Enter the 6-digit passcode sent to your email.")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .padding(.top, Style.Layout.bodyBelowKebab)
                    .multilineTextAlignment(.center)

                codeField
                    .padding(.top, Style.Layout.inputBelowBody)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .padding(.top, Style.Layout.bodyBelowKebab)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Style.Layout.kebabBelowHeader)

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                primaryButton(title: "Submit") {
                    Task { await viewModel.verifyOTP() }
                }

                Button("I didn't receive a code") {
                    Task { await viewModel.sendOTP() }
                }
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .padding(.top, Style.Layout.signInBelowPrimary)

                Button("Use a different email address") {
                    viewModel.resetFlow()
                    flow = .email
                }
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .padding(.top, Style.Layout.signInBelowPrimary)
            }
            .padding(.bottom, 8)
        }
    }

    private var codeField: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Style.Color.composerBackground)
                .frame(height: Style.Layout.composerSingleLineHeight)

            if viewModel.code.isEmpty {
                Text("Enter code")
                    .font(Style.Typography.composerPlaceholder())
                    .foregroundColor(Style.Color.secondary)
                    .padding(.leading, Style.Spacing.composerPaddingLeft)
            }

            TextField("", text: $viewModel.code)
                .font(Style.Typography.composerText())
                .foregroundColor(Style.Color.primaryText)
                .keyboardType(.numberPad)
                .padding(.leading, Style.Spacing.composerPaddingLeft)
                .frame(height: Style.Layout.composerSingleLineHeight)
        }
    }

    // MARK: - Shared

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(Style.Color.primaryText)
            .frame(height: Style.Layout.composerSingleLineHeight)
            .frame(maxWidth: .infinity)
            .background(Style.Color.composerSend, in: Capsule())
            .disabled(viewModel.isLoading)
    }

    private var legalText: some View {
        Text("By continuing you are agreeing to the ")
            .foregroundColor(Style.Color.secondary)
        + Text("Terms of Service")
            .foregroundColor(Style.Color.composerSend)
            .underline()
        + Text(" and ")
            .foregroundColor(Style.Color.secondary)
        + Text("Privacy Policy")
            .foregroundColor(Style.Color.composerSend)
            .underline()
        + Text(".")
            .foregroundColor(Style.Color.secondary)
    }
}
