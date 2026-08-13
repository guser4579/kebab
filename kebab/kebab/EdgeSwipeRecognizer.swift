//
//  EdgeSwipeRecognizer.swift
//  kebab
//

import SwiftUI
import UIKit

/// Window-level left-edge pan that opens settings without touching feed
/// scrolling. A SwiftUI highPriorityGesture claimed every >20pt drag in any
/// direction, forcing the scroll view to wait out a gesture competition on
/// every scroll (the "press, hold, then drag" deadness). UIKit's
/// UIScreenEdgePanGestureRecognizer — the same mechanism as the system back
/// swipe — begins only for horizontal drags starting at the screen edge and
/// fails instantly on vertical motion, so casual scrolling stays native.
struct EdgeSwipeRecognizer: UIViewRepresentable {

    /// Gate evaluated at gesture start; return false while settings is open,
    /// an overlay is up, or a screen is pushed (where the swipe means "back").
    var canBegin: () -> Bool
    var onSwipe: () -> Void

    func makeUIView(context: Context) -> AttachingView {
        let view = AttachingView()
        view.isUserInteractionEnabled = false
        view.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: AttachingView, context: Context) {
        context.coordinator.canBegin = canBegin
        context.coordinator.onSwipe = onSwipe
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(canBegin: canBegin, onSwipe: onSwipe)
    }

    final class AttachingView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canBegin: () -> Bool
        var onSwipe: () -> Void

        private weak var attachedWindow: UIWindow?
        private var recognizer: UIScreenEdgePanGestureRecognizer?

        init(canBegin: @escaping () -> Bool, onSwipe: @escaping () -> Void) {
            self.canBegin = canBegin
            self.onSwipe = onSwipe
        }

        func attach(to window: UIWindow) {
            guard window !== attachedWindow else { return }
            if let recognizer {
                attachedWindow?.removeGestureRecognizer(recognizer)
            }
            let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle))
            edge.edges = .left
            edge.delegate = self
            window.addGestureRecognizer(edge)
            attachedWindow = window
            recognizer = edge
        }

        @objc private func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
            if gesture.state == .began {
                onSwipe()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            canBegin()
        }

        // Default exclusivity is deliberate: when the edge pan begins it must
        // BLOCK other recognizers, or the row's NavigationLink tap fires too
        // and pushes an entry over the opening settings panel. Scrolling is
        // unaffected because an edge recognizer can't begin away from the
        // edge and fails instantly on vertical motion.
    }
}
