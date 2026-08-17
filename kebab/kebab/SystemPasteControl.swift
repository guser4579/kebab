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

    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> UIPasteControl {
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .clear
        config.baseForegroundColor = Style.Color.secondaryUIColor

        let control = UIPasteControl(configuration: config)
        control.target = context.coordinator
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        return control
    }

    func updateUIView(_ uiView: UIPasteControl, context: Context) {
        context.coordinator.onPaste = onPaste
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
