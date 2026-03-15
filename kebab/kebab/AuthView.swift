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

            if flow == .welcome {
                Text("kebab")
                    .font(Style.Typography.headerTitle())
                    .foregroundColor(Style.Color.background)
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Welcome

    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Text("A place for thoughts you\ndon\u{2019}t want to lose.")
                    .font(Style.Typography.authTitle())
                    .foregroundColor(.white)
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)

                Button {
                    flow = .email
                } label: {
                    ZStack {
                        Text("Continue with email")
                            .font(Style.Typography.authButton())
                            .foregroundColor(.white)

                        HStack(spacing: 0) {
                            Icon("email")
                                .foregroundColor(.white)
                                .padding(.leading, Style.Spacing.composerPaddingLeft)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: Style.Layout.composerSingleLineHeight)
                    .frame(maxWidth: .infinity)
                    .background(Style.Color.composerBackground, in: Capsule())
                }
                .disabled(viewModel.isLoading)
                .padding(.top, 24)

                legalText
                    .font(Style.Typography.meta())
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
            }
        }
        .background(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 40,
                bottomTrailingRadius: 40,
                topTrailingRadius: 0
            )
            .fill(Style.Color.stickyNoteYellow)
            .frame(height: 300)
            .padding(.horizontal, 24)
            .ignoresSafeArea(.all, edges: .top)
        }
    }

    // MARK: - Email

    private var emailScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    Text("auth")
                        .font(.system(size: 18, weight: .medium).monospaced())
                        .foregroundColor(Style.Color.primaryText)
                        .frame(maxWidth: .infinity)

                    Button("Back") {
                        viewModel.email = ""
                        viewModel.resetFlow()
                        flow = .welcome
                    }
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.secondary)
                }

                Rectangle()
                    .fill(Style.Color.separator)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, -Style.Layout.entryContentPadding)
                    .padding(.top, Style.Layout.separatorSpacingBelowHeader)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)

            VStack(spacing: 0) {
                Text("Enter your email")
                    .font(Style.Typography.authTitle())
                    .foregroundColor(.white)
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                emailField
                    .padding(.top, 24)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)

            Spacer(minLength: 0)

            Button("Next") {
                Task {
                    await viewModel.sendOTP()
                    if viewModel.errorMessage == nil {
                        flow = .code
                    }
                }
            }
            .font(Style.Typography.authButton())
            .foregroundColor(Style.Color.background)
            .frame(height: Style.Layout.composerSingleLineHeight)
            .frame(maxWidth: .infinity)
            .background(.white, in: Capsule())
            .disabled(viewModel.isLoading)
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var emailField: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Style.Color.composerBackground)
                .frame(height: Style.Layout.composerSingleLineHeight)

            Icon("email")
                .foregroundColor(.white)
                .padding(.leading, Style.Spacing.composerPaddingLeft)

            if viewModel.email.isEmpty {
                Text("Enter email")
                    .font(Style.Typography.composerPlaceholder())
                    .foregroundColor(Style.Color.secondary)
                    .padding(.leading, 52)
            }

            TextField("", text: $viewModel.email)
                .font(Style.Typography.composerText())
                .foregroundColor(Style.Color.primaryText)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .keyboardType(.emailAddress)
                .padding(.leading, 52)
                .frame(height: Style.Layout.composerSingleLineHeight)
        }
    }

    // MARK: - Code (OTP)

    private var codeScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    Text("auth")
                        .font(.system(size: 18, weight: .medium).monospaced())
                        .foregroundColor(Style.Color.primaryText)
                        .frame(maxWidth: .infinity)

                    Button("Back") {
                        viewModel.email = ""
                        viewModel.resetFlow()
                        flow = .welcome
                    }
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.secondary)
                }

                Rectangle()
                    .fill(Style.Color.separator)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, -Style.Layout.entryContentPadding)
                    .padding(.top, Style.Layout.separatorSpacingBelowHeader)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)

            VStack(spacing: 0) {
                Text("Enter your code")
                    .font(Style.Typography.authTitle())
                    .foregroundColor(.white)
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                Text("We sent a code to your email. Enter it below.")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                codeField
                    .padding(.top, 24)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Button("Submit") {
                    Task { await viewModel.verifyOTP() }
                }
                .font(Style.Typography.authButton())
                .foregroundColor(Style.Color.background)
                .frame(height: Style.Layout.composerSingleLineHeight)
                .frame(maxWidth: .infinity)
                .background(.white, in: Capsule())
                .disabled(viewModel.isLoading)

                Button("I didn\u{2019}t receive a code") {
                    Task { await viewModel.sendOTP() }
                }
                .font(Style.Typography.authButton())
                .foregroundColor(.white)
                .frame(height: Style.Layout.composerSingleLineHeight)
                .frame(maxWidth: .infinity)
                .background(Style.Color.composerBackground, in: Capsule())
                .padding(.top, 16)

                Button("Use different email") {
                    viewModel.email = ""
                    viewModel.resetFlow()
                    flow = .email
                }
                .font(Style.Typography.authButton())
                .foregroundColor(.white)
                .padding(.top, 28)
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var codeField: some View {
        ZStack {
            Capsule()
                .fill(Style.Color.composerBackground)
                .frame(height: Style.Layout.composerSingleLineHeight)

            if viewModel.code.isEmpty {
                Text("Enter code")
                    .font(Style.Typography.composerPlaceholder())
                    .foregroundColor(Style.Color.secondary)
            }

            TextField("", text: $viewModel.code)
                .font(Style.Typography.composerText())
                .foregroundColor(Style.Color.primaryText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Style.Spacing.composerPaddingLeft)
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
            .foregroundColor(Style.Color.secondary)
            .underline()
        + Text(" and ")
            .foregroundColor(Style.Color.secondary)
        + Text("Privacy Policy")
            .foregroundColor(Style.Color.secondary)
            .underline()
        + Text(".")
            .foregroundColor(Style.Color.secondary)
    }
}
