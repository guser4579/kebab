//
//  EditEntryFullScreenView.swift
//  kebab
//

import SwiftUI
import UIKit

// The editor internals (FocusingTextView + FullScreenTextEditor) live in
// FullScreenTextEditor.swift, shared with the full-screen composer.

// MARK: - Full-screen edit

struct EditEntryFullScreenView: View {

    let entry: Entry
    let initialText: String
    @ObservedObject var feedViewModel: FeedViewModel
    let onDismiss: () -> Void
    /// Called after a successful save, before dismiss.
    var onPersistSuccess: (() -> Void)?
    /// Merge updated text into local detail state when the edited row is the screen’s root item.
    var onSaveSuccess: ((Entry) -> Void)?

    @State private var text: String
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    init(
        entry: Entry,
        initialText: String,
        feedViewModel: FeedViewModel,
        onDismiss: @escaping () -> Void,
        onPersistSuccess: (() -> Void)? = nil,
        onSaveSuccess: ((Entry) -> Void)? = nil
    ) {
        self.entry = entry
        self.initialText = initialText
        self.feedViewModel = feedViewModel
        self.onDismiss = onDismiss
        self.onPersistSuccess = onPersistSuccess
        self.onSaveSuccess = onSaveSuccess
        _text = State(initialValue: initialText)
    }

    private var trimmedOriginal: String {
        initialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDraft: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save control: never persist empty trimmed text; allow tick when unchanged to dismiss only.
    private var tickInteractive: Bool {
        !trimmedDraft.isEmpty && !isSaving
    }

    private var needsBackendSave: Bool {
        trimmedDraft != trimmedOriginal
    }

    var body: some View {
        VStack(spacing: 0) {
            editHeader

            FullScreenTextEditor(text: $text)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, Style.Layout.entryContentPadding)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .background(Style.Color.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Style.Color.background)
        .ignoresSafeArea(edges: [.top, .bottom])
        .alert("Couldn’t save", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                saveErrorMessage = nil
            }
        } message: {
            if let saveErrorMessage {
                Text(saveErrorMessage)
            }
        }
    }

    private var editHeader: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            ZStack {
                Text("Edit")
                    .font(.custom("DMSans-Medium", size: 16))
                    .foregroundColor(Style.Color.primaryText)

                HStack {
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        onDismiss()
                    } label: {
                        Icon("close")
                            .foregroundColor(Style.Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        Task { await handlePrimaryAction() }
                    } label: {
                        Icon("tick-02")
                            .foregroundColor(
                                tickInteractive
                                ? Style.Color.composerSend
                                : Style.Color.secondary.opacity(0.35)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!tickInteractive)
                }
                .padding(.horizontal, Style.Spacing.x4)
                .frame(height: 24, alignment: .center)
            }
            .frame(height: 24)

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

    @MainActor
    private func handlePrimaryAction() async {
        guard tickInteractive else { return }
        if !needsBackendSave {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            Haptics.mediumTap()
            onDismiss()
            return
        }

        isSaving = true
        let ok = await feedViewModel.updateEntryContent(id: entry.id, content: trimmedDraft)
        isSaving = false

        if ok {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            Haptics.mediumTap()
            onPersistSuccess?()
            onSaveSuccess?(entry.withContent(trimmedDraft))
            onDismiss()
        } else {
            saveErrorMessage = feedViewModel.errorMessage ?? "Something went wrong."
        }
    }
}
