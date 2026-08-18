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
    /// When set, images on the pasteboard route into the composer's
    /// attachment pipeline instead of pasting into the text.
    var onPasteImages: (([UIImage]) -> Void)?
    /// When set, a pasted bare URL becomes a staged link attachment — the
    /// same treatment the Paste affordance produces.
    var onPasteLink: ((URL) -> Void)?

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if isScrollEnabled || contentOffset == .zero {
            super.setContentOffset(contentOffset, animated: animated)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteImages != nil, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let onPasteImages, UIPasteboard.general.hasImages,
           let images = UIPasteboard.general.images, !images.isEmpty {
            onPasteImages(images)
            return
        }
        if let onPasteLink, let url = PastedLink.current() {
            onPasteLink(url)
            return
        }
        super.paste(sender)
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
    /// Routes pasted images into the attachment pipeline (root composer only).
    var onPasteImages: (([UIImage]) -> Void)?
    /// Routes a pasted bare URL into the staged-link attachment.
    var onPasteLink: ((URL) -> Void)?

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
        textView.onPasteImages = onPasteImages
        textView.onPasteLink = onPasteLink
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        (textView as? NonScrollingTextView)?.onPasteImages = onPasteImages
        (textView as? NonScrollingTextView)?.onPasteLink = onPasteLink
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
    /// Link staged for the next send as a compact chip (pasted URL). Owned by
    /// the host — part of the same single draft as text and images.
    @Binding var attachedLink: URL?
    /// External focus request (e.g. returning from the full-screen composer);
    /// consumed once honored.
    @Binding var requestFocus: Bool
    let onSent: (String) -> Void
    var onFocus: (() -> Void)?
    /// Present ⇒ the constrained state shows the expand affordance, which
    /// hands this draft to the full-screen composer.
    var onExpandTapped: (() -> Void)?
    /// Present ⇒ the + menu offers List, a purpose-built checklist accelerator.
    var onStartList: (() -> Void)?

    init(
        text: Binding<String>,
        maxHeight: CGFloat,
        placeholder: String = "Make an entry",
        allowsAttachments: Bool = false,
        attachedImages: Binding<[PendingImage]> = .constant([]),
        attachedLink: Binding<URL?> = .constant(nil),
        requestFocus: Binding<Bool> = .constant(false),
        onSent: @escaping (String) -> Void,
        onFocus: (() -> Void)? = nil,
        onExpandTapped: (() -> Void)? = nil,
        onStartList: (() -> Void)? = nil
    ) {
        self._text = text
        self.maxHeight = maxHeight
        self.placeholder = placeholder
        self.allowsAttachments = allowsAttachments
        self._attachedImages = attachedImages
        self._attachedLink = attachedLink
        self._requestFocus = requestFocus
        self.onSent = onSent
        self.onFocus = onFocus
        self.onExpandTapped = onExpandTapped
        self.onStartList = onStartList
    }

    @State private var isFocused: Bool = false
    /// True while the text content exceeds the max inline height (internal
    /// scrolling active) — the composer's constrained state.
    @State private var isConstrained: Bool = false
    /// True for the render pass triggered by a send. Clearing the draft can
    /// collapse the expanded layout (drafted-unfocused send), and the
    /// composerState animation would walk the send button downward through
    /// that collapse — send state changes must land instantly instead.
    @State private var suppressLayoutAnimation = false
    /// Drives paste-control recreation on appearance flips — the system
    /// control bakes its colors in at creation. The app's own appearance
    /// setting is the authority; the environment scheme only decides the
    /// "system" case.
    @AppStorage("kebab.appearance") private var appearance = "dark"
    @Environment(\.colorScheme) private var colorScheme
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
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachedImages.isEmpty
            || attachedLink != nil
    }

    /// Paste is a permanent capability of attachment-capable composers — no
    /// clipboard-state gating. The system control dims itself when nothing
    /// acceptable is on the pasteboard; kebab never inspects availability.
    private var showsPasteAffordance: Bool {
        allowsAttachments
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
            if attachedLink != nil || !attachedImages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let url = attachedLink {
                        ComposerLinkChip(url: url) {
                            // Removing the link never touches written context.
                            attachedLink = nil
                        }
                    }
                    if !attachedImages.isEmpty {
                        ComposerThumbnailStrip(images: $attachedImages)
                    }
                }
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
                    if showsPasteAffordance {
                        pasteChip
                            .padding(.bottom, buttonInset + 4)
                    }
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
        .animation(
            suppressLayoutAnimation ? nil : Style.Animation.composerState,
            value: isExpandedLayout
        )
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
                       let staged = await PendingImage.staged(fromData: data) {
                        attachedImages.append(staged)
                    }
                }
                photoSelection = []
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { image in
                Task {
                    guard attachedImages.count < maxImages else { return }
                    if let staged = await PendingImage.staged(fromImage: image) {
                        attachedImages.append(staged)
                    }
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
            // Read while the security scope is open; stage (decode/encode)
            // off-main afterwards.
            let datas: [Data] = urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            }
            Task {
                for data in datas {
                    guard attachedImages.count < maxImages else { break }
                    if let staged = await PendingImage.staged(fromData: data) {
                        attachedImages.append(staged)
                    }
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
                // One line always: a long collection name ellipsizes within
                // the text area's width, never wrapping or running under the
                // trailing controls.
                Text(placeholder)
                    .font(Style.Typography.composerPlaceholder())
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, textLeadingInset)
                    .padding(.trailing, Style.Spacing.x2)
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
                onConstrainedChange: { isConstrained = $0 },
                onPasteImages: allowsAttachments ? { appendPastedImages($0) } : nil,
                // Standard iOS paste of a bare URL converges on the same
                // staged-link attachment as the Paste affordance.
                onPasteLink: allowsAttachments ? { stageLink($0) } : nil
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
            onExpandTapped?()
        } label: {
            // Outward chevrons: expand this draft into the full-screen
            // composer (whose header shows the inward inverse to collapse).
            Icon("chevrons-expand", glyphSize: Style.Icon.glyphSmall)
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
            if showsPasteAffordance {
                pasteChip
                    .padding(.leading, allowsAttachments ? 0 : Style.Spacing.x3)
            }
            Spacer(minLength: 0)
            micButton
            sendButton
                .padding(.leading, 4)
        }
        .padding(.trailing, buttonInset)
        .padding(.bottom, buttonInset)
    }

    // MARK: - Clipboard paste affordance

    /// One-tap Paste for supported clipboard content. The tappable element is
    /// Apple's own paste control (no repeated permission prompt); kebab wraps
    /// it in the chip's capsule stroke. The system supplies the payload —
    /// this path never reads UIPasteboard.
    /// The appearance the paste control must render in: kebab's setting
    /// wins outright; "system" follows the device.
    private var pasteControlStyle: UIUserInterfaceStyle {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return colorScheme == .light ? .light : .dark
        }
    }

    private var pasteChip: some View {
        SystemPasteControl(uiStyle: pasteControlStyle) { providers in
            handlePastePayload(providers)
        }
        // Rebuild the control when the appearance flips: it resolves its
        // configuration colors once at creation.
        .id(pasteControlStyle)
        .fixedSize()
        .frame(height: 28)
        .background(Capsule().stroke(Style.Color.separator, lineWidth: 1))
    }

    /// Routes the system-provided payload into the pipelines that content
    /// already uses everywhere else: images join the attachment strip, a bare
    /// URL becomes the staged link chip, and plain text lands in the draft as
    /// ordinary editable text. Consumption happens only after content
    /// actually arrives.
    private func handlePastePayload(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }

        let imageProviders = providers.filter { $0.canLoadObject(ofClass: UIImage.self) }
        if !imageProviders.isEmpty {
            Task { @MainActor in
                var images: [UIImage] = []
                for provider in imageProviders {
                    if let image = await Self.loadImage(from: provider) {
                        images.append(image)
                    }
                }
                guard !images.isEmpty else { return }
                appendPastedImages(images)
            }
            return
        }

        Task { @MainActor in
            // The string form is the authority when present (same rule as the
            // pasteboard path): a bare link stages the chip, prose — even
            // prose containing a URL — pastes as text and is parsed at send.
            if let string = await Self.loadString(from: providers) {
                if let url = PastedLink.from(string: string) {
                    stageLink(url)
                } else {
                    insertPastedText(string)
                }
            } else if let url = await Self.loadURL(from: providers) {
                // URL-only object with no string form.
                stageLink(url)
            }
        }
    }

    private func insertPastedText(_ string: String) {
        guard !string.isEmpty else { return }
        text = text.isEmpty ? string : text + string
    }

    private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    private static func loadString(from providers: [NSItemProvider]) async -> String? {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) })
        else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map(String.init))
            }
        }
    }

    private static func loadURL(from providers: [NSItemProvider]) async -> URL? {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSURL.self) })
        else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
    }

    /// The single place a URL becomes a staged link, whichever route brought
    /// it here (Paste affordance or standard iOS paste).
    private func stageLink(_ url: URL) {
        attachedLink = url
    }

    /// Pasted images enter the exact same pipeline as picked ones.
    private func appendPastedImages(_ images: [UIImage]) {
        Task {
            for image in images {
                guard attachedImages.count < maxImages else { break }
                if let staged = await PendingImage.staged(fromImage: image) {
                    attachedImages.append(staged)
                }
            }
        }
    }

    // "+" attach menu — Camera / Photos / Files (capped at four images),
    // plus the List accelerator on the root composer.
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
            if let onStartList {
                Button {
                    onStartList()
                } label: {
                    Label("List", systemImage: "checklist")
                }
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
        // List stays reachable even at the image cap; only fully disable the
        // menu when it has nothing left to offer.
        .disabled(attachedImages.count >= maxImages && onStartList == nil)
    }

    // Mic button — dictation toggle. While recording the glyph becomes an
    // animated waveform tinted with the accent color; the streaming transcript
    // lands in the text field after whatever was already typed.
    private var micButton: some View {
        Button {
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
                .foregroundColor(voice.isRecording ? Style.Color.destructive : Style.Color.secondary)
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
        // Images or a staged link alone are sendable — text context is
        // optional. The host reads attachedImages/attachedLink itself (and
        // clears them) inside onSent.
        guard !trimmed.isEmpty || !attachedImages.isEmpty || attachedLink != nil else { return }
        suppressLayoutAnimation = true
        onSent(trimmed)
        text = ""
        // Re-arm the layout animation once the send's render pass has landed.
        DispatchQueue.main.async {
            suppressLayoutAnimation = false
        }
        // Height resets automatically: updateUIView clears the UITextView text,
        // then sizeThatFits returns single-line height in the same layout pass.
    }
}
