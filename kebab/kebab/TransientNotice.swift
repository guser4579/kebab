//
//  TransientNotice.swift
//  kebab
//

import Combine
import SwiftUI

/// Lightweight transient messages (e.g. "Failed to delete") rendered as a
/// floating capsule above the composer — never a modal. Owned by MainAppView
/// and injected into the environment so pushed screens (entry detail) can
/// surface a failure from a place that still exists after they dismiss.
@MainActor
final class TransientNoticeCenter: ObservableObject {

    @Published private(set) var message: String?
    /// Invalidates a stale auto-clear when a newer notice replaces the text.
    private var generation = 0

    func show(_ message: String) {
        generation += 1
        let current = generation
        withAnimation(.easeOut(duration: 0.2)) {
            self.message = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if self.generation == current {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.message = nil
                }
            }
        }
    }
}
