//
//  FullScreenTextEditor.swift
//  kebab
//
//  Shared full-screen text editor used by both the entry editor
//  (EditEntryFullScreenView) and the full-screen composer
//  (ComposerFullScreenView) — one editor implementation so the two surfaces
//  can't drift apart over time.
//

import SwiftUI
import UIKit

// MARK: - FocusingTextView
//
// UITextView subclass that requests first responder exactly once, tied to the
// UIKit window-attachment lifecycle rather than to SwiftUI update passes.
//
// didMoveToWindow() is called by UIKit after the view is inserted into a live
// window (window != nil) or removed from one (window == nil). Hooking here
// guarantees that the view already has a committed layout and real bounds before
// becomeFirstResponder() is called, which eliminates the bounds.width == 0
// timing race that the old DispatchQueue.main.async-in-updateUIView approach
// was vulnerable to.
//
// The second window != nil check inside the async block closes the teardown
// window: if the overlay begins its exit animation before the deferred block
// runs, self.window will be nil and the block is a no-op. This prevents the
// "keyboard flash on X-close" that occurred when the view was being dismissed
// before it had ever acquired focus.

final class FocusingTextView: UITextView {
    private var didRequestFocus = false
    /// When set, images on the pasteboard route into the composer's
    /// attachment pipeline instead of pasting into the text.
    var onPasteImages: (([UIImage]) -> Void)?
    /// When set, a pasted bare URL becomes a staged link attachment.
    var onPasteLink: ((URL) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !didRequestFocus else { return }
        didRequestFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.becomeFirstResponder()
            let end = self.endOfDocument
            self.selectedTextRange = self.textRange(from: end, to: end)
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

// MARK: - FullScreenTextEditor

struct FullScreenTextEditor: UIViewRepresentable {

    @Binding var text: String
    /// Routes pasted images into the attachment pipeline (composer only).
    var onPasteImages: (([UIImage]) -> Void)? = nil
    /// Routes a pasted bare URL into the staged-link attachment (composer only).
    var onPasteLink: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> FocusingTextView {
        let tv = FocusingTextView()
        tv.backgroundColor = .clear
        tv.font = UIFont(name: "DMSans-Regular", size: 16) ?? .systemFont(ofSize: 16, weight: .regular)
        tv.textColor = Style.Color.primaryTextUIColor
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.delegate = context.coordinator
        tv.text = text
        tv.tintColor = Style.Color.composerSendUIColor
        tv.onPasteImages = onPasteImages
        tv.onPasteLink = onPasteLink
        return tv
    }

    func updateUIView(_ uiView: FocusingTextView, context: Context) {
        context.coordinator.parent = self
        uiView.onPasteImages = onPasteImages
        uiView.onPasteLink = onPasteLink
        if uiView.text != text {
            uiView.text = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: FullScreenTextEditor

        init(_ parent: FullScreenTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
        }

        // Checklist continuation: return on a checklist line inserts the next
        // "- [ ] " marker; return on an *empty* checklist item removes the
        // marker instead (the natural way to end a list). Plain text lines
        // are untouched.
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n" else { return true }
            let ns = textView.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: lineRange)
                .trimmingCharacters(in: .newlines)

            guard let marker = Checklist.marker(of: line) else { return true }

            let itemText = String(line.dropFirst(marker.count))
            if itemText.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item: end the list by clearing the marker line.
                let contentLength = (line as NSString).length
                let markerRange = NSRange(location: lineRange.location, length: contentLength)
                textView.textStorage.replaceCharacters(in: markerRange, with: "")
                textView.selectedRange = NSRange(location: lineRange.location, length: 0)
            } else {
                let insertion = "\n" + Checklist.uncheckedMarker
                textView.textStorage.replaceCharacters(in: range, with: insertion)
                textView.selectedRange = NSRange(
                    location: range.location + (insertion as NSString).length,
                    length: 0
                )
            }
            parent.text = textView.text ?? ""
            return false
        }
    }
}
