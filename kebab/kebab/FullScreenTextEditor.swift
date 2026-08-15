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
}

// MARK: - FullScreenTextEditor

struct FullScreenTextEditor: UIViewRepresentable {

    @Binding var text: String

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
        return tv
    }

    func updateUIView(_ uiView: FocusingTextView, context: Context) {
        context.coordinator.parent = self
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
    }
}
