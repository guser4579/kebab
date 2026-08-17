//
//  AccountPageView.swift
//  kebab
//

import SwiftUI
import PhotosUI

/// The Account detail page, pushed inside the Menu panel (same manual
/// choreography as Appearance). A focused profile editor: photo and optional
/// name staged as one change set behind an explicit Save, with the auth email
/// shown as read-only account information. Lifecycle actions (sign out,
/// delete) live on the Menu root, not here.
struct AccountPageView: View {

    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var authViewModel: AuthViewModel
    /// True while this page is the panel's open detail. Drives staged-edit
    /// reset on open and toast dismissal on close (chevron AND drag).
    let isOpen: Bool
    let onBack: () -> Void

    /// The staged (uncommitted) avatar decision. nil = unchanged.
    private enum StagedAvatar: Equatable {
        case replace(UIImage)
        case remove
    }

    @State private var nameText: String = ""
    @FocusState private var isNameFocused: Bool
    @State private var stagedAvatar: StagedAvatar? = nil

    @State private var isSaving = false
    @State private var saveFailed = false

    @State private var isPhotoDialogPresented = false
    @State private var isPhotosPickerPresented = false
    @State private var photoSelection: [PhotosPickerItem] = []
    /// Brief busy state while a picked photo loads from the library —
    /// uploading happens later, on Save.
    @State private var isLoadingPhoto = false
    @State private var photoLoadFailed = false

    @State private var isToastVisible = false
    /// Invalidates a stale auto-dismiss when a newer toast (or an early
    /// dismissal) supersedes it — same generation idiom as the post-capture
    /// strip.
    @State private var toastGeneration = 0

    private let contentTopOffset: CGFloat = 60
    private let rowPaddingVertical: CGFloat = 12
    private let rowPaddingHorizontal: CGFloat = 16
    private let containerCornerRadius: CGFloat = 16
    private let avatarSize: CGFloat = 96

    // MARK: - Staged state

    private var stagedName: String? {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(50))
    }

    /// One dirty flag for the whole change set — any difference from the
    /// persisted profile activates Save.
    private var isDirty: Bool {
        stagedAvatar != nil || stagedName != profileStore.displayName
    }

    /// Whether an avatar is showing right now, staged edits included.
    private var effectiveHasPhoto: Bool {
        switch stagedAvatar {
        case .replace: return true
        case .remove: return false
        case nil: return profileStore.avatarURL != nil
        }
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
                avatarBlock
                    .frame(maxWidth: .infinity)

                Color.clear
                    .frame(height: 28)

                sectionLabel("name")

                Color.clear
                    .frame(height: Style.Spacing.x2)

                nameGroup

                Color.clear
                    .frame(height: 28)

                sectionLabel("email")

                Color.clear
                    .frame(height: Style.Spacing.x2)

                emailGroup
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)

            Spacer(minLength: 0)

            // Bottom action block: the transient confirmation floats in the
            // space directly above Save; the spacer absorbs its height so
            // Save never moves and content is never covered.
            VStack(spacing: 0) {
                if isToastVisible {
                    SuccessToast(text: "Account updated")
                        .transition(.opacity)

                    Color.clear
                        .frame(height: 12)
                }

                saveButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Style.Color.background)
        .onChange(of: isOpen) { _, open in
            if open {
                resetStagedState()
                Task { await profileStore.refresh() }
            } else {
                isNameFocused = false
                dismissToast()
            }
        }
        .onChange(of: nameText) { _, text in
            if text.count > 50 {
                nameText = String(text.prefix(50))
            }
            // A fresh edit supersedes the confirmation. Focused-only so the
            // programmatic reset after a save can't dismiss its own toast.
            if isNameFocused {
                dismissToast()
            }
        }
        // Adopt a background refresh only while the field is untouched —
        // never over the user's staged edits.
        .onChange(of: profileStore.displayName) { _, name in
            if isOpen, !isNameFocused, !isDirty {
                nameText = name ?? ""
            }
        }
        .confirmationDialog("", isPresented: $isPhotoDialogPresented) {
            Button("Replace photo") {
                isPhotosPickerPresented = true
            }
            Button("Remove photo", role: .destructive) {
                stageRemovePhoto()
            }
            Button("Cancel", role: .cancel) { }
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photoSelection,
            maxSelectionCount: 1,
            matching: .images
        )
        .onChange(of: photoSelection) { _, items in
            guard let item = items.first else { return }
            photoSelection = []
            Task { await stagePickedPhoto(item) }
        }
        .alert("Couldn\u{2019}t save", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your changes didn\u{2019}t save. Check your connection and try again.")
        }
        .alert("Couldn\u{2019}t load photo", isPresented: $photoLoadFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("That photo couldn\u{2019}t be loaded. Try a different one.")
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

            Text("Account")
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Style.Typography.meta())
            .foregroundColor(Style.Color.secondary)
            .padding(.leading, Style.Spacing.base)
    }

    // MARK: - Avatar (staged)

    private var avatarBlock: some View {
        VStack(spacing: Style.Spacing.x3) {
            Button {
                handleAvatarTap()
            } label: {
                ZStack {
                    avatarCircle

                    if isLoadingPhoto {
                        Circle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: avatarSize, height: avatarSize)
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoadingPhoto || isSaving)

            Button {
                handleAvatarTap()
            } label: {
                Text(effectiveHasPhoto ? "Edit photo" : "Add photo")
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoadingPhoto || isSaving)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var avatarCircle: some View {
        switch stagedAvatar {
        case .replace(let image):
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
        case .remove:
            placeholderCircle
        case nil:
            if let url = profileStore.avatarURL {
                CachedAsyncImage(url: url, contentMode: .fill)
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
            } else {
                placeholderCircle
            }
        }
    }

    private var placeholderCircle: some View {
        Circle()
            .fill(Style.Color.composerSend)
            .frame(width: avatarSize, height: avatarSize)
            .overlay(
                Text(avatarInitial)
                    .font(.custom("DMSans-SemiBold", size: 36))
                    .foregroundColor(Style.Color.composerSendForeground)
            )
    }

    private var avatarInitial: String {
        let source = profileStore.displayName ?? authViewModel.currentUserEmail
        guard let first = source?.trimmingCharacters(in: .whitespaces).first else { return "" }
        return String(first).uppercased()
    }

    private func handleAvatarTap() {
        dismissToast()
        if effectiveHasPhoto {
            isPhotoDialogPresented = true
        } else {
            isPhotosPickerPresented = true
        }
    }

    /// Stages the picked image locally — nothing uploads until Save.
    private func stagePickedPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            photoLoadFailed = true
            return
        }
        stagedAvatar = .replace(image)
    }

    private func stageRemovePhoto() {
        // Removing a photo that only ever existed as a staged pick simply
        // unstages it; removing a persisted photo stages the removal.
        if profileStore.avatarURL != nil {
            stagedAvatar = .remove
        } else {
            stagedAvatar = nil
        }
    }

    // MARK: - Name

    private var nameGroup: some View {
        TextField("Enter name", text: $nameText)
            .font(Style.Typography.body())
            .foregroundColor(Style.Color.primaryText)
            .tint(Style.Color.composerSend)
            .focused($isNameFocused)
            .submitLabel(.done)
            .onSubmit {
                isNameFocused = false
            }
            .padding(.vertical, rowPaddingVertical)
            .padding(.horizontal, rowPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.Color.composerBackground)
            .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
    }

    // MARK: - Email (read-only account information)

    private var emailGroup: some View {
        HStack(spacing: Style.Spacing.x3) {
            // The welcome screen's email glyph, quieted to match the
            // read-only address beside it.
            Icon("email")
                .foregroundColor(Style.Color.secondary)

            Spacer(minLength: 0)

            Text(authViewModel.currentUserEmail ?? "")
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, rowPaddingVertical)
        .padding(.horizontal, rowPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.Color.composerBackground)
        .clipShape(RoundedRectangle(cornerRadius: containerCornerRadius))
    }

    // MARK: - Save

    /// The auth primary CTA treatment: filled capsule, dimmed while there is
    /// nothing to save (the app's inactive-control opacity).
    private var saveButton: some View {
        Button {
            Task { await handleSave() }
        } label: {
            ZStack {
                if isSaving {
                    ProgressView()
                        .tint(Style.Color.composerSendForeground)
                } else {
                    Text("Save")
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
        .opacity(isDirty || isSaving ? 1 : 0.35)
        .disabled(!isDirty || isSaving)
        .animation(.easeInOut(duration: 0.2), value: isDirty)
    }

    private func handleSave() async {
        guard isDirty, !isSaving else { return }
        isNameFocused = false
        isSaving = true
        defer { isSaving = false }

        let avatarEdit: ProfileStore.AvatarEdit
        switch stagedAvatar {
        case .replace(let image): avatarEdit = .replace(image)
        case .remove: avatarEdit = .remove
        case nil: avatarEdit = .keep
        }

        let ok = await profileStore.applyEdits(
            displayName: nameText,
            avatarEdit: avatarEdit
        )
        if ok {
            stagedAvatar = nil
            nameText = profileStore.displayName ?? ""
            showToast()
        } else {
            // Staged edits stay exactly as they are; Save remains active.
            saveFailed = true
        }
    }

    private func resetStagedState() {
        nameText = profileStore.displayName ?? ""
        stagedAvatar = nil
        dismissToast()
    }

    // MARK: - Success toast

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
        guard isToastVisible else {
            toastGeneration += 1
            return
        }
        toastGeneration += 1
        withAnimation(.easeInOut(duration: 0.25)) {
            isToastVisible = false
        }
    }
}
