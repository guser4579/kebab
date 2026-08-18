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
    /// Called once the backend accepts the edit (resume-signal recording).
    var onPersistSuccess: (() -> Void)?
    /// Called IMMEDIATELY on submit with the edited entry, before dismissal —
    /// hosts patch their local copies (detail root, thread rows) in the same
    /// beat the editor closes.
    var onSaveSuccess: ((Entry) -> Void)?
    /// Called if persistence genuinely fails after the editor has dismissed —
    /// hosts roll back / restore truth and surface a notice.
    var onPersistFailure: (() -> Void)?

    @State private var text: String
    @State private var hasSubmitted = false

    init(
        entry: Entry,
        initialText: String,
        feedViewModel: FeedViewModel,
        onDismiss: @escaping () -> Void,
        onPersistSuccess: (() -> Void)? = nil,
        onSaveSuccess: ((Entry) -> Void)? = nil,
        onPersistFailure: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.initialText = initialText
        self.feedViewModel = feedViewModel
        self.onDismiss = onDismiss
        self.onPersistSuccess = onPersistSuccess
        self.onSaveSuccess = onSaveSuccess
        self.onPersistFailure = onPersistFailure
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
        !trimmedDraft.isEmpty && !hasSubmitted
    }

    private var needsBackendSave: Bool {
        trimmedDraft != trimmedOriginal
    }

    var body: some View {
        VStack(spacing: 0) {
            editHeader

            // Read-only attachment context: editing mutates text only, so
            // attachments are shown (same treatment as the composer) but not
            // removable here — they can never be destroyed by an edit.
            if entry.linkAttachment != nil || !entry.imageAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let link = entry.linkAttachment, let url = URL(string: link.url) {
                        HStack(spacing: 6) {
                            Icon("link-02", glyphSize: Style.Icon.glyphSmall)
                                .foregroundColor(Style.Color.secondary)
                            Text(url.rootDomainDisplay)
                                .font(Style.Typography.meta())
                                .foregroundColor(Style.Color.primaryText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(
                            Capsule()
                                .fill(Style.Color.composerBackground)
                                .overlay(Capsule().stroke(Style.Color.separator, lineWidth: 1))
                        )
                    }

                    if !entry.imageAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(entry.imageAttachments, id: \.url) { attachment in
                                    CachedAsyncImage(url: URL(string: attachment.url))
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Style.Layout.entryContentPadding)
                .padding(.top, 16)
            }

            FullScreenTextEditor(text: $text)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, Style.Layout.entryContentPadding)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .background(Style.Color.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Style.Color.background)
        // Container edges only — `.all` would also ignore the keyboard region
        // and break keyboard avoidance for the editor (see ComposerFullScreen).
        .ignoresSafeArea(.container, edges: [.top, .bottom])
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
                        handlePrimaryAction()
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

    /// Local-first save: hosts patch their copies and the editor dismisses in
    /// the same beat; persistence runs behind. `updateEntryContent` patches
    /// the shared feed model (root entries) with rollback on failure; hosts
    /// receive onPersistFailure to restore any thread-local state and surface
    /// a notice. Content-only persistence can't clobber concurrent attachment
    /// writers (link enrichment updates attachments in a separate payload).
    @MainActor
    private func handlePrimaryAction() {
        guard tickInteractive else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if needsBackendSave {
            hasSubmitted = true
            onSaveSuccess?(entry.withContent(trimmedDraft))
            let persistSuccess = onPersistSuccess
            let persistFailure = onPersistFailure
            let entryId = entry.id
            let draft = trimmedDraft
            let viewModel = feedViewModel
            Task {
                let ok = await viewModel.updateEntryContent(id: entryId, content: draft)
                if ok {
                    persistSuccess?()
                } else {
                    persistFailure?()
                }
            }
        }
        onDismiss()
    }
}
