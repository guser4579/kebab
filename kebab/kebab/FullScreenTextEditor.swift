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

// MARK: - EditorContainerView
//
// The text view fills the container and the glass bar floats over it, pinned
// to the keyboard, so text passes behind the glass. The bar has to live here
// rather than in an inputAccessoryView: that sits in the keyboard's own window,
// where the glass has nothing of ours to sample and renders opaque.

final class EditorContainerView: UIView {
    let textView = FocusingTextView()
    private var bar: UIView?
    private var isBarShown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.frame = bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installBar(_ bar: UIView) {
        self.bar = bar
        bar.alpha = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        // Hosts pad the editor by entryContentPadding, the same inset the
        // composer capsule keeps from the screen edge.
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: FormattingBar.capsuleHeight),
            bar.bottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor,
                constant: -FormattingBar.keyboardGap
            )
        ])
    }

    /// Only while editing, so nothing floats over the page with the keyboard down.
    func setBarShown(_ shown: Bool) {
        guard let bar, shown != isBarShown else { return }
        isBarShown = shown
        setNeedsLayout()
        UIView.animate(withDuration: 0.2) {
            bar.alpha = shown ? 1 : 0
        }
    }

    /// Hosts let the editor run under the keyboard, so it insets its own text
    /// from whatever covers it. Runs on every step of an interactive drag.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let bar else { return }
        let covered = isBarShown ? bar.frame.minY : keyboardLayoutGuide.layoutFrame.minY
        let inset = max(0, bounds.maxY - covered)
        let previous = textView.contentInset.bottom
        guard inset != previous else { return }
        textView.contentInset.bottom = inset
        textView.verticalScrollIndicatorInsets.bottom = inset
        if inset > previous, textView.isFirstResponder, !textView.isTracking {
            textView.scrollRangeToVisible(textView.selectedRange)
        }
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

    func makeUIView(context: Context) -> EditorContainerView {
        let container = EditorContainerView()
        let tv = container.textView
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
            context.coordinator.enableFormatting(in: container)
        }
        return container
    }

    func updateUIView(_ uiView: EditorContainerView, context: Context) {
        context.coordinator.parent = self
        let tv = uiView.textView
        tv.onPasteImages = onPasteImages
        tv.onPasteLink = onPasteLink
        if tv.text != text {
            if formatting {
                context.coordinator.adoptExternalText(text, in: tv)
            } else {
                tv.text = text
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate, UIGestureRecognizerDelegate {
        var parent: FullScreenTextEditor

        private let barModel = FormattingBarModel()
        private weak var formattedTextView: UITextView?
        private weak var container: EditorContainerView?
        private var barHost: UIViewController?
        /// Set while an operation is being applied, so its own change
        /// callbacks don't re-enter the formatting pipeline.
        private var isApplying = false
        /// Characters edited since the last restyle. A second edit before the
        /// restyle (an undo group, say) falls back to the whole document.
        private var pendingEdit: NSRange?
        private var needsFullRestyle = false
        /// Where an undo or redo of an operation should leave the caret, set
        /// while the undo manager unwinds and used once it has finished.
        private var caretAfterUndo: Int?

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

        func textViewDidBeginEditing(_ textView: UITextView) {
            container?.setBarShown(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            container?.setBarShown(false)
        }

        // MARK: Formatting setup

        func enableFormatting(in container: EditorContainerView) {
            let textView = container.textView
            self.container = container
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
            container.installBar(host.view)
            refreshBar(for: textView)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.delegate = self
            textView.addGestureRecognizer(tap)

            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(undoManagerDidFinish),
                    name: name,
                    object: nil
                )
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
            let caretBefore = textView.selectedRange.location
            if let edit = MarkupEditing.replacement(from: textView.text ?? "", to: new.text),
               let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
               let end = textView.position(from: start, offset: edit.range.length),
               let range = textView.textRange(from: start, to: end) {
                textView.undoManager?.beginUndoGrouping()
                registerCaretRestore(caretBefore, on: textView)
                isApplying = true
                textView.replace(range, withText: edit.text)
                isApplying = false
                textView.undoManager?.endUndoGrouping()
            }
            isApplying = true
            textView.selectedRange = new.selection
            isApplying = false
            parent.text = textView.text ?? ""
            restylePendingEdits(in: textView)
            refreshBar(for: textView)
        }

        /// Left alone, undoing an operation selects the characters it put
        /// back, and the next keystroke would replace them. This rides in the
        /// operation's undo group, in both directions.
        private func registerCaretRestore(_ caret: Int, on textView: UITextView) {
            textView.undoManager?.registerUndo(withTarget: textView) { [weak self] textView in
                self?.caretAfterUndo = caret
                self?.registerCaretRestore(caret, on: textView)
            }
        }

        @objc private func undoManagerDidFinish(_ notification: Notification) {
            guard let textView = formattedTextView,
                  notification.object as? UndoManager === textView.undoManager,
                  let caret = caretAfterUndo
            else { return }
            caretAfterUndo = nil
            // UIKit selects the restored characters after this notification.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.isApplying = true
                textView.selectedRange = NSRange(location: min(caret, (textView.text as NSString).length), length: 0)
                self.isApplying = false
                textView.typingAttributes = MarkupTextStyler.bodyAttributes
                self.refreshBar(for: textView)
            }
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
