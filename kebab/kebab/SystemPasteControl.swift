//
//  SystemPasteControl.swift
//  kebab
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Apple's UIPasteControl dressed for the composer's Paste chip. Because the
/// tapped element IS the system control, iOS hands the content over without
/// the repeated "would like to paste from…" permission prompt — the tap
/// itself is the consent.
///
/// The control owns its glyph and label typography; kebab supplies the
/// capsule, clear background, and secondary foreground so it sits in the
/// chip row like the previous custom chip. ClipboardMonitor still decides
/// WHETHER the chip is offered; this control only delivers the payload WHEN
/// the user taps.
struct SystemPasteControl: UIViewRepresentable {

    /// Passed explicitly from the call site (derived from kebab's own
    /// appearance setting) rather than read from the SwiftUI environment —
    /// @Environment reads inside a representable's makeUIView proved stale
    /// on appearance flips, leaving the control in the previous scheme.
    let uiStyle: UIUserInterfaceStyle
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> UIPasteControl {
        // The control resolves its appearance once at creation and ignores
        // later trait changes, so every color is handed over concrete for
        // the CURRENT app appearance — the call site recreates the control
        // (`.id`) when the scheme flips.
        let traits = UITraitCollection(userInterfaceStyle: uiStyle)

        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Style.Color.composerBackgroundUIColor.resolvedColor(with: traits)
        config.baseForegroundColor = Style.Color.secondaryUIColor.resolvedColor(with: traits)

        let control = UIPasteControl(configuration: config)
        // Some OS revisions style the pill from tintColor rather than the
        // configuration's base background — set both to the same resolved
        // color so whichever wins, the pill matches the app's appearance.
        control.tintColor = Style.Color.composerBackgroundUIColor.resolvedColor(with: traits)
        // Pin the control's own trait environment to the app's appearance —
        // kebab's in-app appearance setting can differ from the system's.
        control.overrideUserInterfaceStyle = uiStyle
        control.target = context.coordinator
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        return control
    }

    func updateUIView(_ uiView: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
        uiView.overrideUserInterfaceStyle = uiStyle
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaste: onPaste)
    }

    /// The paste target. Its pasteConfiguration advertises what kebab
    /// accepts (the control auto-disables for anything else); the system
    /// calls `paste(itemProviders:)` with the payload on tap.
    final class Coordinator: UIResponder {
        var onPaste: ([NSItemProvider]) -> Void

        init(onPaste: @escaping ([NSItemProvider]) -> Void) {
            self.onPaste = onPaste
            super.init()
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
                UTType.image.identifier,
                UTType.url.identifier,
                UTType.plainText.identifier
            ])
        }

        override func paste(itemProviders: [NSItemProvider]) {
            let handler = onPaste
            DispatchQueue.main.async {
                handler(itemProviders)
            }
        }
    }
}
