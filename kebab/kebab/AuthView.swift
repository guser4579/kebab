import SwiftUI
import UIKit

struct AuthView: View {

    enum AuthFlow {
        case welcome
        case email
        case code
    }

    @ObservedObject var viewModel: AuthViewModel
    @State private var flow: AuthFlow = .welcome
    /// Tracks keyboard presence so bottom CTAs can sit close above the keyboard
    /// (contemporary ~12pt) while keeping a comfortable 40pt resting position
    /// when no keyboard is shown.
    @State private var isKeyboardVisible = false
    @FocusState private var isCodeFocused: Bool

    private var bottomButtonPadding: CGFloat {
        isKeyboardVisible ? 12 : 40
    }

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
                RoundedRectangle(cornerRadius: 24)
                    .fill(Style.Color.stickyNoteYellow)
                    .frame(width: 225, height: 225)
                    .overlay(alignment: .top) {
                        Text("kebab")
                            .font(Style.Typography.headerTitle())
                            .foregroundColor(Style.Color.background)
                            .frame(height: 24)
                            .padding(.top, 24)
                    }
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { isKeyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { isKeyboardVisible = false }
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
            .padding(.bottom, bottomButtonPadding)
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
            .padding(.bottom, bottomButtonPadding)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // Six digit boxes rendered over a single invisible full-width TextField.
    // The TextField owns the real input: it keeps the number pad, backspace
    // behavior, and — critically — keyboard OTP autofill via .oneTimeCode,
    // which custom per-digit inputs tend to break. The boxes are display-only
    // (allowsHitTesting(false)) so every tap lands on the field.
    private var codeField: some View {
        ZStack {
            TextField("", text: $viewModel.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundColor(.clear)
                .tint(.clear)
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .opacity(0.05)
                .focused($isCodeFocused)

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isCodeFocused = true
            }
        }
        .onChange(of: viewModel.code) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(6))
            if filtered != newValue {
                viewModel.code = filtered
                return
            }
            // Auto-submit once the sixth digit lands (typed or autofilled).
            if filtered.count == 6 && !viewModel.isLoading {
                Task { await viewModel.verifyOTP() }
            }
        }
    }

    private func digitBox(at index: Int) -> some View {
        let digits = Array(viewModel.code)
        let isCurrent = isCodeFocused && index == min(digits.count, 5)
        return Text(index < digits.count ? String(digits[index]) : "")
            .font(.custom("DMSans-Medium", size: 24))
            .foregroundColor(Style.Color.primaryText)
            .frame(width: 48, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Style.Color.composerBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isCurrent ? Style.Color.composerSend : Style.Color.separator,
                        lineWidth: 1
                    )
            )
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
