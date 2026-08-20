//
//  FeedbackPageView.swift
//  kebab
//

import SwiftUI

/// The feedback screen, pushed inside the Menu panel. One dominant free-form
/// field, optional identity (prefilled, clearable), one send action — no
/// categories, ratings, or support-ticket machinery.
struct FeedbackPageView: View {

    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var authViewModel: AuthViewModel
    /// True while this page is the panel's open detail. Drives prefill on
    /// open and toast dismissal on close (chevron AND drag).
    let isOpen: Bool
    let onBack: () -> Void

    @Environment(\.supabase) private var supabase

    private enum Field {
        case name, email, message
    }

    @State private var nameText = ""
    @State private var emailText = ""
    @State private var messageText = ""
    @FocusState private var focusedField: Field?

    @State private var isSending = false
    @State private var sendFailed = false

    @State private var isToastVisible = false
    /// Same generation idiom as the Account toast — supersedes stale
    /// auto-dismissals without queueing.
    @State private var toastGeneration = 0

    private let contentTopOffset: CGFloat = 60
    private let rowPaddingVertical: CGFloat = 12
    private let rowPaddingHorizontal: CGFloat = 16
    private let containerCornerRadius: CGFloat = 16

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: contentTopOffset)

            headerRow

            Color.clear
                .frame(height: 12)

            divider

            VStack(alignment: .leading, spacing: 0) {
                Text("Help improve Kebab by sharing your feedback! If something feels wrong, missing, or especially good, I\u{2019}d love to know.")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Color.clear
                    .frame(height: 20)

                identityGroup

                Color.clear
                    .frame(height: Style.Spacing.x3)

                messageGroup
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                if isToastVisible {
                    SuccessToast(text: "Feedback sent. Thank you.")
                        .transition(.opacity)

                    Color.clear
                        .frame(height: 12)
                }

                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Style.Color.background)
        .onChange(of: isOpen) { _, open in
            if open {
                // Identity prefills from what kebab already knows; both stay
                // editable and clearable, and neither is required.
                nameText = profileStore.displayName ?? ""
                emailText = authViewModel.currentUserEmail ?? ""
                messageText = ""
                dismissToast()
            } else {
                focusedField = nil
                dismissToast()
            }
        }
        .onChange(of: messageText) { _, _ in
            if focusedField == .message {
                dismissToast()
            }
        }
        .alert("Couldn\u{2019}t send feedback", isPresented: $sendFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your feedback didn\u{2019}t go through. Check your connection and try again.")
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: Style.Spacing.x2) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Style.Color.secondary)
                    .frame(width: Style.Icon.grid, height: Style.Icon.grid)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Send feedback")
                .font(.custom("DMSans-Medium", size: 18))
                .foregroundColor(Style.Color.primaryText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Fields

    private var identityGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Name", text: $nameText)
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .tint(Style.Color.composerSend)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusedField = .email }
                .padding(.vertical, rowPaddingVertical)
                .padding(.horizontal, rowPaddingHorizontal)

            rowDivider

            TextField("Email", text: $emailText)
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .tint(Style.Color.composerSend)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .message }
                .padding(.vertical, rowPaddingVertical)
                .padding(.horizontal, rowPaddingHorizontal)
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

    /// The dominant field — the reason the screen exists.
    private var messageGroup: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $messageText)
                .font(Style.Typography.body())
                .foregroundColor(Style.Color.primaryText)
                .tint(Style.Color.composerSend)
                .scrollContentBackground(.hidden)
                .focused($focusedField, equals: .message)
                .padding(.vertical, rowPaddingVertical - 8)
                .padding(.horizontal, rowPaddingHorizontal - 5)

            if messageText.isEmpty {
                Text("What should I know?")
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.secondary)
                    .padding(.vertical, rowPaddingVertical)
                    .padding(.horizontal, rowPaddingHorizontal)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 168)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
        .onTapGesture {
            focusedField = .message
        }
    }

    // MARK: - Send

    private var sendButton: some View {
        Button {
            Task { await handleSend() }
        } label: {
            ZStack {
                if isSending {
                    ProgressView()
                        .tint(Style.Color.composerSendForeground)
                } else {
                    Text("Send feedback")
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
        .opacity(canSend || isSending ? 1 : 0.35)
        .disabled(!canSend || isSending)
        .animation(.easeInOut(duration: 0.2), value: canSend)
    }

    private func handleSend() async {
        guard canSend, !isSending, let supabase else { return }
        focusedField = nil
        isSending = true
        defer { isSending = false }

        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = emailText.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await FeedbackRepository(supabase: supabase).submit(
                userId: authViewModel.currentUserId,
                name: trimmedName.isEmpty ? nil : trimmedName,
                email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                message: messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            messageText = ""
            showToast()
        } catch {
            // Everything typed stays put; the user can retry.
            sendFailed = true
        }
    }

    // MARK: - Toast

    private func showToast() {
        toastGeneration += 1
        let generation = toastGeneration
        withAnimation(.easeInOut(duration: 0.25)) {
            isToastVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
            guard toastGeneration == generation else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isToastVisible = false
            }
        }
    }

    private func dismissToast() {
        toastGeneration += 1
        guard isToastVisible else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            isToastVisible = false
        }
    }
}
