//
//  EditorPrewarm.swift
//  kebab
//
//  Pays the full-screen editor's one-time costs before anyone opens it. Each is
//  once per process and blocks the main thread, so without this they land on
//  the first frames of the first open, and the inline composer sits there while
//  they run. Both composer and entry editing share what's warmed here.
//
//  Runs one step at a time when the run loop is idle, after the feed has shown.
//  Nothing here takes focus, touches the keyboard, or reaches the screen.
//
//  The one cost it can't pay is the process's first keyboard. Only a first
//  responder creates it, and a brief one visibly flashes the keyboard. So the
//  editor holds its focus request until the slide has finished, that one time.
//

import SwiftUI
import UIKit

enum EditorPrewarm {

    private static var hasRun = false
    private static var keyboardObserver: NSObjectProtocol?

    /// False until this process has shown a keyboard.
    private(set) static var isKeyboardWarm = false

    /// How long the editor should wait before asking for focus: long enough for
    /// the 0.25s overlay slide to finish, if a keyboard is about to be built.
    static var focusDelay: TimeInterval {
        isKeyboardWarm ? 0 : 0.28
    }

    /// Call as soon as the main screen exists.
    @MainActor
    static func trackKeyboard() {
        guard keyboardObserver == nil else { return }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { _ in
            isKeyboardWarm = true
        }
    }

    /// Call once the feed has rendered.
    @MainActor
    static func schedule() {
        guard !hasRun else { return }
        hasRun = true
        // Clear of launch, then only when nothing else is happening.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            runWhenIdle(steps: [warmKeyboardGuide, warmEditorViews])
        }
    }

    /// `.whenIdle` waits for a run-loop pass with nothing to do in the default
    /// mode, so a step never lands mid-scroll or mid-animation.
    @MainActor
    private static func runWhenIdle(steps: [@MainActor () -> Void]) {
        guard let step = steps.first else { return }
        let name = Notification.Name("kebab.editorPrewarm")
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            if let observer { NotificationCenter.default.removeObserver(observer) }
            MainActor.assumeIsolated {
                step()
                runWhenIdle(steps: Array(steps.dropFirst()))
            }
        }
        NotificationQueue.default.enqueue(Notification(name: name), postingStyle: .whenIdle)
    }

    @MainActor
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow
    }

    /// A window's first `keyboardLayoutGuide` loads TextInputUI and builds its
    /// tracking machinery. It's per window, so a throwaway view leaves it warm.
    @MainActor
    private static func warmKeyboardGuide() {
        guard let window = keyWindow else { return }
        let view = UIView(frame: .zero)
        view.isHidden = true
        window.addSubview(view)
        _ = view.keyboardLayoutGuide
        view.removeFromSuperview()
    }

    /// One pass through the real views, so SwiftUI's type metadata and protocol
    /// lookups are done. SwiftUI skips rendering without a window, so this adds
    /// them to one, and takes them out again in the same main-thread turn: no
    /// frame is ever committed with them in it.
    @MainActor
    private static func warmEditorViews() {
        guard let window = keyWindow else { return }
        let host = UIHostingController(rootView: ComposerFullScreenView(
            text: .constant("Warm"),
            attachedImages: .constant([]),
            attachedLink: .constant(nil),
            onSend: {},
            onDismiss: {}
        ))
        host.view.frame = window.bounds
        host.view.alpha = 0
        host.view.isUserInteractionEnabled = false
        FocusingTextView.suppressesAutoFocus = true
        window.addSubview(host.view)
        host.view.layoutIfNeeded()
        host.view.removeFromSuperview()
        FocusingTextView.suppressesAutoFocus = false
    }
}
