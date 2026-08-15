//
//  ComposerFullScreenView.swift
//  kebab
//

import SwiftUI
import UIKit

/// The composer's maximum-accommodation state: the same draft (text and
/// attachments are bindings into the owner's single draft source), full
/// screen. Entering never saves or forks the draft; X returns it to the
/// inline composer unchanged; send follows the exact same submission path
/// as the inline send button.
struct ComposerFullScreenView: View {

    @Binding var text: String
    @Binding var attachedImages: [PendingImage]
    /// Same staged link as the inline composer — one draft, every state.
    @Binding var attachedLink: URL?
    /// Sends the current draft — the owner reads and clears the bindings,
    /// identical to the inline path.
    let onSend: () -> Void
    /// Collapse back to the inline composer, draft intact.
    let onDismiss: () -> Void

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachedImages.isEmpty
            || attachedLink != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if attachedLink != nil || !attachedImages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let url = attachedLink {
                        ComposerLinkChip(url: url) {
                            attachedLink = nil
                        }
                    }
                    if !attachedImages.isEmpty {
                        ComposerThumbnailStrip(images: $attachedImages)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Style.Layout.entryContentPadding)
                .padding(.top, 16)
            }

            FullScreenTextEditor(
                text: $text,
                onPasteImages: { pasted in
                    for image in pasted where attachedImages.count < 4 {
                        attachedImages.append(PendingImage(image: image))
                    }
                },
                onPasteLink: { url in
                    attachedLink = url
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, Style.Layout.entryContentPadding)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .background(Style.Color.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Style.Color.background)
        .ignoresSafeArea(edges: [.top, .bottom])
    }

    private var header: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 60)

            ZStack {
                Text("New entry")
                    .font(.custom("DMSans-Medium", size: 16))
                    .foregroundColor(Style.Color.primaryText)

                HStack {
                    Button {
                        // Collapse only — the draft flows back to the inline
                        // composer through the shared bindings.
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        onDismiss()
                    } label: {
                        // Inward chevrons: this surface collapses back into
                        // the inline composer rather than closing outright —
                        // the inverse of the inline expand affordance. Every
                        // other full-screen sheet keeps its X.
                        Icon("chevrons-collapse")
                            .foregroundColor(Style.Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        guard hasContent else { return }
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        onSend()
                    } label: {
                        Icon("arrow-up")
                            .foregroundColor(
                                hasContent
                                    ? Style.Color.composerSend
                                    : Style.Color.secondary.opacity(0.35)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasContent)
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
}
