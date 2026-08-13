//
//  PopGestureEnabler.swift
//  kebab
//

import SwiftUI
import UIKit

/// Re-enables the interactive edge-swipe-back gesture on pushed screens that
/// hide the system back button — `.navigationBarBackButtonHidden(true)` also
/// silently disables UIKit's interactive pop gesture.
///
/// The delegate is a long-lived shared object (not the per-screen controller)
/// so the recognizer never falls back to a nil delegate on the root screen,
/// where an attempted pop with an empty stack freezes the navigation
/// controller. Each swipe pops exactly one level, so nested comment threads
/// unwind gracefully: comment-of-comment → comment → entry → feed.
struct PopGestureEnabler: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let navigationController,
                  let recognizer = navigationController.interactivePopGestureRecognizer
            else { return }
            PopGestureDelegate.shared.navigationController = navigationController
            recognizer.delegate = PopGestureDelegate.shared
            recognizer.isEnabled = true
        }
    }
}

final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = PopGestureDelegate()
    weak var navigationController: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }
}

extension View {
    /// Attach to any pushed screen with a custom header to restore
    /// edge-swipe-back.
    func enablesSwipeBack() -> some View {
        background(PopGestureEnabler())
    }
}
