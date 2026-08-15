import SwiftUI
import UIKit
import PhotosUI

// MARK: - NonScrollingTextView

// Suppresses spurious contentOffset mutations when isScrollEnabled = false.
//
// UIKit internally calls scrollRangeToVisible (which calls setContentOffset)
// after layout events and text changes, even when the text view is not in
// scrolling mode. With a non-scrollable text view whose frame exactly matches
// its content height, any non-zero contentOffset produces a visible viewport
// jump — the text briefly appears shifted before the next layout pass corrects
// it. Blocking those calls keeps the viewport pinned at (0,0) during normal
// editing. An explicit reset to .zero is always permitted so that transitions
// from scrolling → non-scrolling mode can clear any accumulated offset.
private final class NonScrollingTextView: UITextView {
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if isScrollEnabled || contentOffset == .zero {
            super.setContentOffset(contentOffset, animated: animated)
        }
    }
}

// MARK: - GrowingTextView (UITextView-backed)

private struct GrowingTextView: UIViewRepresentable {

    @Binding var text: String
    @Binding var isFocused: Bool
    /// External focus request (returning from full-screen) — consumed once honored.
    @Binding var requestFocus: Bool
    let maxHeight: CGFloat
    /// Horizontal text insets vary by composer layout: tighter next to the
    /// inline + button, roomier when text owns the full row.
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    var onFocus: (() -> Void)?
    /// Fires when the content height crosses the max-inline-height boundary
    /// (the composer's constrained state).
    var onConstrainedChange: ((Bool) -> Void)?

    private let textInsetTop: CGFloat    = 13
    private let textInsetBottom: CGFloat = 13
    private let minHeight: CGFloat       = 48

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = NonScrollingTextView()
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(
            top: textInsetTop, left: leadingInset,
            bottom: textInsetBottom, right: trailingInset
        )
        textView.textContainer.lineFragmentPadding  = 0
        textView.textContainer.widthTracksTextView  = true
        textView.textContainer.lineBreakMode        = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.font      = UIFont.systemFont(ofSize: 16, weight: .regular)
        textView.textColor = Style.Color.primaryTextUIColor
        textView.delegate  = context.coordinator
        textView.text      = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
        }
        if textView.textContainerInset.left != leadingInset
            || textView.textContainerInset.right != trailingInset {
            var inset = textView.textContainerInset
            inset.left = leadingInset
            inset.right = trailingInset
            textView.textContainerInset = inset
        }
        if requestFocus {
            DispatchQueue.main.async {
                if !textView.isFirstResponder {
                    textView.becomeFirstResponder()
                }
                self.requestFocus = false
            }
        }
    }

    // MARK: sizeThatFits — one-way sizing

    // SwiftUI calls this during every layout pass to determine the view's size.
    // Implementing it here removes the need for a separate @State contentHeight
    // and the async write/re-render loop that variable created. Size is computed
    // once per pass, SwiftUI sets the UITextView frame to exactly that value, and
    // there is no intermediate state where the frame is wrong relative to the text
    // content — which was the root cause of cursor/viewport jumping.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        // Resolve a concrete width. If the proposal is nil or infinite (e.g.
        // inside a ScrollView), fall back to the current bounds. If neither
        // is available yet, defer this pass and let SwiftUI try again after
        // the first layout establishes real bounds.
        let width: CGFloat
        if let w = proposal.width, w > 0, w < .infinity {
            width = w
        } else if uiView.bounds.width > 0 {
            width = uiView.bounds.width
        } else {
            return nil
        }

        let fittedHeight = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height

        let shouldScroll = fittedHeight > maxHeight
        if uiView.isScrollEnabled != shouldScroll {
            if !shouldScroll {
                // Clear any accumulated scroll position before disabling scroll
                // so content is anchored at the top in non-scrolling mode.
                uiView.contentOffset = .zero
            }
            uiView.isScrollEnabled = shouldScroll
            // Notify outside the layout pass — the owner mutates view state
            // (the expand affordance) in response.
            let constrained = shouldScroll
            DispatchQueue.main.async {
                onConstrainedChange?(constrained)
            }
        }

        return CGSize(width: width, height: min(maxHeight, max(minHeight, fittedHeight)))
    }

    // MARK: Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            parent.onFocus?()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}

// MARK: - ComposerView

struct ComposerView: View {

    @Binding var text: String
    let maxHeight: CGFloat
    var placeholder: String = "Make an entry"
    /// Enables the "+" attach menu (main feed composer only — root entries).
    var allowsAttachments: Bool = false
    /// Images staged for the next send. Owned by the host so a failed send
    /// can restore them alongside the text draft.
    @Binding var attachedImages: [PendingImage]
    /// External focus request (e.g. returning from the full-screen composer);
    /// consumed once honored.
    @Binding var requestFocus: Bool
    let onSent: (String) -> Void
    var onFocus: (() -> Void)?
    /// Present ⇒ the constrained state shows the expand affordance, which
    /// hands this draft to the full-screen composer.
    var onExpandTapped: (() -> Void)?

    init(
        text: Binding<String>,
        maxHeight: CGFloat,
        placeholder: String = "Make an entry",
        allowsAttachments: Bool = false,
        attachedImages: Binding<[PendingImage]> = .constant([]),
        requestFocus: Binding<Bool> = .constant(false),
        onSent: @escaping (String) -> Void,
        onFocus: (() -> Void)? = nil,
        onExpandTapped: (() -> Void)? = nil
    ) {
        self._text = text
        self.maxHeight = maxHeight
        self.placeholder = placeholder
        self.allowsAttachments = allowsAttachments
        self._attachedImages = attachedImages
        self._requestFocus = requestFocus
        self.onSent = onSent
        self.onFocus = onFocus
        self.onExpandTapped = onExpandTapped
    }

    @State private var isFocused: Bool = false
    /// True while the text content exceeds the max inline height (internal
    /// scrolling active) — the composer's constrained state.
    @State private var isConstrained: Bool = false
    @StateObject private var voice = VoiceTranscriber()
    /// Text present when dictation started; the streaming transcript is
    /// appended after it so dictation never destroys typed text.
    @State private var dictationBaseline: String = ""
    // Attachment picker presentation
    @State private var isPhotosPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var photoSelection: [PhotosPickerItem] = []

    private let maxImages = 4

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
    }

    private let composerOuterPadding:    CGFloat = Style.Spacing.x4
    private let buttonInset:             CGFloat = 6
    private let buttonSize:              CGFloat = 36

    /// Focused (or holding a draft) ⇒ text owns its own region above a stable
    /// action row — five levels of accommodation, one composer, one draft.
    private var isExpandedLayout: Bool {
        isFocused || !text.isEmpty
    }

    /// Leading text inset: tight next to the inline + button, roomy when the
    /// text owns the full row.
    private var textLeadingInset: CGFloat {
        if isExpandedLayout { return 16 }
        return allowsAttachments ? 8 : 16
    }

    private var textTrailingInset: CGFloat {
        isExpandedLayout ? 16 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachedImages.isEmpty {
                ComposerThumbnailStrip(images: $attachedImages)
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
            }

            // The text view keeps this exact structural slot in every state —
            // only the controls around it move — so UIKit never rebuilds it
            // and focus/cursor survive layout transitions.
            HStack(alignment: .bottom, spacing: 0) {
                if !isExpandedLayout && allowsAttachments {
                    attachMenu
                        .padding(.leading, 4)
                        .padding(.bottom, buttonInset)
                }
                textArea
                if !isExpandedLayout {
                    micButton
                        .padding(.bottom, buttonInset)
                    sendButtonColumn
                        .padding(.leading, 4)
                        .padding(.trailing, buttonInset)
                }
            }

            if isExpandedLayout {
                actionRow
            }
        }
        .animation(Style.Animation.composerState, value: isExpandedLayout)
        // Liquid Glass capsule: feed content scrolls visibly behind the
        // composer. The subtle tint keeps placeholder/text contrast on the
        // dark theme without going opaque.
        .glassEffect(
            .regular.tint(Style.Color.composerBackground.opacity(0.5)),
            in: RoundedRectangle(cornerRadius: Style.Layout.composerCapsuleRadius)
        )
        .padding(.horizontal, composerOuterPadding)
        .padding(.bottom, isFocused ? Style.Spacing.x3 : 0)
        .onDisappear {
            voice.stop()
        }
        .alert("Allow microphone access", isPresented: $voice.permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("To dictate entries, allow microphone and speech recognition access in Settings.")
        }
        .alert("Dictation unavailable", isPresented: $voice.startFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Speech recognition isn\u{2019}t available right now. Try again in a moment.")
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photoSelection,
            maxSelectionCount: max(1, maxImages - attachedImages.count),
            matching: .images
        )
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    guard attachedImages.count < maxImages else { break }
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        attachedImages.append(PendingImage(image: image))
                    }
                }
                photoSelection = []
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { image in
                if attachedImages.count < maxImages {
                    attachedImages.append(PendingImage(image: image))
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                guard attachedImages.count < maxImages else { break }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url),
                   let image = UIImage(data: data) {
                    attachedImages.append(PendingImage(image: image))
                }
            }
        }
    }

    // Text input area — ZStack holds the placeholder overlay and the live text view.
    // Neither element carries an explicit .frame(height:) here. The GrowingTextView
    // reports its ideal height via sizeThatFits; the ZStack sizes to that; the HStack
    // sizes to the tallest child. There is exactly one place in the layout tree that
    // drives the composer height, and it is the text view itself — not a @State mirror
    // of it applied back in three nested modifiers.
    private var textArea: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !isFocused {
                Text(placeholder)
                    .font(Style.Typography.composerPlaceholder())
                    .foregroundColor(Style.Color.secondary)
                    .padding(.leading, textLeadingInset)
                    .padding(.top, 13)
                    .padding(.bottom, 13)
            }
            GrowingTextView(
                text: $text,
                isFocused: $isFocused,
                requestFocus: $requestFocus,
                maxHeight: maxHeight,
                leadingInset: textLeadingInset,
                trailingInset: textTrailingInset,
                onFocus: onFocus,
                onConstrainedChange: { isConstrained = $0 }
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        // Restrained expand affordance: only once expansion is genuinely
        // useful (content exceeds the max inline height), floating clear of
        // text on a small scrim so the two never tangle.
        .overlay(alignment: .topTrailing) {
            if isConstrained, isExpandedLayout, onExpandTapped != nil {
                expandButton
                    .padding(.top, 6)
                    .padding(.trailing, 6)
            }
        }
    }

    private var expandButton: some View {
        Button {
            Haptics.lightTap()
            onExpandTapped?()
        } label: {
            Icon("doub-arrows", glyphSize: Style.Icon.glyphSmall)
                .foregroundColor(Style.Color.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Style.Color.composerBackground.opacity(0.85)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // Stable bottom action row for the expanded layout: + at the leading
    // edge, voice and send trailing. The row never moves while the text
    // region above it grows.
    private var actionRow: some View {
        HStack(spacing: 0) {
            if allowsAttachments {
                attachMenu
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
            micButton
            sendButton
                .padding(.leading, 4)
        }
        .padding(.trailing, buttonInset)
        .padding(.bottom, buttonInset)
    }

    // "+" attach menu — Camera / Photos / Files, capped at four images.
    private var attachMenu: some View {
        Menu {
            Button {
                isCameraPresented = true
            } label: {
                Label("Camera", systemImage: "camera")
            }
            Button {
                isPhotosPickerPresented = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                isFileImporterPresented = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(
                    attachedImages.count >= maxImages
                        ? Style.Color.secondary.opacity(0.35)
                        : Style.Color.secondary
                )
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Circle())
        }
        .disabled(attachedImages.count >= maxImages)
    }

    // Mic button — dictation toggle. While recording the glyph becomes an
    // animated waveform tinted with the accent color; the streaming transcript
    // lands in the text field after whatever was already typed.
    private var micButton: some View {
        Button {
            Haptics.lightTap()
            if voice.isRecording {
                voice.stop()
            } else {
                let baseline = text.trimmingCharacters(in: .whitespacesAndNewlines)
                dictationBaseline = baseline
                voice.onTranscript = { transcript in
                    text = baseline.isEmpty ? transcript : baseline + " " + transcript
                }
                Task { await voice.start() }
            }
        } label: {
            Image(systemName: voice.isRecording ? "waveform" : "mic")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(voice.isRecording ? Style.Color.composerSend : Style.Color.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: voice.isRecording)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // Send button column — width is fixed; height fills the HStack naturally.
    // HStack(alignment: .bottom) pins the column's bottom edge to the composer
    // bottom, so the button stays anchored regardless of how tall the text grows.
    private var sendButtonColumn: some View {
        sendButton
            .padding(.bottom, buttonInset)
            .frame(width: buttonSize, alignment: .bottom)
    }

    private var sendButton: some View {
        Button {
            sendIfNeeded()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        hasContent
                        ? Style.Color.composerSend
                        : Style.Color.secondary.opacity(0.2)
                    )
                    .frame(width: buttonSize, height: buttonSize)
                Icon("arrow-up")
                    .foregroundColor(
                        hasContent
                        ? Style.Color.composerSendForeground
                        : Style.Color.secondary
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasContent)
    }

    private func sendIfNeeded() {
        if voice.isRecording {
            voice.stop()
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Images alone are sendable; the host reads attachedImages itself
        // (and clears them) inside onSent.
        guard !trimmed.isEmpty || !attachedImages.isEmpty else { return }
        onSent(trimmed)
        text = ""
        // Height resets automatically: updateUIView clears the UITextView text,
        // then sizeThatFits returns single-line height in the same layout pass.
    }
}
