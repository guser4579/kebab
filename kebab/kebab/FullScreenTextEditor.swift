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
    /// Root-thought surfaces: live markup styling, list continuation, and the
    /// formatting bar. False behaves exactly as a plain text editor.
    var formatting: Bool = false
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
        tv.font = Style.Typography.faceUIFont(16)
        tv.textColor = Style.Color.primaryTextUIColor
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.delegate = context.coordinator
        tv.text = text
        tv.tintColor = Style.Color.composerSendUIColor
        // A serious writing surface: dragging the text tracks the keyboard
        // down interactively, and alwaysBounceVertical keeps that gesture
        // available even when the draft is shorter than the viewport. Cursor
        // and draft survive dismissal (UIKit keeps selectedRange).
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.onPasteImages = onPasteImages
        tv.onPasteLink = onPasteLink
        if formatting {
            context.coordinator.enableFormatting(on: tv)
        }
        return tv
    }

    func updateUIView(_ uiView: FocusingTextView, context: Context) {
        context.coordinator.parent = self
        uiView.onPasteImages = onPasteImages
        uiView.onPasteLink = onPasteLink
        if uiView.text != text {
            if formatting {
                context.coordinator.adoptExternalText(text, in: uiView)
            } else {
                uiView.text = text
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate, UIGestureRecognizerDelegate {
        var parent: FullScreenTextEditor

        private let barModel = FormattingBarModel()
        private weak var formattedTextView: UITextView?
        private var barHost: UIViewController?
        /// Set while an operation is being applied, so its own change
        /// callbacks don't re-enter the formatting pipeline.
        private var isApplying = false
        /// Characters edited since the last restyle. A second edit before the
        /// restyle (an undo group, say) falls back to the whole document.
        private var pendingEdit: NSRange?
        private var needsFullRestyle = false

        init(_ parent: FullScreenTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard parent.formatting else {
                parent.text = textView.text ?? ""
                return
            }
            guard !isApplying else { return }
            parent.text = textView.text ?? ""
            // IME and dictation own the text until they commit.
            guard textView.markedTextRange == nil else { return }
            if textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true {
                let current = editState(of: textView)
                let renumbered = MarkupEditing.renumbered(current)
                if renumbered != current {
                    apply(renumbered, to: textView)
                    return
                }
            }
            restylePendingEdits(in: textView)
            refreshBar(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard parent.formatting, !isApplying, textView.markedTextRange == nil else { return }
            // UIKit inherits typing attributes from the character before the
            // caret; styling only ever comes from markers.
            textView.typingAttributes = MarkupTextStyler.bodyAttributes
            refreshBar(for: textView)
        }

        // MARK: Formatting setup

        func enableFormatting(on textView: FocusingTextView) {
            formattedTextView = textView
            textView.textStorage.delegate = self
            MarkupTextStyler.styleAll(textView.textStorage)
            textView.typingAttributes = MarkupTextStyler.bodyAttributes

            barModel.perform = { [weak self] action in
                self?.perform(action)
            }
            let host = UIHostingController(rootView: FormattingBar(model: barModel))
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            barHost = host
            textView.inputAccessoryView = FormattingAccessoryView(hosting: host.view)
            refreshBar(for: textView)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.delegate = self
            textView.addGestureRecognizer(tap)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardFrameWillChange),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
        }

        /// The text view runs behind the glass bar and the keyboard (hosts
        /// ignore the keyboard safe area), so text shows through the capsule.
        /// Its content inset keeps the caret and last line above the bar.
        @objc private func keyboardFrameWillChange(_ notification: Notification) {
            guard let textView = formattedTextView, let window = textView.window,
                  let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            let keyboard = window.convert(frame, from: nil)
            let field = textView.convert(textView.bounds, to: window)
            let overlap = max(0, field.maxY - keyboard.minY)
            textView.contentInset.bottom = overlap
            textView.verticalScrollIndicatorInsets.bottom = overlap
            if overlap > 0, textView.isFirstResponder {
                textView.scrollRangeToVisible(textView.selectedRange)
            }
        }

        /// Text set from outside (the composer's voice dictation): restyle
        /// everything and keep the caret — one sitting at the very end stays
        /// at the end, so dictation keeps appending under it.
        func adoptExternalText(_ text: String, in textView: UITextView) {
            let previous = textView.selectedRange
            let wasAtEnd = previous.location + previous.length == (textView.text as NSString).length
            isApplying = true
            textView.text = text
            let length = (text as NSString).length
            textView.selectedRange = wasAtEnd
                ? NSRange(location: length, length: 0)
                : NSRange(location: min(previous.location, length), length: min(previous.length, max(0, length - previous.location)))
            isApplying = false
            pendingEdit = nil
            needsFullRestyle = false
            guard textView.markedTextRange == nil else {
                needsFullRestyle = true
                return
            }
            MarkupTextStyler.styleAll(textView.textStorage)
            textView.typingAttributes = MarkupTextStyler.bodyAttributes
            refreshBar(for: textView)
        }

        // MARK: Live styling

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorage.EditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            if pendingEdit != nil { needsFullRestyle = true }
            pendingEdit = editedRange
        }

        private func restylePendingEdits(in textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            if needsFullRestyle {
                MarkupTextStyler.styleAll(textView.textStorage)
            } else if let edited = pendingEdit {
                MarkupTextStyler.style(textView.textStorage, around: edited)
            }
            pendingEdit = nil
            needsFullRestyle = false
            textView.typingAttributes = MarkupTextStyler.bodyAttributes
        }

        // MARK: Applying operations

        private func editState(of textView: UITextView) -> EditState {
            EditState(text: textView.text ?? "", selection: textView.selectedRange)
        }

        /// One undoable edit through UITextInput, whatever the operation was.
        private func apply(_ new: EditState, to textView: UITextView) {
            if let edit = MarkupEditing.replacement(from: textView.text ?? "", to: new.text),
               let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
               let end = textView.position(from: start, offset: edit.range.length),
               let range = textView.textRange(from: start, to: end) {
                isApplying = true
                textView.replace(range, withText: edit.text)
                isApplying = false
            }
            isApplying = true
            textView.selectedRange = new.selection
            isApplying = false
            parent.text = textView.text ?? ""
            restylePendingEdits(in: textView)
            refreshBar(for: textView)
        }

        private func perform(_ action: FormattingAction) {
            guard let textView = formattedTextView, textView.markedTextRange == nil else { return }
            let state = editState(of: textView)
            let new: EditState
            switch action {
            case .list(let list): new = MarkupEditing.toggleList(list, state)
            case .inline(let inline): new = MarkupEditing.toggleInline(inline, state)
            case .indent: new = MarkupEditing.indent(state)
            case .outdent: new = MarkupEditing.outdent(state)
            }
            apply(new, to: textView)
        }

        private func refreshBar(for textView: UITextView) {
            let active = MarkupEditing.activeFormats(editState(of: textView))
            if barModel.active != active {
                barModel.active = active
            }
        }

        // MARK: Checkbox taps

        /// The checkbox a tap landed on: the nearest character must be on the
        /// brackets, and the tap must really be over them.
        private func checkbox(at point: CGPoint, in textView: UITextView) -> Int? {
            guard let position = textView.closestPosition(to: point) else { return nil }
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            guard let hit = MarkupEditing.checkboxLine(at: offset, in: textView.text ?? ""),
                  let start = textView.position(from: textView.beginningOfDocument, offset: hit.range.location),
                  let end = textView.position(from: start, offset: hit.range.length),
                  let range = textView.textRange(from: start, to: end),
                  textView.firstRect(for: range).insetBy(dx: -6, dy: -6).contains(point)
            else { return nil }
            return hit.lineIndex
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let textView = formattedTextView else { return false }
            return checkbox(at: gestureRecognizer.location(in: textView), in: textView) != nil
        }

        // The text view's own tap (which would move the caret into the marker)
        // waits for this one. It decides on touch-up, so normal taps aren't
        // delayed.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UITapGestureRecognizer
        }

        @objc private func handleTap(_ tap: UITapGestureRecognizer) {
            guard let textView = formattedTextView,
                  let lineIndex = checkbox(at: tap.location(in: textView), in: textView)
            else { return }
            apply(MarkupEditing.toggleCheckbox(lineIndex: lineIndex, editState(of: textView)), to: textView)
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
            if parent.formatting {
                return shouldChangeFormatted(textView, in: range, replacement: replacement)
            }
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

        /// Return continues or ends a list; backspace right after a marker
        /// removes it. Everything else is ordinary typing.
        private func shouldChangeFormatted(
            _ textView: UITextView,
            in range: NSRange,
            replacement: String
        ) -> Bool {
            guard !isApplying, textView.markedTextRange == nil else { return true }
            if replacement == "\n" {
                let state = EditState(text: textView.text ?? "", selection: range)
                guard let new = MarkupEditing.insertReturn(state) else { return true }
                apply(new, to: textView)
                return false
            }
            let selection = textView.selectedRange
            if replacement.isEmpty, range.length == 1, selection.length == 0,
               range.location + range.length == selection.location,
               let new = MarkupEditing.backspace(editState(of: textView)) {
                apply(new, to: textView)
                return false
            }
            return true
        }
    }
}
