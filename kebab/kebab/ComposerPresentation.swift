//
//  ComposerPresentation.swift
//  kebab
//
//  Who's showing the draft: the inline composer or the full-screen one. Never
//  both, so the inline composer stays hidden from the tap that opens full screen
//  until the overlay has finished leaving.
//

import SwiftUI

nonisolated struct ComposerPresentation: Equatable {

    enum Phase: Equatable {
        case inline
        case fullScreen
        /// Closed, with the overlay still sliding away.
        case leaving
    }

    private(set) var phase: Phase = .inline
    /// Returning from full screen, a draft rests as one line rather than opening
    /// out over the feed. The next focus or dictation lets it expand.
    var restsCollapsed = false

    var isFullScreen: Bool { phase == .fullScreen }
    var hidesInline: Bool { phase != .inline }

    mutating func open() {
        phase = .fullScreen
        restsCollapsed = false
    }

    mutating func close() {
        guard phase == .fullScreen else { return }
        phase = .leaving
        restsCollapsed = true
    }

    /// Runs when the slide ends, so it does nothing if the draft was reopened
    /// in the meantime.
    mutating func finishLeaving() {
        guard phase == .leaving else { return }
        phase = .inline
    }
}

extension View {
    /// Out of sight and out of reach behind a full-screen editor. It vanishes on
    /// the tap, inside that tap's slide animation, and only the return fades.
    func hiddenBehindFullScreen(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1)
            .animation(hidden ? nil : .easeOut(duration: 0.15), value: hidden)
            // Not allowsHitTesting: that disables the text view underneath, which
            // resigns it and drops the keyboard before the hand-off can happen.
            .overlay {
                if hidden {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {}
                }
            }
            .accessibilityHidden(hidden)
    }
}
