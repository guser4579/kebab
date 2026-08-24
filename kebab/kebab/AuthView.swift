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
    /// Measured height of the welcome copy + CTA + legal block, so the demo
    /// stack overlay can bottom out above it without ever pushing it around.
    @State private var welcomeCopyHeight: CGFloat = 0
    /// Measured height of the wordmark, so the demo stack overlay knows where
    /// the open field below it begins.
    @State private var wordmarkHeight: CGFloat = 0

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
        GeometryReader { geo in
            VStack(spacing: 0) {
                Text("kebab")
                    .font(Style.Typography.authWordmark())
                    .foregroundColor(Style.Color.primaryText)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        wordmarkHeight = $0
                    }
                    .padding(.top, Style.Spacing.x4)

                // Open space lives here, between the wordmark and the
                // bottom-anchored copy + CTA group, so headline → sub-copy
                // → button read as one intentional composition.
                Spacer(minLength: Style.Spacing.x4)

                // Everything below the spacer is measured as one block so the
                // demo stack knows exactly where the locked copy begins.
                VStack(spacing: 0) {
                Group {
                    Text("Keep what you notice")
                        .font(Style.Typography.authTitle())
                        .foregroundColor(Style.Color.primaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Style.Layout.entryContentPadding)

                    Text("Like texting yourself, but better. A private place for thoughts, links, questions, and the little things you want to come back to.")
                        .font(Style.Typography.body())
                        .foregroundColor(Style.Color.primaryText)
                        .lineSpacing(Style.Typography.bodyLineHeight - 16)
                        .multilineTextAlignment(.center)
                        .padding(.top, Style.Spacing.x3)
                        .padding(.horizontal, Style.Layout.entryContentPadding + Style.Spacing.x2)
                }
                .frame(maxWidth: .infinity)

                Button {
                    flow = .email
                } label: {
                    ZStack {
                        Text("Continue with email")
                            .font(Style.Typography.authButton())
                            .foregroundColor(Style.Color.primaryText)

                        HStack(spacing: 0) {
                            Icon("email")
                                .foregroundColor(Style.Color.primaryText)
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
                .padding(.horizontal, Style.Layout.entryContentPadding)

                legalText
                    .font(Style.Typography.meta())
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                    // Measured from the physical bottom edge — the screen
                    // ignores the bottom container inset below — so the
                    // legal line sits low in the home-indicator band while
                    // staying clear of the indicator itself.
                    .padding(.bottom, 24)
                    .padding(.horizontal, Style.Layout.entryContentPadding)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    welcomeCopyHeight = $0
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .topLeading) {
                welcomeDemoStack(geo: geo)
            }
            .background {
                // Ambient monochrome field behind the whole welcome surface.
                // Purely decorative: no layout participation, no touches.
                MetaballBackground()
                    .ignoresSafeArea()
            }
        }
        // The copy block anchors to the physical bottom (its own 24pt
        // padding is the entire clearance) instead of stacking padding on
        // top of the 34pt home-indicator inset, which read as a dead band
        // under the legal text. `.container` only — never the keyboard.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// Positions the ambient demo-entry deck in the open region between the
    /// wordmark and the locked copy block. An overlay (not a layout
    /// participant), so the cycling cards can never move the headline or CTA.
    /// The deck occupies one stable location: every front card starts at the
    /// same fixed top edge and shorter cards simply end higher. The deck
    /// bottoms out against the copy block, so spare room reads as breathing
    /// space under the wordmark. It renders full-width, scaling down only
    /// when the tallest example genuinely cannot fit (short screens).
    private func welcomeDemoStack(geo: GeometryProxy) -> some View {
        let copyHeight = welcomeCopyHeight > 0 ? welcomeCopyHeight : 260
        let markHeight = wordmarkHeight > 0 ? wordmarkHeight : 32
        let regionTop = Style.Spacing.x4 + markHeight + Style.Spacing.x4
        let stackBottom = geo.size.height - copyHeight - Style.Spacing.x3
        let scale = min(1, max(0.75, (stackBottom - regionTop) / WelcomeDemoStackView.designHeight))
        let top = max(regionTop, stackBottom - WelcomeDemoStackView.designHeight * scale)

        return WelcomeDemoStackView()
            .frame(width: geo.size.width)
            .scaleEffect(scale, anchor: .top)
            .offset(y: top)
            .allowsHitTesting(false)
    }

    // MARK: - Email

    private var emailScreen: some View {
        VStack(spacing: 0) {
            authHeader {
                viewModel.email = ""
                viewModel.resetFlow()
                flow = .welcome
            }

            VStack(spacing: 0) {
                Text("Enter your email")
                    .font(Style.Typography.authTitle())
                    .foregroundColor(Style.Color.primaryText)
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

            primaryCTA("Next") {
                Task {
                    await viewModel.sendOTP()
                    if viewModel.errorMessage == nil {
                        flow = .code
                    }
                }
            }
            .padding(.bottom, bottomButtonPadding)
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }

    private var emailField: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Style.Color.composerBackground)
                .frame(height: Style.Layout.composerSingleLineHeight)

            Icon("email")
                .foregroundColor(Style.Color.primaryText)
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
            authHeader {
                viewModel.email = ""
                viewModel.resetFlow()
                flow = .welcome
            }

            VStack(spacing: 0) {
                Text("Enter your code")
                    .font(Style.Typography.authTitle())
                    .foregroundColor(Style.Color.primaryText)
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
                primaryCTA("Submit") {
                    Task { await viewModel.verifyOTP() }
                }

                secondaryCTA("I didn\u{2019}t receive a code") {
                    Task { await viewModel.sendOTP() }
                }
                .padding(.top, 16)

                Button("Use different email") {
                    viewModel.email = ""
                    viewModel.resetFlow()
                    flow = .email
                }
                .font(Style.Typography.authButton())
                .foregroundColor(Style.Color.primaryText)
                .padding(.top, 28)
            }
            .padding(.bottom, bottomButtonPadding)
        }
        .padding(.horizontal, Style.Layout.entryContentPadding)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
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
            // Light haptic signals "submitted" since no button was pressed.
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

    /// Quiet sub-screen header shared by the email and OTP steps: the
    /// app-standard 60pt offset from the physical top (Search/Settings use
    /// the same) with a lone back chevron — no title, no divider.
    private func authHeader(onBack: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Style.Layout.authHeaderTopOffset)

            HStack(spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Style.Color.secondary)
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
    }

    /// Full-width primary CTA. The frame, background, and contentShape live
    /// INSIDE the button label so the entire capsule is the touch target —
    /// with the default `Button("title")` form only the text itself was
    /// tappable, which read as an unresponsive button. Shows a spinner and
    /// disables while an auth request is in flight; haptic confirms the tap.
    private func primaryCTA(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            ZStack {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(Style.Color.composerSendForeground)
                } else {
                    Text(title)
                        .font(Style.Typography.authButton())
                        .foregroundColor(Style.Color.composerSendForeground)
                }
            }
            .frame(height: Style.Layout.composerSingleLineHeight)
            .frame(maxWidth: .infinity)
            .background(Style.Color.composerSend, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
    }

    /// Full-width secondary CTA (dark capsule); same full-capsule touch target.
    private func secondaryCTA(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(Style.Typography.authButton())
                .foregroundColor(Style.Color.primaryText)
                .opacity(viewModel.isLoading ? 0.4 : 1)
                .frame(height: Style.Layout.composerSingleLineHeight)
                .frame(maxWidth: .infinity)
                .background(Style.Color.composerBackground, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
