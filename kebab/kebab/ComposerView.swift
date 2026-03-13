import SwiftUI
import UIKit

// MARK: - GrowingTextView (UITextView-backed)

private struct GrowingTextView: UIViewRepresentable {

    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool
    let maxHeight: CGFloat
    var onFocus: (() -> Void)?

    private let textInsetTop: CGFloat = 13
    private let textInsetBottom: CGFloat = 13
    private let textInsetLeft: CGFloat = 16
    private let textInsetRight: CGFloat = 0
    private let minHeight: CGFloat = 48

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: textInsetTop, left: textInsetLeft, bottom: textInsetBottom, right: textInsetRight)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        textView.textColor = UIColor(red: 202/255, green: 208/255, blue: 219/255, alpha: 1)
        textView.delegate = context.coordinator
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
        }
        DispatchQueue.main.async {
            context.coordinator.reportHeight(from: textView)
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            reportHeight(from: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            parent.onFocus?()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        func reportHeight(from textView: UITextView) {
            guard textView.bounds.width > 0 else { return }
            let fittedHeight = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
            let clamped = min(parent.maxHeight, max(parent.minHeight, fittedHeight))
            if abs(clamped - parent.measuredHeight) > 0.5 {
                parent.measuredHeight = clamped
            }
            textView.isScrollEnabled = fittedHeight > parent.maxHeight
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

    @State private var contentHeight: CGFloat = Style.Layout.composerSingleLineHeight
    @State private var isFocused: Bool = false

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let composerOuterPadding: CGFloat = Style.Spacing.x4
    private let textLeadingPadding: CGFloat = 16
    private let textVerticalPadding: CGFloat = 12
    private let gapBetweenTextAndButton: CGFloat = 12
    private let buttonInset: CGFloat = 6
    private let buttonSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .bottom, spacing: gapBetweenTextAndButton) {
            textArea
            sendButtonColumn
                .padding(.trailing, buttonInset)
        }
        .frame(height: contentHeight)
        .background(
            Style.Color.composerBackground,
            in: RoundedRectangle(cornerRadius: Style.Layout.composerCapsuleRadius)
        )
        .padding(.horizontal, composerOuterPadding)
        .padding(.bottom, isFocused ? Style.Spacing.x3 : 0)
    }

    private var textArea: some View {
        ZStack(alignment: .leading) {
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
                measuredHeight: $contentHeight,
                isFocused: $isFocused,
                maxHeight: maxHeight,
                onFocus: onFocus
            )
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: contentHeight)
    }

    private var sendButtonColumn: some View {
        sendButton
            .padding(.bottom, buttonInset)
            .frame(width: buttonSize, height: contentHeight, alignment: .bottom)
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
        contentHeight = Style.Layout.composerSingleLineHeight
    }
}
