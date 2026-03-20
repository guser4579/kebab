//
//  EditEntryFullScreenView.swift
//  kebab
//

import SwiftUI
import UIKit

// MARK: - Multiline editor (focus + cursor at end on appear)

private struct EditEntryTextEditor: UIViewRepresentable {

    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.font = UIFont(name: "DMSans-Regular", size: 16) ?? .systemFont(ofSize: 16, weight: .regular)
        tv.textColor = UIColor(red: 202 / 255, green: 208 / 255, blue: 219 / 255, alpha: 1)
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.delegate = context.coordinator
        tv.text = text
        tv.tintColor = UIColor(red: 147 / 255, green: 94 / 255, blue: 213 / 255, alpha: 1)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        DispatchQueue.main.async {
            context.coordinator.primeFocusIfNeeded(uiView)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditEntryTextEditor
        private var didPrimeFocus = false

        init(_ parent: EditEntryTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
        }

        func primeFocusIfNeeded(_ textView: UITextView) {
            guard !didPrimeFocus, textView.bounds.width > 0 else { return }
            didPrimeFocus = true
            textView.becomeFirstResponder()
            let end = textView.endOfDocument
            textView.selectedTextRange = textView.textRange(from: end, to: end)
        }
    }
}

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

            EditEntryTextEditor(text: $text)
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
            onDismiss()
            return
        }

        isSaving = true
        let ok = await feedViewModel.updateEntryContent(id: entry.id, content: trimmedDraft)
        isSaving = false

        if ok {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            onPersistSuccess?()
            onSaveSuccess?(entry.withContent(trimmedDraft))
            onDismiss()
        } else {
            saveErrorMessage = feedViewModel.errorMessage ?? "Something went wrong."
        }
    }
}
