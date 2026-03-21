import SwiftUI
import UIKit

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
    let maxHeight: CGFloat
    var onFocus: (() -> Void)?

    private let textInsetTop: CGFloat    = 13
    private let textInsetBottom: CGFloat = 13
    private let textInsetLeft: CGFloat   = 16
    private let textInsetRight: CGFloat  = 0
    private let minHeight: CGFloat       = 48

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = NonScrollingTextView()
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(
            top: textInsetTop, left: textInsetLeft,
            bottom: textInsetBottom, right: textInsetRight
        )
        textView.textContainer.lineFragmentPadding  = 0
        textView.textContainer.widthTracksTextView  = true
        textView.textContainer.lineBreakMode        = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.font      = UIFont.systemFont(ofSize: 16, weight: .regular)
        textView.textColor = UIColor(red: 202/255, green: 208/255, blue: 219/255, alpha: 1)
        textView.delegate  = context.coordinator
        textView.text      = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
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
    let onSent: (String) -> Void
    var onFocus: (() -> Void)?

    @State private var isFocused: Bool = false

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let composerOuterPadding:    CGFloat = Style.Spacing.x4
    private let textLeadingPadding:      CGFloat = 16
    private let gapBetweenTextAndButton: CGFloat = 12
    private let buttonInset:             CGFloat = 6
    private let buttonSize:              CGFloat = 36

    var body: some View {
        HStack(alignment: .bottom, spacing: gapBetweenTextAndButton) {
            textArea
            sendButtonColumn
                .padding(.trailing, buttonInset)
        }
        .background(
            Style.Color.composerBackground,
            in: RoundedRectangle(cornerRadius: Style.Layout.composerCapsuleRadius)
        )
        .padding(.horizontal, composerOuterPadding)
        .padding(.bottom, isFocused ? Style.Spacing.x3 : 0)
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
                    .padding(.leading, textLeadingPadding)
                    .padding(.top, 13)
                    .padding(.bottom, 13)
            }
            GrowingTextView(
                text: $text,
                isFocused: $isFocused,
                maxHeight: maxHeight,
                onFocus: onFocus
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
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
                        ? Style.Color.primaryText
                        : Style.Color.secondary
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasContent)
    }

    private func sendIfNeeded() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSent(trimmed)
        text = ""
        // Height resets automatically: updateUIView clears the UITextView text,
        // then sizeThatFits returns single-line height in the same layout pass.
    }
}
